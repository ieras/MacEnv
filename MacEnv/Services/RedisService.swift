import Foundation

@MainActor
final class RedisService {
    let root: URL
    private let supervisor: ProcessSupervisor
    private(set) var runningVersion: RedisVersion?
    var onExit: (() -> Void)?

    var directory: URL { root.appendingPathComponent("server/redis", isDirectory: true) }
    var versionsDirectory: URL { directory.appendingPathComponent("versions", isDirectory: true) }
    var pidFile: URL { directory.appendingPathComponent("redis.pid") }

    init(root: URL) {
        self.root = root
        supervisor = ProcessSupervisor(marker: root.appendingPathComponent("server/redis", isDirectory: true).path)
        supervisor.onExit = { [weak self] in
            self?.runningVersion = nil
            self?.onExit?()
        }
    }

    func configURL(for version: RedisVersion) -> URL { directory.appendingPathComponent("redis-\(version.majorMinor).conf") }
    func dataURL(for version: RedisVersion) -> URL { directory.appendingPathComponent("db-\(version.majorMinor)", isDirectory: true) }
    func logFile(for version: RedisVersion) -> URL { directory.appendingPathComponent("redis-\(version.majorMinor).log") }

    func running(_ version: RedisVersion) -> Bool { supervisor.isRunning && runningVersion?.id == version.id }

    // redis.conf 是「键 值」空格分隔，不是 my.cnf 那种 key=value。
    func port(for version: RedisVersion) -> Int {
        guard let content = try? String(contentsOf: configURL(for: version), encoding: .utf8) else { return 6379 }
        for line in content.split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace)
            if parts.count >= 2, parts[0] == "port" { return Int(parts[1]) ?? 6379 }
        }
        return 6379
    }

    func prepare(_ version: RedisVersion) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: versionsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: dataURL(for: version), withIntermediateDirectories: true)
        let file = configURL(for: version)
        guard !fm.fileExists(atPath: file.path) else { return }
        let content = """
        # daemonize 必须是 no：MacEnv 靠前台进程托管，yes 会让 redis fork 完就让父进程秒退，
        # supervisor 判成启动失败，真正的 redis 却变成没人管的孤儿进程（跟 php-fpm.conf 一个道理）。
        # 路径里带空格（Application Support），redis.conf 是空格分隔的「键 值」，
        # 不加引号会被拆成好几段，直接报 FATAL CONFIG FILE ERROR。
        daemonize no
        port 6379
        bind 127.0.0.1
        pidfile \(doubleQuoted(pidFile.path))
        logfile \(doubleQuoted(logFile(for: version).path))
        dir \(doubleQuoted(dataURL(for: version).path))
        loglevel notice
        databases 16
        save 900 1
        save 300 10
        save 60 10000
        rdbcompression yes
        dbfilename dump.rdb
        appendonly no
        appendfsync everysec
        """
        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    func installedVersions(customDirectories: [String] = []) async throws -> [RedisVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String, String?)] = []
        if let brew = Brew.executable {
            for formula in try await Brew.formulae("redis") {
                for version in formula.installedVersions {
                    for cellar in ["/opt/homebrew/Cellar", "/usr/local/Cellar"] {
                        let file = URL(fileURLWithPath: cellar).appendingPathComponent(formula.name).appendingPathComponent(version).appendingPathComponent("bin/redis-server")
                        if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Homebrew", formula.name)) }
                    }
                }
                let prefix = try await Command.run(brew, ["--prefix", formula.name], environment: Command.brewEnvironment)
                if prefix.status == 0 {
                    let file = URL(fileURLWithPath: prefix.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).appendingPathComponent("bin/redis-server")
                    if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Homebrew", formula.name)) }
                }
            }
        }
        if let items = try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for item in items {
                for path in ["bin/redis-server", "sbin/redis-server", "redis-server"] {
                    let file = item.appendingPathComponent(path)
                    if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Static", nil)); break }
                }
            }
        }
        for directory in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            for path in ["redis-server", "bin/redis-server", "sbin/redis-server"] {
                let file = directory.appendingPathComponent(path)
                if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Static", nil)) }
            }
        }
        // MacPorts 的 redis 直接落在 /opt/local/bin，不像数据库那样待在 /opt/local/lib/<name>/bin 下。
        let macPorts = URL(fileURLWithPath: "/opt/local/bin/redis-server")
        if fm.isExecutableFile(atPath: macPorts.path) { candidates.append((macPorts, "MacPorts", nil)) }
        var seen = Set<String>()
        var result: [RedisVersion] = []
        for (file, source, formula) in candidates {
            let executable = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted else { continue }
            // redis-server -v 输出：Redis server v=7.2.5 sha=00000000:0 malloc=libc bits=64 build=...
            let output = try await Command.run(executable.path, ["-v"])
            guard let version = firstCapture(#"v=(\d+(?:\.\d+){1,3})"#, in: output.text) else { continue }
            result.append(RedisVersion(version: version, directory: executable.deletingLastPathComponent().deletingLastPathComponent(), executable: executable, source: source, formula: formula))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    func brewFormulae() async throws -> [BrewFormulaItem] { try await Brew.formulae("redis") }

    func adopt(_ versions: [RedisVersion]) async {
        guard !supervisor.isRunning else { return }
        // redis 用 setproctitle 把 argv 改写成 "redis-server 127.0.0.1:6379"，
        // MacEnv 的路径标记和 conf 路径全没了，supervisor.find 按命令行匹配永远找不到它。
        // 走 pidfile + proc_pidpath，认的是内核里的真实可执行路径。
        guard let existing = supervisor.owned(pidFile: pidFile, binary: "redis-server"),
              let version = versions.first(where: { $0.executable.path == existing.command }) else { return }
        runningVersion = version
        supervisor.adopt(existing)
    }

    func start(_ version: RedisVersion) async throws {
        try prepare(version)
        if let existing = supervisor.owned(pidFile: pidFile, binary: "redis-server") {
            try await supervisor.terminate(existing, graceful: { try? await self.shutdown(version) }, force: true)
        }
        let startupLog = directory.appendingPathComponent("redis-\(version.version)-start-error.log")
        let item = try supervisor.launch(at: version.executable,
                                         arguments: [configURL(for: version).path],
                                         directory: version.directory,
                                         environment: ProcessInfo.processInfo.environment,
                                         errorLog: startupLog)
        // 配置写错时 redis 会立刻退出。等半秒再判活，别把「秒退」当成启动成功。
        for _ in 0..<5 where item.isRunning { try await Task.sleep(nanoseconds: 100_000_000) }
        guard item.isRunning else {
            supervisor.forget()
            throw CommandError(message: (try? String(contentsOf: startupLog, encoding: .utf8)) ?? L("error.databaseStartFailed"))
        }
        runningVersion = version
        try String(item.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
    }

    func stop() async throws {
        guard let target = supervisor.owned(pidFile: pidFile, binary: "redis-server") else {
            supervisor.forget()
            runningVersion = nil
            try? FileManager.default.removeItem(at: pidFile)
            return
        }
        if let version = runningVersion { try await supervisor.terminate(target, graceful: { try? await self.shutdown(version) }, force: true) }
        else { try await supervisor.terminate(target, force: true) }
        runningVersion = nil
        try? FileManager.default.removeItem(at: pidFile)
    }

    // redis-cli shutdown 会先把数据落盘再退出，比直接发 SIGTERM 稳。
    private func shutdown(_ version: RedisVersion) async throws {
        let cli = version.executable.deletingLastPathComponent().appendingPathComponent("redis-cli")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { return }
        _ = try await Command.run(cli.path, ["-p", String(port(for: version)), "shutdown"])
    }

    func log(_ version: RedisVersion) -> String { readLogTail(logFile(for: version)) }
}
