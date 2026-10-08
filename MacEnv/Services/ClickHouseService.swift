import Foundation

@MainActor
final class ClickHouseService {
    let root: URL
    private let supervisor: ProcessSupervisor
    private(set) var runningVersion: ClickHouseVersion?
    var onExit: (() -> Void)?

    var directory: URL { root.appendingPathComponent("server/clickhouse", isDirectory: true) }
    var versionsDirectory: URL { directory.appendingPathComponent("versions", isDirectory: true) }
    var dataDirectory: URL { directory.appendingPathComponent("data", isDirectory: true) }
    var logDirectory: URL { directory.appendingPathComponent("log", isDirectory: true) }
    var pidFile: URL { directory.appendingPathComponent("clickhouse.pid") }
    var configFile: URL { directory.appendingPathComponent("config.xml") }
    var usersFile: URL { directory.appendingPathComponent("users.xml") }

    init(root: URL) {
        self.root = root
        supervisor = ProcessSupervisor(marker: root.appendingPathComponent("server/clickhouse", isDirectory: true).path)
        supervisor.onExit = { [weak self] in
            self?.runningVersion = nil
            self?.onExit?()
        }
    }

    // ClickHouse 的配置是 MacEnv 自己写的两个 XML，不是像 PG 那样由 initdb 生成 ——
    // 跟 MySQL 的 my.cnf 一条路。数据目录单份，切版本沿用同一份数据（官方向下兼容）。
    func logFile() -> URL { logDirectory.appendingPathComponent("server.log") }

    func running(_ version: ClickHouseVersion) -> Bool { supervisor.isRunning && runningVersion?.id == version.id }

    // 配置只有一份（不分版本），端口一次读全 —— 表格每行都要显示，一行读两遍盘没必要。
    func ports() -> (http: Int, tcp: Int) {
        let text = configText()
        return (Self.xmlValue("http_port", in: text) ?? 8123, Self.xmlValue("tcp_port", in: text) ?? 9000)
    }

    func configText() -> String { (try? String(contentsOf: configFile, encoding: .utf8)) ?? "" }
    func usersText() -> String { (try? String(contentsOf: usersFile, encoding: .utf8)) ?? "" }

    // 配置只有一份（不分版本），所以取标签值不用传 version。
    static func xmlValue(_ tag: String, in content: String) -> Int? {
        guard let start = content.range(of: "<\(tag)>"),
              let end = content.range(of: "</\(tag)>", range: start.upperBound..<content.endIndex) else { return nil }
        return Int(content[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // 已经存在的配置绝不覆盖 —— 用户改过的端口、内存限制要是被下次启动冲掉，那是灾难。
    func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: configFile.path) {
            try configContent().write(to: configFile, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: usersFile.path) {
            try usersContent().write(to: usersFile, atomically: true, encoding: .utf8)
        }
    }

    private func configContent() -> String {
        """
        <clickhouse>
            <logger>
                <level>information</level>
                <log>\(logFile().path)</log>
                <errorlog>\(logDirectory.appendingPathComponent("server.err.log").path)</errorlog>
                <size>10M</size>
                <count>3</count>
            </logger>
            <http_port>8123</http_port>
            <tcp_port>9000</tcp_port>
            <listen_host>127.0.0.1</listen_host>
            <path>\(dataDirectory.path)/</path>
            <tmp_path>\(dataDirectory.appendingPathComponent("tmp").path)/</tmp_path>
            <user_files_path>\(dataDirectory.appendingPathComponent("user_files").path)/</user_files_path>
            <users_config>\(usersFile.path)</users_config>
            <default_profile>default</default_profile>
        </clickhouse>
        """
    }

    // 超级用户就是 root / root，不给 default 空密码账号留后门。
    // access_management 打开，否则 root 建不了库、建不了别的用户，跟 MySQL 的 root 不是一个量级。
    private func usersContent() -> String {
        """
        <clickhouse>
            <profiles>
                <default/>
            </profiles>
            <users>
                <root>
                    <password>root</password>
                    <networks>
                        <ip>::/0</ip>
                    </networks>
                    <profile>default</profile>
                    <quota>default</quota>
                    <access_management>1</access_management>
                </root>
            </users>
            <quotas>
                <default/>
            </quotas>
        </clickhouse>
        """
    }

    static func parseVersion(_ text: String) -> String? {
        // clickhouse --version 输出："ClickHouse version 26.9.12.8-stable (official build)."
        firstCapture(#"(\d+\.\d+\.\d+\.\d+(?:-[A-Za-z]+)?)"#, in: text)
    }

    // 不扫 Homebrew：官方只提供 cask，brew 的公式接口（Brew.formulae）根本查不到，
    // 扫了也是白扫。MacPorts 同样没有 port。所以只剩静态包和自定义目录。
    func installedVersions(customDirectories: [String] = []) async throws -> [ClickHouseVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String)] = []
        if let items = try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for item in items {
                let file = item.appendingPathComponent("bin/clickhouse")
                if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Static")) }
            }
        }
        for directory in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            for path in ["clickhouse", "bin/clickhouse"] {
                let file = directory.appendingPathComponent(path)
                if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Static")) }
            }
        }
        var seen = Set<String>()
        var result: [ClickHouseVersion] = []
        for (file, source) in candidates {
            let executable = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted else { continue }
            let output = try await Command.run(executable.path, ["--version"])
            guard let version = Self.parseVersion(output.text) else { continue }
            result.append(ClickHouseVersion(version: version, directory: executable.deletingLastPathComponent().deletingLastPathComponent(), executable: executable, source: source))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    func adopt(_ versions: [ClickHouseVersion]) async {
        guard !supervisor.isRunning else { return }
        guard let existing = supervisor.owned(pidFile: pidFile, binary: "clickhouse"),
              let version = versions.first(where: { $0.executable.path == existing.executable }) else { return }
        runningVersion = version
        supervisor.adopt(existing)
    }

    func start(_ version: ClickHouseVersion) async throws {
        try prepare()
        if let existing = supervisor.owned(pidFile: pidFile, binary: "clickhouse") {
            try await supervisor.terminate(existing, force: true)
        }
        // 前台跑 server 子命令，不加 --daemonize —— fork 成守护进程后父进程秒退，
        // 托管句柄立刻失效（redis 的 daemonize no、PG 的 pg_ctl start 都是同一个坑）。
        let item = try supervisor.launch(at: version.executable,
                                         arguments: ["server", "--config-file=\(configFile.path)"],
                                         directory: version.directory,
                                         environment: ProcessInfo.processInfo.environment,
                                         errorLog: logDirectory.appendingPathComponent("server.start.err.log"))
        // 探活问 HTTP 口的 /ping：ClickHouse 起来后它一定回 200，比干等固定秒数准。
        let port = ports().http
        do {
            var ready = false
            for _ in 0..<40 where item.isRunning {
                if let output = try? await Command.run("/usr/bin/curl", ["-s", "--fail", "--noproxy", "*", "--max-time", "1", "http://127.0.0.1:\(port)/ping"]),
                   output.status == 0 { ready = true; break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            guard ready && item.isRunning else {
                throw CommandError(message: ((try? String(contentsOf: logFile(), encoding: .utf8)) ?? "") + "\n" + L("error.serviceStartTimeout"))
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
        guard let target = supervisor.target ?? supervisor.owned(pidFile: pidFile, binary: "clickhouse") else {
            supervisor.forget()
            runningVersion = nil
            try? FileManager.default.removeItem(at: pidFile)
            return
        }
        try await supervisor.terminate(target, force: true)
        runningVersion = nil
        try? FileManager.default.removeItem(at: pidFile)
    }

    func log() -> String { readLogTail(logFile()) }
}
