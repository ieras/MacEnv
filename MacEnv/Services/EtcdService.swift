import Foundation

// etcd —— 服务治理组件（分布式 KV + watch + 租约，K8s 的配置底座）。
//
// 目录布局（配置、数据、日志都按主版本分）：
//   server/etcd/etcd-<major>.yaml      配置，MacEnv 生成，已存在绝不覆盖
//   server/etcd/etcd-<major>-data/     数据目录（WAL + snap）
//   server/etcd/log/etcd.log           etcd 自己写的日志（靠配置里的 log-outputs）
//   server/etcd/etcd.pid               由 MacEnv 在启动成功后写
//
// 启动方式：`etcd --config-file <yaml>`，**前台**跑（不加任何 daemonize 开关，父进程秒退会让
// 托管句柄失效 —— 同 redis / consul / clickhouse）。
//
// 跟 FlyEnv 的三处关键差异（照抄会出事，理由写在 configContent 上面）。
@MainActor
final class EtcdService {
    let root: URL
    private let supervisor: ProcessSupervisor
    private(set) var runningVersion: EtcdVersion?
    var onExit: (() -> Void)?

    var directory: URL { root.appendingPathComponent("server/etcd", isDirectory: true) }
    var versionsDirectory: URL { directory.appendingPathComponent("versions", isDirectory: true) }
    var logDirectory: URL { directory.appendingPathComponent("log", isDirectory: true) }
    var pidFile: URL { directory.appendingPathComponent("etcd.pid") }

    func logFile() -> URL { logDirectory.appendingPathComponent("etcd.log") }
    func configFile(_ version: EtcdVersion) -> URL { directory.appendingPathComponent("etcd-\(version.major).yaml") }
    func dataDirectory(_ version: EtcdVersion) -> URL { directory.appendingPathComponent("etcd-\(version.major)-data", isDirectory: true) }

    init(root: URL) {
        self.root = root
        supervisor = ProcessSupervisor(marker: root.appendingPathComponent("server/etcd", isDirectory: true).path)
        supervisor.onExit = { [weak self] in
            self?.runningVersion = nil
            self?.onExit?()
        }
    }

    func running(_ version: EtcdVersion) -> Bool { supervisor.isRunning && runningVersion?.id == version.id }

    func configText(_ version: EtcdVersion) -> String { (try? String(contentsOf: configFile(version), encoding: .utf8)) ?? "" }

    // 端口一次读全，表格每行都要显示 —— 一行读两遍盘没必要。
    // 配置是 YAML，从 listen-client-urls / listen-peer-urls 里抠端口；读不到就退回 etcd 的默认值。
    func ports(_ version: EtcdVersion) -> (client: Int, peer: Int) {
        let text = configText(version)
        return (Self.port(in: text, key: "listen-client-urls") ?? 2379,
                Self.port(in: text, key: "listen-peer-urls") ?? 2380)
    }

    // 值可能是 `key: "http://127.0.0.1:2379"` 也可能是
    // `key:\n  - "http://127.0.0.1:2379"`（YAML 列表），所以不按行解析，
    // 直接从 key 之后的一小段里找第一个「冒号 + 端口」。
    private static func port(in text: String, key: String) -> Int? {
        guard let range = text.range(of: key) else { return nil }
        return firstCapture(#":(\d{2,5})"#, in: String(text[range.upperBound...].prefix(200))).flatMap(Int.init)
    }

    // 已经存在的配置绝不覆盖 —— 用户改过的端口、集群参数要是被下次启动冲掉，那是灾难。
    func prepare(_ version: EtcdVersion) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.createDirectory(at: dataDirectory(version), withIntermediateDirectories: true)
        try fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: configFile(version).path) {
            try configContent(version).write(to: configFile(version), atomically: true, encoding: .utf8)
        }
    }

    // 对照 FlyEnv 的 initConfig()，三处必须改：
    //
    // ① **补 initial-cluster。** FlyEnv 那份写了 `name: "etcd-flyenv-test"` 却没写 initial-cluster，
    //    而 etcd 的 initial-cluster 默认值是 `default=http://localhost:2380` —— 名字对不上，
    //    etcd 直接拒绝启动（couldn't find local name ... in the initial cluster configuration）。
    // ② **log-outputs 必须指向文件。** FlyEnv 写 `["stdout"]`，但 MacEnv 的 ProcessSupervisor.launch
    //    把 standardOutput 接到 /dev/null（只有 stderr 落盘），照抄的话「日志」tab 永远是空的。
    //    Consul 靠配置里的 log_file 解决同一个问题，etcd 就靠 log-outputs。
    // ③ **补 data-dir。** FlyEnv 压根没设，etcd 会在工作目录下建 default.etcd —— 也就是
    //    数据落在二进制旁边。MacEnv 显式指定到 server/etcd/etcd-<major>-data。
    //
    // 另外把 listen-*-urls 从 0.0.0.0 收回 127.0.0.1：FlyEnv 绑全网卡是为了能组多机集群，
    // MacEnv 只做本机开发环境，绑回环更安全（要连集群自己在配置页改）。
    private func configContent(_ version: EtcdVersion) -> String {
        let name = "macenv-etcd"
        let peer = "http://127.0.0.1:2380"
        return """
        name: "\(name)"
        data-dir: \(doubleQuoted(dataDirectory(version).path))
        listen-client-urls: "http://127.0.0.1:2379"
        listen-peer-urls: "\(peer)"
        advertise-client-urls: "http://127.0.0.1:2379"
        initial-advertise-peer-urls: "\(peer)"
        initial-cluster: "\(name)=\(peer)"
        log-level: "info"
        log-outputs: [\(doubleQuoted(logFile().path))]
        """
    }

    // `etcd --version` 第一行是「etcd Version: 3.7.2」，后面几行是 Git SHA / Go Version / Go OS-Arch。
    static func parseVersion(_ text: String) -> String? {
        firstCapture(#"etcd Version: (\d+(?:\.\d+){1,4})"#, in: text)
    }

    // 来源两条：Homebrew（homebrew/core 有正式公式）和静态包（one-env 给的官方 GitHub release zip）。
    // 没有 MacPorts —— `port search '^etcd$'` 是 No match，FlyEnv 那边也没给这一栏。
    func installedVersions(customDirectories: [String] = []) async throws -> [EtcdVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String, String?)] = []
        for (file, formula) in try await Brew.installedBinaries("etcd", binary: "etcd") {
            candidates.append((file, "Homebrew", formula))
        }
        if let items = try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for item in items {
                let file = item.appendingPathComponent("bin/etcd")
                if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Static", nil)) }
            }
        }
        for directory in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            for path in ["etcd", "bin/etcd"] {
                let file = directory.appendingPathComponent(path)
                if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Static", nil)) }
            }
        }
        var seen = Set<String>()
        var result: [EtcdVersion] = []
        for (file, source, formula) in candidates {
            let executable = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted else { continue }
            let output = try await Command.run(executable.path, ["--version"])
            guard let version = Self.parseVersion(output.text) else { continue }
            result.append(EtcdVersion(version: version, directory: executable.deletingLastPathComponent().deletingLastPathComponent(), executable: executable, source: source, formula: formula))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    func brewFormulae() async throws -> [BrewFormulaItem] { try await Brew.formulae("etcd") }

    func adopt(_ versions: [EtcdVersion]) async {
        guard !supervisor.isRunning else { return }
        guard let existing = supervisor.owned(pidFile: pidFile, binary: "etcd"),
              let version = versions.first(where: { $0.executable.path == existing.executable }) else { return }
        runningVersion = version
        supervisor.adopt(existing)
    }

    func start(_ version: EtcdVersion) async throws {
        try prepare(version)
        if let existing = supervisor.owned(pidFile: pidFile, binary: "etcd") {
            try await supervisor.terminate(existing, force: true)
        }
        let stderrLog = logDirectory.appendingPathComponent("etcd.start.err.log")
        let item = try supervisor.launch(at: version.executable,
                                         arguments: ["--config-file", configFile(version).path],
                                         directory: version.directory,
                                         environment: ProcessInfo.processInfo.environment,
                                         errorLog: stderrLog)
        // 探活问 /health：etcd 起来后会回 200 {"health":"true"}，没起来是连不上或 503。
        // 必须带 --fail —— 不带的话 503 也是退出码 0，探活就白做了（Qdrant 的 /readyz 踩过同一个坑）。
        let port = ports(version).client
        do {
            var ready = false
            for _ in 0..<50 where item.isRunning {
                if let output = try? await Command.run("/usr/bin/curl", ["-s", "--fail", "--noproxy", "*", "--max-time", "1", "http://127.0.0.1:\(port)/health"]),
                   output.status == 0 { ready = true; break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            guard ready && item.isRunning else {
                // 配置错（名字对不上、端口占用、数据目录是别的版本写的）都走这条路，
                // 原因只会出现在 stderr 那个文件里，把它原文抛出来，别只给一句「启动失败」。
                let stderr = (try? String(contentsOf: stderrLog, encoding: .utf8)) ?? ""
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw CommandError(message: detail.isEmpty ? L("error.serviceStartFailed") : detail)
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
        guard let target = supervisor.target ?? supervisor.owned(pidFile: pidFile, binary: "etcd") else {
            supervisor.forget()
            runningVersion = nil
            try? FileManager.default.removeItem(at: pidFile)
            return
        }
        // SIGTERM 是 etcd 的优雅退出信号（FlyEnv 的 _stopSignal() 也把 etcd 归在 -TERM 那一组）：
        // 它会停 raft、刷 WAL、关 bolt，所以别一上来就 SIGKILL。
        try await supervisor.terminate(target, force: true)
        runningVersion = nil
        try? FileManager.default.removeItem(at: pidFile)
    }

    func log() -> String { readLogTail(logFile()) }
}
