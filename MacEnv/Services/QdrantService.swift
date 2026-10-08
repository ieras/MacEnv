import Foundation

@MainActor
final class QdrantService {
    let root: URL
    private let supervisor: ProcessSupervisor
    private(set) var runningVersion: QdrantVersion?
    var onExit: (() -> Void)?

    // 配置 / 数据 / 日志 / pid 全放这里（MacEnv 自己管的目录），不往 Homebrew 的 Cellar 包目录里写，
    // 那玩意儿是只读的，硬写会崩。跟 redis 一个道理（redis 的 db 目录也在 server/redis 下）。
    var directory: URL { root.appendingPathComponent("server/qdrant", isDirectory: true) }
    var versionsDirectory: URL { directory.appendingPathComponent("versions", isDirectory: true) }
    var pidFile: URL { directory.appendingPathComponent("qdrant.pid") }
    let defaultPort = 6333

    init(root: URL) {
        self.root = root
        supervisor = ProcessSupervisor(marker: root.appendingPathComponent("server/qdrant", isDirectory: true).path)
        supervisor.onExit = { [weak self] in
            self?.runningVersion = nil
            self?.onExit?()
        }
    }

    func configURL(for version: QdrantVersion) -> URL { directory.appendingPathComponent("qdrant-\(version.version).yaml") }
    func storageURL(for version: QdrantVersion) -> URL { directory.appendingPathComponent("storage-\(version.version)", isDirectory: true) }
    func snapshotsURL(for version: QdrantVersion) -> URL { directory.appendingPathComponent("snapshots-\(version.version)", isDirectory: true) }
    func logFile(for version: QdrantVersion) -> URL { directory.appendingPathComponent("qdrant-\(version.version).log") }

    func running(_ version: QdrantVersion) -> Bool { supervisor.isRunning && runningVersion?.id == version.id }

    func port(for version: QdrantVersion) -> Int { Self.parsePort(try? String(contentsOf: configURL(for: version), encoding: .utf8)) ?? defaultPort }

    // Qdrant 的 config 是 YAML，http_port 缩进在 service: 下；storage_path / snapshots_path
    // 我们一律写绝对路径，不学 FlyEnv 的 ./storage 相对 cwd（cwd 一飘数据就不知道去哪了）。
    static func parsePort(_ content: String?) -> Int? {
        for line in (content ?? "").split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard !value.hasPrefix("#") else { continue }
            if value.hasPrefix("http_port:") {
                let v = value.dropFirst("http_port:".count).trimmingCharacters(in: .whitespaces)
                return Int(v)
            }
        }
        return nil
    }

    static func parseVersion(_ text: String) -> String? {
        // qdrant --version 输出："qdrant 1.12.0"（大小写不敏感）。
        firstCapture(#"(?i)qdrant[ ]?v?(\d+(?:\.\d+){1,3})"#, in: text)
    }

    func prepare(_ version: QdrantVersion) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: versionsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: storageURL(for: version), withIntermediateDirectories: true)
        try fm.createDirectory(at: snapshotsURL(for: version), withIntermediateDirectories: true)
        let file = configURL(for: version)
        guard !fm.fileExists(atPath: file.path) else { return }
        // 现代 Qdrant 二进制自带 dashboard（:6333/dashboard），不单独下载 web-ui。
        // on_disk 日志写到固定文件，日志面板才有内容可读（默认只打 stdout）。
        let content = """
        log_level: INFO
        storage:
          storage_path: \(doubleQuoted(storageURL(for: version).path))
          snapshots_path: \(doubleQuoted(snapshotsURL(for: version).path))
        service:
          host: 127.0.0.1
          http_port: 6333
          grpc_port: 6334
          enable_cors: true
        logger:
          on_disk:
            enabled: true
            log_file: \(doubleQuoted(logFile(for: version).path))
            log_level: INFO
        """
        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    // 只有静态包一条路：官方没发 brew 公式（brew 公式接口查不到 qdrant）、MacPorts 也没有 port
    // （FlyEnv 的 brewinfo / portinfo 都返回空）。所以只扫静态目录和用户自定义目录。
    func installedVersions(customDirectories: [String] = []) async throws -> [QdrantVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String)] = []
        if let items = try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for item in items {
                let file = item.appendingPathComponent("bin/qdrant")
                if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Static")) }
            }
        }
        for directory in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            for path in ["qdrant", "bin/qdrant"] {
                let file = directory.appendingPathComponent(path)
                if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Static")) }
            }
        }
        var seen = Set<String>()
        var result: [QdrantVersion] = []
        for (file, source) in candidates {
            let executable = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted else { continue }
            let output = try await Command.run(executable.path, ["--version"])
            guard let version = Self.parseVersion(output.text) else { continue }
            result.append(QdrantVersion(version: version, directory: executable.deletingLastPathComponent().deletingLastPathComponent(), executable: executable, source: source))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    func adopt(_ versions: [QdrantVersion]) async {
        guard !supervisor.isRunning else { return }
        // Qdrant 是 Rust 二进制，不改写 argv（不像 redis/postgres 的 setproctitle），
        // 但走 pid 文件认领最稳，跟 redis/postgres 同构。
        guard let existing = supervisor.owned(pidFile: pidFile, binary: "qdrant"),
              let version = versions.first(where: { $0.executable.path == existing.executable }) else { return }
        runningVersion = version
        supervisor.adopt(existing)
    }

    func start(_ version: QdrantVersion) async throws {
        try prepare(version)
        if let existing = supervisor.owned(pidFile: pidFile, binary: "qdrant") {
            try await supervisor.terminate(existing, force: true)
        }
        let errorLog = directory.appendingPathComponent("qdrant-\(version.version)-start-error.log")
        // 前台跑 qdrant --config-path，不是 nohup/daemon —— 否则父进程秒退托管句柄失效。
        let item = try supervisor.launch(at: version.executable,
                                         arguments: ["--config-path", configURL(for: version).path],
                                         directory: version.directory,
                                         environment: ProcessInfo.processInfo.environment,
                                         errorLog: errorLog)
        // 探活问 HTTP 口的 /readyz：Qdrant 起好之前它回 503（这个端点 v1.5.0 起就有），
        // 所以 curl 必须带 --fail，否则 503 也被当成成功。比干等固定秒数准
        // （同 ClickHouse 的 /ping、PG 的 pg_isready）。超时必须报错，进程存活不代表服务已经就绪。
        let port = port(for: version)
        do {
            var ready = false
            for _ in 0..<25 where item.isRunning {
                if let output = try? await Command.run("/usr/bin/curl", ["-s", "--fail", "--noproxy", "*", "--max-time", "1", "-o", "/dev/null", "http://127.0.0.1:\(port)/readyz"]),
                   output.status == 0 { ready = true; break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            guard ready && item.isRunning else {
                throw CommandError(message: ((try? String(contentsOf: errorLog, encoding: .utf8)) ?? "") + "\n" + L("error.serviceStartTimeout"))
            }
            runningVersion = version
            try String(item.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
        } catch {
            try await Task { @MainActor in
                if let target = supervisor.target { try await supervisor.terminate(target, force: true) }
            }.value
            throw error
        }
    }

    func stop() async throws {
        guard let target = supervisor.target ?? supervisor.owned(pidFile: pidFile, binary: "qdrant") else {
            supervisor.forget()
            runningVersion = nil
            try? FileManager.default.removeItem(at: pidFile)
            return
        }
        try await supervisor.terminate(target, force: true)
        runningVersion = nil
        try? FileManager.default.removeItem(at: pidFile)
    }

    func log(_ version: QdrantVersion) -> String { readLogTail(logFile(for: version)) }
}
