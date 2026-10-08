import Foundation

@MainActor
final class PostgresService {
    let root: URL
    private let supervisor: ProcessSupervisor
    private(set) var runningVersion: PostgresVersion?
    var onExit: (() -> Void)?

    var directory: URL { root.appendingPathComponent("server/postgresql", isDirectory: true) }
    var versionsDirectory: URL { directory.appendingPathComponent("versions", isDirectory: true) }
    var pidFile: URL { directory.appendingPathComponent("postgresql.pid") }
    let defaultPort = 5432

    init(root: URL) {
        self.root = root
        supervisor = ProcessSupervisor(marker: root.appendingPathComponent("server/postgresql", isDirectory: true).path)
        supervisor.onExit = { [weak self] in
            self?.runningVersion = nil
            self?.onExit?()
        }
    }

    // 配置（postgresql.conf）、日志、密码全在数据目录里，initdb 生成 —— 这跟 MySQL
    // 「MacEnv 自己写 my.cnf」是两条路，PG 的生态就认数据目录这套布局，别自作主张搬出去。
    func dataURL(for version: PostgresVersion) -> URL { directory.appendingPathComponent("data-\(version.major)", isDirectory: true) }
    func logFile(for version: PostgresVersion) -> URL { dataURL(for: version).appendingPathComponent("pg.log") }
    func configURL(for version: PostgresVersion) -> URL { dataURL(for: version).appendingPathComponent("postgresql.conf") }

    func running(_ version: PostgresVersion) -> Bool { supervisor.isRunning && runningVersion?.id == version.id }

    func port(for version: PostgresVersion) -> Int { Self.parsePort(try? String(contentsOf: configURL(for: version), encoding: .utf8)) ?? defaultPort }

    static func parsePort(_ content: String?) -> Int? {
        for line in (content ?? "").split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard !value.hasPrefix("#"), let index = value.firstIndex(of: "=") else { continue }
            guard value[..<index].trimmingCharacters(in: .whitespaces) == "port" else { continue }
            return Int(value[value.index(after: index)...].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static func parseVersion(_ text: String) -> String? {
        // postgres --version 输出："postgres (PostgreSQL) 16.4"
        firstCapture(#"\(PostgreSQL\) (\d+(?:\.\d+){1,3})"#, in: text)
    }

    func installedVersions(customDirectories: [String] = []) async throws -> [PostgresVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String, String?)] = []
        for (file, formula) in try await Brew.installedBinaries("postgresql", binary: "postgres") {
            candidates.append((file, "Homebrew", formula))
        }
        if let items = try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for item in items {
                let file = item.appendingPathComponent("bin/postgres")
                if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Static", nil)) }
            }
        }
        for directory in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            for path in ["postgres", "bin/postgres"] {
                let file = directory.appendingPathComponent(path)
                if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Static", nil)) }
            }
        }
        // MacPorts 的 postgresql16 落在 /opt/local/lib/postgresql16/bin，跟 mysql/mariadb 同一个布局。
        if let items = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/opt/local/lib", isDirectory: true), includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for item in items where item.lastPathComponent.lowercased().hasPrefix("postgresql") {
                let file = item.appendingPathComponent("bin/postgres")
                if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "MacPorts", nil)) }
            }
        }
        var seen = Set<String>()
        var result: [PostgresVersion] = []
        for (file, source, formula) in candidates {
            let executable = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted else { continue }
            let output = try await Command.run(executable.path, ["--version"])
            guard let version = Self.parseVersion(output.text) else { continue }
            result.append(PostgresVersion(version: version, directory: executable.deletingLastPathComponent().deletingLastPathComponent(), executable: executable, source: source, formula: formula))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    func brewFormulae() async throws -> [BrewFormulaItem] { try await Brew.formulae("postgresql") }

    func adopt(_ versions: [PostgresVersion]) async {
        guard !supervisor.isRunning else { return }
        // 服务会改写 argv；由启动记录与内核身份一起确认归属。
        guard let existing = supervisor.owned(pidFile: pidFile, binary: "postgres"),
              let version = versions.first(where: { $0.executable.path == existing.executable }) else { return }
        runningVersion = version
        supervisor.adopt(existing)
    }

    func start(_ version: PostgresVersion) async throws {
        if let existing = supervisor.owned(pidFile: pidFile, binary: "postgres") {
            try await supervisor.terminate(existing, graceful: { try? await self.shutdown(version) }, force: true)
        }
        let data = dataURL(for: version)
        let passwordPending = data.appendingPathComponent(".macenv-password-pending")
        if !FileManager.default.fileExists(atPath: configURL(for: version).path) {
            let contents = (try? FileManager.default.contentsOfDirectory(at: data, includingPropertiesForKeys: nil)) ?? []
            guard contents.isEmpty else {
                throw CommandError(message: String(format: L("error.databaseDataDirIncomplete"), "PostgreSQL", data.lastPathComponent))
            }
            try await initialize(version, data: data)
            try Data().write(to: passwordPending)
        }
        // 前台跑 postgres -D，不是 pg_ctl start —— pg_ctl 会 fork 守护进程然后父进程秒退，
        // 托管句柄立刻失效（FlyEnv 注释里踩过同一个坑，跟 redis 的 daemonize no 一回事）。
        let item = try supervisor.launch(at: version.executable,
                                         arguments: ["-D", data.path],
                                         directory: version.directory,
                                         environment: ProcessInfo.processInfo.environment,
                                         errorLog: logFile(for: version))
        do {
            let isready = version.executable.deletingLastPathComponent().appendingPathComponent("pg_isready")
            guard FileManager.default.isExecutableFile(atPath: isready.path) else { throw CommandError(message: L("error.binaryMissing") + "pg_isready") }
            var ready = false
            for _ in 0..<50 where item.isRunning {
                let output = try await Command.run(isready.path, ["-p", String(port(for: version)), "-h", "127.0.0.1", "-t", "1"])
                if output.status == 0 { ready = true; break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard ready && item.isRunning else {
                throw CommandError(message: log(version) + "\n" + L("error.serviceStartTimeout"))
            }
            runningVersion = version
            try String(item.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
            if FileManager.default.fileExists(atPath: passwordPending.path) {
                try await setRootPassword(version)
                try FileManager.default.removeItem(at: passwordPending)
            }
        } catch {
            try await Task { @MainActor in
                if let target = supervisor.target { try await supervisor.terminate(target, force: true) }
            }.value
            runningVersion = nil
            throw error
        }
    }

    func stop() async throws {
        guard let target = supervisor.target ?? supervisor.owned(pidFile: pidFile, binary: "postgres") else {
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

    // pg_ctl stop -m fast 会等事务收尾后让 postmaster 干净退出并清掉 postmaster.pid，
    // 比 SIGTERM 硬杀稳 —— 硬杀留下的共享内存要等进程全退才能释放。
    private func shutdown(_ version: PostgresVersion) async throws {
        let pgctl = version.executable.deletingLastPathComponent().appendingPathComponent("pg_ctl")
        guard FileManager.default.isExecutableFile(atPath: pgctl.path) else { return }
        _ = try await Command.run(pgctl.path, ["stop", "-D", dataURL(for: version).path, "-m", "fast"])
    }

    // initdb 的参数构造抽出来给单测钉行为。locale 必须显式给：GUI 启动的 App 环境里
    // 没有 LANG/LC_*，initdb 第一步 locale 校验就报「无效的区域设置」直接死（本机踩过）。
    // en_US.UTF-8 跟 FlyEnv、Homebrew 官方 bottle 的做法一致，macOS 上永远存在。
    static let initdbLocale = "en_US.UTF-8"
    static func initdbArguments(_ data: URL) -> [String] {
        ["-D", data.path, "-U", "root", "--locale=" + initdbLocale, "--encoding=UTF8"]
    }

    private func initialize(_ version: PostgresVersion, data: URL) async throws {
        let initdb = version.executable.deletingLastPathComponent().appendingPathComponent("initdb")
        guard FileManager.default.isExecutableFile(atPath: initdb.path) else {
            throw CommandError(message: L("error.postgresInstallerMissing"))
        }
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        // 超级用户 root，跟 MySQL 系对齐。本地连接默认 trust，密码主要给 TCP 客户端用。
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = Self.initdbLocale
        environment["LANG"] = Self.initdbLocale
        let output = try await Command.run(initdb.path, Self.initdbArguments(data), environment: environment)
        guard output.status == 0 else {
            // initdb 半路死会留下残留目录，不清掉的话下次启动永远卡在「数据目录不完整」。
            // 只清空目录 —— 里面有东西说明是真实数据（或用户自己的目录），绝不能碰。
            let left = (try? FileManager.default.contentsOfDirectory(at: data, includingPropertiesForKeys: nil)) ?? []
            if left.isEmpty { try? FileManager.default.removeItem(at: data) }
            throw CommandError(message: output.text)
        }
    }

    private func setRootPassword(_ version: PostgresVersion) async throws {
        let psql = version.executable.deletingLastPathComponent().appendingPathComponent("psql")
        guard FileManager.default.isExecutableFile(atPath: psql.path) else { throw CommandError(message: L("error.binaryMissing") + "psql") }
        let output = try await Command.run(psql.path, ["-h", "127.0.0.1", "-p", String(port(for: version)), "-U", "root", "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-c", "ALTER USER root WITH PASSWORD 'root'"], environment: ["PGCONNECT_TIMEOUT": "3"])
        guard output.status == 0 else { throw CommandError(message: output.text) }
    }

    func log(_ version: PostgresVersion) -> String { readLogTail(logFile(for: version)) }
}
