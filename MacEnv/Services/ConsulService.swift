import Foundation

// Consul —— 服务治理组件（服务发现 / 健康检查 / KV / 自带 Web UI）。
//
// 目录布局（配置、数据、日志全部按主版本分，理由见 ConsulVersion.major）：
//   server/consul/consul-<major>.json      配置，MacEnv 生成，已存在绝不覆盖
//   server/consul/consul-<major>-data/     数据目录（raft 存储）
//   server/consul/log/consul.log           Consul 自己写的日志（-log-file / log_file）
//   server/consul/consul.pid               由 MacEnv 在启动成功后写
//
// 启动方式：`consul agent -config-file=<json>`，**前台**跑（不加任何 fork/daemonize 开关，
// 父进程秒退会让托管句柄失效 —— redis 的 daemonize no 是同一个坑）。
// 端口不写死在命令行，全在配置里：HTTP/UI 8500、DNS 8600，界面上那两列读的就是它。
@MainActor
final class ConsulService {
    let root: URL
    private let supervisor: ProcessSupervisor
    private(set) var runningVersion: ConsulVersion?
    var onExit: (() -> Void)?

    var directory: URL { root.appendingPathComponent("server/consul", isDirectory: true) }
    var versionsDirectory: URL { directory.appendingPathComponent("versions", isDirectory: true) }
    var logDirectory: URL { directory.appendingPathComponent("log", isDirectory: true) }
    var pidFile: URL { directory.appendingPathComponent("consul.pid") }

    func logFile() -> URL { logDirectory.appendingPathComponent("consul.log") }
    func configFile(_ version: ConsulVersion) -> URL { directory.appendingPathComponent("consul-\(version.major).json") }
    func dataDirectory(_ version: ConsulVersion) -> URL { directory.appendingPathComponent("consul-\(version.major)-data", isDirectory: true) }

    // 自带 Web UI 的地址。Consul 1.10 起要配置里显式开 ui_config.enabled 才会在 :8500/ui 提供页面。
    func webUI(_ version: ConsulVersion) -> URL { URL(string: "http://127.0.0.1:\(ports(version).http)/ui")! }

    init(root: URL) {
        self.root = root
        supervisor = ProcessSupervisor(marker: root.appendingPathComponent("server/consul", isDirectory: true).path)
        supervisor.onExit = { [weak self] in
            self?.runningVersion = nil
            self?.onExit?()
        }
    }

    func running(_ version: ConsulVersion) -> Bool { supervisor.isRunning && runningVersion?.id == version.id }

    func configText(_ version: ConsulVersion) -> String { (try? String(contentsOf: configFile(version), encoding: .utf8)) ?? "" }

    // 端口一次读全，表格每行都要显示 —— 一行读两遍盘没必要。
    // Consul 的默认端口就是 8500(HTTP/UI) / 8600(DNS)，配置里读不到才退回默认值。
    func ports(_ version: ConsulVersion) -> (http: Int, dns: Int) {
        let object = (try? JSONSerialization.jsonObject(with: Data(configText(version).utf8))) as? [String: Any]
        let ports = object?["ports"] as? [String: Any]
        return ((ports?["http"] as? Int) ?? 8500, (ports?["dns"] as? Int) ?? 8600)
    }

    // 已经存在的配置绝不覆盖 —— 用户改过的端口、节点名要是被下次启动冲掉，那是灾难。
    func prepare(_ version: ConsulVersion) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.createDirectory(at: dataDirectory(version), withIntermediateDirectories: true)
        try fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: configFile(version).path) {
            try configContent(version).write(to: configFile(version), atomically: true, encoding: .utf8)
        }
    }

    // 默认配置照 FlyEnv 那份（server / bootstrap_expect / client_addr / ui_config.enabled），
    // 另外补三样 FlyEnv 放在命令行上的东西，让「配置文件 = 唯一来源」：
    //   data_dir / log_file  —— FlyEnv 走 -data-dir / -log-file 参数
    //   bind_addr            —— FlyEnv 走 -bind=<本机 LAN IP>，为的是能组多机集群；
    //                           MacEnv 只做本机开发环境，绑回环更安全，要连集群自己在配置页改
    //   node_name            —— 本机 hostname 是 m2MacBook-Pro.local（带点），
    //                           Consul 拿它当节点名会踩合法性校验，所以固定一个干净的名字
    // 端口显式写出来，界面「端口」列读的就是它，显示值和真实监听端口不会各说各话。
    private func configContent(_ version: ConsulVersion) -> String {
        """
        {
          "server": true,
          "bootstrap_expect": 1,
          "node_name": "macenv-consul",
          "client_addr": "127.0.0.1",
          "bind_addr": "127.0.0.1",
          "data_dir": "\(dataDirectory(version).path)",
          "log_file": "\(logFile().path)",
          "log_level": "INFO",
          "ui_config": {
            "enabled": true
          },
          "ports": {
            "http": 8500,
            "dns": 8600
          }
        }
        """
    }

    // `consul version` 第一行是「Consul v1.21.4」，后面几行是 Revision / Build Date / Protocol。
    static func parseVersion(_ text: String) -> String? {
        firstCapture(#"Consul v(\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?)"#, in: text)
    }

    // 不扫 Homebrew：consul 在 homebrew/core 里没有公式，官方只发 cask 和 hashicorp/tap，
    // 本机那个 tap 未信任，brew 直接拒绝加载（跟 ClickHouse 只有 cask 是同一种情况）。
    // 所以只剩静态包、MacPorts（/opt/local/bin/consul）和自定义目录。
    func installedVersions(customDirectories: [String] = []) async throws -> [ConsulVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String)] = []
        if let items = try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for item in items {
                // 平铺 zip 解出来落在 bin/consul；万一包里有目录层则落在 consul，两条都认。
                for path in ["bin/consul", "consul"] {
                    let file = item.appendingPathComponent(path)
                    if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Static")) }
                }
            }
        }
        // MacPorts 的 consul 是 Go 编的单文件，直接落在 /opt/local/bin（同 redis / mkcert）。
        let macPorts = URL(fileURLWithPath: "/opt/local/bin/consul")
        if fm.isExecutableFile(atPath: macPorts.path) { candidates.append((macPorts, "MacPorts")) }
        for directory in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            for path in ["consul", "bin/consul"] {
                let file = directory.appendingPathComponent(path)
                if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Static")) }
            }
        }
        var seen = Set<String>()
        var result: [ConsulVersion] = []
        for (file, source) in candidates {
            let executable = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted else { continue }
            let output = try await Command.run(executable.path, ["version"])
            guard let version = Self.parseVersion(output.text) else { continue }
            let parent = executable.deletingLastPathComponent()
            let directory = ["bin", "sbin"].contains(parent.lastPathComponent) ? parent.deletingLastPathComponent() : parent
            result.append(ConsulVersion(version: version, directory: directory, executable: executable, source: source))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    func adopt(_ versions: [ConsulVersion]) async {
        guard !supervisor.isRunning else { return }
        guard let existing = supervisor.owned(pidFile: pidFile, binary: "consul"),
              let version = versions.first(where: { $0.executable.path == existing.executable }) else { return }
        runningVersion = version
        supervisor.adopt(existing)
    }

    func start(_ version: ConsulVersion) async throws {
        try prepare(version)
        if let existing = supervisor.owned(pidFile: pidFile, binary: "consul") {
            try await supervisor.terminate(existing, force: true)
        }
        let item = try supervisor.launch(at: version.executable,
                                         arguments: ["agent", "-config-file=\(configFile(version).path)"],
                                         directory: version.directory,
                                         environment: ProcessInfo.processInfo.environment,
                                         errorLog: logDirectory.appendingPathComponent("consul.start.err.log"))
        // 探活问 HTTP API：/v1/agent/self 在 agent 起来后立刻回 200，比干等固定秒数准。
        // 选它而不是 /v1/status/leader，是因为后者要等选主完成，单节点虽然很快但没必要把
        // 「起没起来」和「选没选完主」绑在一起。
        let port = ports(version).http
        do {
            var ready = false
            for _ in 0..<40 where item.isRunning {
                if let output = try? await Command.run("/usr/bin/curl", ["-s", "--fail", "--noproxy", "*", "--max-time", "1", "http://127.0.0.1:\(port)/v1/agent/self"]),
                   output.status == 0 { ready = true; break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            guard ready && item.isRunning else {
                throw CommandError(message: (try? String(contentsOf: logFile(), encoding: .utf8)) ?? L("error.serviceStartFailed"))
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
        guard let target = supervisor.target ?? supervisor.owned(pidFile: pidFile, binary: "consul") else {
            supervisor.forget()
            runningVersion = nil
            try? FileManager.default.removeItem(at: pidFile)
            return
        }
        // SIGTERM。⚠️ 别以为这样就「优雅退集群」了：Consul 的 leave_on_terminate 默认 false，
        // 实测日志是「Graceful shutdown disabled. Exiting」+「serf: Shutdown without a Leave」，
        // 也就是直接落盘走人，不向集群广播 leave。
        //
        // 那为什么不把 leave_on_terminate 打开？实测打开后 SIGTERM 到真正退出要 10 秒以上
        // （先 server starting leave → 等 LAN leave 事件 → 还要 drain RPC 流量 drain_time=5s），
        // 而 ProcessSupervisor 的宽限期只有 3 秒（waitGone attempts: 30 × 100ms），到点就 SIGKILL ——
        // 半路被打断的 leave 会让集群里留下一个状态错乱的节点，比干脆不 leave 更糟。
        // 想真优雅退集群，得先把宽限期拉长，那是另一件事。
        try await supervisor.terminate(target, force: true)
        runningVersion = nil
        try? FileManager.default.removeItem(at: pidFile)
    }

    func log() -> String { readLogTail(logFile()) }
}
