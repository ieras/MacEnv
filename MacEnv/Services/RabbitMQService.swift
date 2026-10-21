import Foundation

// RabbitMQ 消息队列模块。跟 Neo4j 一样「自己不带运行时」—— 它是 Erlang/OTP 写的，
// 起进程必须有兼容的 erl（PATH 最前面）。OTP 兼容矩阵照搬官方 which-erlang 页，
// 但只用于「Erlang 列下拉过滤 + 自动绑定推荐值」，启动不硬拦
// （Neo4j 实测策略外的 JDK 也能跑，同一立场）。
@MainActor
final class RabbitMQService {
    let root: URL
    private let supervisor: ProcessSupervisor
    private(set) var runningVersion: RabbitMQVersion?
    var onExit: (() -> Void)?

    // 已安装 Erlang 列表由 RabbitMQViewModel.refresh() 刷 Erlang 模块时注入 ——
    // Erlang 的扫描范围（brew keg / MacPorts / PATH / 自定义目录）全在 ErlangService 里，
    // 这里只消费，不自己扫一遍（同 Neo4j 的 installedJava）。
    var installedErlang: [ErlangVersion] = []

    // sbin 路径 → Erlang 根目录。sbin 路径是安装目录的唯一稳定身份（同版本重装路径不变）。
    var bindings: [String: String] = UserDefaults.standard.dictionary(forKey: "macenv.rabbitmq.erlang") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(bindings, forKey: "macenv.rabbitmq.erlang") }
    }

    // 配置 / 数据 / 日志全放 MacEnv 自己管理的目录（server/rabbitmq 下按版本号分），
    // 不往发行版 etc/rabbitmq 里写 —— 那下面是安装目录，卸载重装要连数据一起没（同 Neo4j）。
    var directory: URL { root.appendingPathComponent("server/rabbitmq", isDirectory: true) }
    var versionsDirectory: URL { directory.appendingPathComponent("versions", isDirectory: true) }
    var pidFile: URL { directory.appendingPathComponent("rabbitmq.pid") }

    init(root: URL) {
        self.root = root
        supervisor = ProcessSupervisor(marker: root.appendingPathComponent("server/rabbitmq", isDirectory: true).path)
        supervisor.onExit = { [weak self] in
            self?.runningVersion = nil
            self?.onExit?()
        }
    }

    func confDirectory(for version: RabbitMQVersion) -> URL { directory.appendingPathComponent("conf-\(version.version)", isDirectory: true) }
    func envFile(for version: RabbitMQVersion) -> URL { confDirectory(for: version).appendingPathComponent("rabbitmq.env") }
    func configURL(for version: RabbitMQVersion) -> URL { confDirectory(for: version).appendingPathComponent("rabbitmq.conf") }
    private func pluginsFile(for version: RabbitMQVersion) -> URL { confDirectory(for: version).appendingPathComponent("enabled_plugins") }
    func mnesiaURL(for version: RabbitMQVersion) -> URL { directory.appendingPathComponent("mnesia-\(version.version)", isDirectory: true) }
    func logDirectory(for version: RabbitMQVersion) -> URL { directory.appendingPathComponent("log-\(version.version)", isDirectory: true) }
    func logFile(for version: RabbitMQVersion) -> URL { logDirectory(for: version).appendingPathComponent("rabbit@localhost.log") }

    func running(_ version: RabbitMQVersion) -> Bool { supervisor.isRunning && runningVersion?.id == version.id }

    // MARK: - 配置

    func prepare(_ version: RabbitMQVersion) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: versionsDirectory, withIntermediateDirectories: true)
        for url in [confDirectory(for: version), mnesiaURL(for: version), logDirectory(for: version)] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        // ini（cuttlefish 语义）：端口写自己的配置文件，「配置 = 唯一来源」——
        // 端口列读它、配置页改它，显示值和真实监听不会各说各话（同 Consul / Neo4j）。
        var ini = (try? String(contentsOf: configURL(for: version), encoding: .utf8)) ?? ""
        let original = ini
        ini = IniFile.set("listeners.tcp.default", to: "5672", in: ini)
        ini = IniFile.set("management.tcp.port", to: "15672", in: ini)
        if ini != original { try ini.write(to: configURL(for: version), atomically: true, encoding: .utf8) }
        // env 文件：rabbitmq-env 直接 source 它（. "$RABBITMQ_CONF_ENV_FILE"），
        // 所以必须是合法 sh —— KEY=value，值一律双引号（数据目录在 Application Support
        // 底下，路径带空格，不引起来 source 当场炸）。
        let content = Self.upsert((try? String(contentsOf: envFile(for: version), encoding: .utf8)) ?? "", [
            // 其余数据库一律回环监听（redis bind 127.0.0.1、clickhouse listen_host）。
            "NODE_IP_ADDRESS": "127.0.0.1",
            // 节点名固定：一改 mnesia 目录、日志名、pid 文件名全跟着变，为一个没人用的功能背一身耦合。
            "NODENAME": "rabbit@localhost",
            "RABBITMQ_LOG_BASE": logDirectory(for: version).path,
            "MNESIA_BASE": mnesiaURL(for: version).path,
            "RABBITMQ_ENABLED_PLUGINS_FILE": pluginsFile(for: version).path,
            "PLUGINS_DIR": version.directory.appendingPathComponent("plugins").path
        ])
        try content.write(to: envFile(for: version), atomically: true, encoding: .utf8)
        // 管理插件预写进 enabled_plugins：rabbitmq-plugins enable 要 escript + 节点已起，
        // 靠启动流程白发一轮请求纯属自找麻烦（同 FlyEnv）。管理界面探活也靠它。
        if !fm.fileExists(atPath: pluginsFile(for: version).path) {
            try "[rabbitmq_management].\n".write(to: pluginsFile(for: version), atomically: true, encoding: .utf8)
        }
    }

    // env 文件是 sh 片段：原地替换第一个匹配行（注释行天然不匹配 # 前缀的 key），
    // 没有就追加。同 Neo4j 的 upsert 一个路子，只是值要引起来。
    static func upsert(_ content: String, _ settings: [String: String]) -> String {
        var lines = content.components(separatedBy: .newlines)
        for (key, value) in settings {
            let prefix = key + "="
            if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) }) {
                lines[index] = prefix + doubleQuoted(value)
            } else {
                lines.append(prefix + doubleQuoted(value))
            }
        }
        return lines.joined(separator: "\n")
    }

    func ports(for version: RabbitMQVersion) -> (amqp: Int, management: Int) {
        guard let content = try? String(contentsOf: configURL(for: version), encoding: .utf8) else { return (5672, 15672) }
        return (IniFile.value("listeners.tcp.default", in: content).flatMap(Int.init) ?? 5672,
                IniFile.value("management.tcp.port", in: content).flatMap(Int.init) ?? 15672)
    }

    // MARK: - Erlang 绑定与策略

    // RabbitMQ 各系列要求的最低 / 最高 Erlang OTP（官方 which-erlang 页）：
    // 4.4/4.3 要 27 起，4.2 锁 27，4.0.4+/4.1 要 26.2 起，3.13 要 26。
    // 表只用来过滤下拉和挑推荐值，启动不硬拦 —— 策略外的组合多数也能跑，只是不再保证。
    static func supportedOtpMajors(_ version: String) -> [Int] {
        let numbers = version.split(separator: ".").compactMap { Int($0) }
        let major = numbers.count > 0 ? numbers[0] : 0
        let minor = numbers.count > 1 ? numbers[1] : 0
        switch major {
        case 4: return minor >= 2 ? [27, 28, 29] : [26, 27]
        case 3: return minor >= 13 ? [26] : [25, 26]
        default: return [26, 27]
        }
    }

    // Erlang 版本形如 "27"（OTP release），大版本号就是它本身。
    static func otpMajor(_ version: String) -> Int { Int(version.split(separator: ".").first.map(String.init) ?? "") ?? 0 }

    private func compatibleErlang(_ version: String) -> [ErlangVersion] {
        let majors = Self.supportedOtpMajors(version)
        // supportedOtpMajors 第一个就是官方 recommended，同大版本里取版本号最高的。
        return installedErlang.filter { majors.contains(Self.otpMajor($0.version)) }
            .sorted { a, b in
                let ra = Self.otpMajor(a.version) == majors.first ? 0 : 1
                let rb = Self.otpMajor(b.version) == majors.first ? 0 : 1
                return ra != rb ? ra < rb : a.version.compare(b.version, options: .numeric) == .orderedDescending
            }
    }

    // 新装版本自动绑推荐的 Erlang；Erlang 被卸掉的绑定当场清掉（留着启动必失败）。
    func reconcileBindings(_ installed: [RabbitMQVersion]) {
        // 先物化成数组再删：Dictionary 不允许迭代 keys 的同时 mutate，直接绑会上。
        let valid = Set(installed.map(\.executable.path))
        for bin in Array(bindings.keys).filter({ !valid.contains($0) }) { bindings[bin] = nil }
        for version in installed where bindings[version.executable.path] == nil {
            if let best = compatibleErlang(version.version).first { bindings[version.executable.path] = best.directory.path }
        }
    }

    func erlangCandidates(_ version: String) -> [ErlangVersion] { compatibleErlang(version) }
    func binding(for version: RabbitMQVersion) -> String? { bindings[version.executable.path] }
    func setBinding(_ version: RabbitMQVersion, _ erlangHome: String) { bindings[version.executable.path] = erlangHome }

    // MARK: - 版本扫描

    static func parseVersion(_ text: String) -> String? {
        // rabbitmqctl version 输出 "4.0.9"（有的版本会带别的尾巴，正则只取三段号）。
        firstCapture(#"\b(\d+\.\d+(?:\.\d+)?)\b"#, in: text)
    }

    func installedVersions(customDirectories: [String] = []) async throws -> [RabbitMQVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String, String?)] = []
        for item in (try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
            let file = item.appendingPathComponent("sbin/rabbitmq-server")
            if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Static", nil)) }
        }
        // brew：rabbitmq 公式是 prefix.install 整套发行版，二进制在 keg 的 sbin/ 下，
        // 所以扫 sbin 不扫 bin。bin 那一扫是给老布局兜底。
        for (file, formula) in (try? await Brew.installedBinaries("rabbitmq", binary: "rabbitmq-server", subdirectory: "sbin")) ?? [] {
            candidates.append((file, "Homebrew", formula))
        }
        for (file, formula) in (try? await Brew.installedBinaries("rabbitmq", binary: "rabbitmq-server")) ?? [] {
            candidates.append((file, "Homebrew", formula))
        }
        // MacPorts：erlang 是依赖，rabbitmq 本体落在 /opt/local/lib/rabbitmq。
        for path in ["sbin/rabbitmq-server", "bin/rabbitmq-server"] {
            let file = URL(fileURLWithPath: "/opt/local/lib/rabbitmq/" + path)
            if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "MacPorts", nil)) }
        }
        for directory in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            for path in ["sbin/rabbitmq-server", "bin/rabbitmq-server", "rabbitmq-server"] {
                let file = directory.appendingPathComponent(path)
                if fm.isExecutableFile(atPath: file.path) { candidates.append((file, L("source.custom"), nil)) }
            }
        }
        var seen = Set<String>()
        var result: [RabbitMQVersion] = []
        for (file, source, formula) in candidates {
            // brew / macports 的入口可能是软链，解析到真身再判重，否则同一个版本出现两行。
            let executable = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted else { continue }
            // rabbitmqctl 是 escript，PATH 里没有 erl 连版本号都吐不出来
            // （Neo4j 探测时借 JAVA_HOME 是同一个坑）。借第一个已装 Erlang 的 bin。
            // rabbitmqctl 同样要过 rabbitmq-env：cwd 给 sbin、SCRIPTS_DIR 预设 "."
            // （空格路径那道坎，同 start），套一层 sh -c 把 cwd 传进去。
            let sbin = executable.deletingLastPathComponent()
            guard let output = try? await Command.run("/bin/sh",
                    ["-c", "cd \"$1\" && RABBITMQ_SCRIPTS_DIR=. ./rabbitmqctl version", "rabbitmqctl", sbin.path],
                    environment: Self.probeEnvironment(installedErlang.first?.directory.path)),
                  let version = Self.parseVersion(output.text) else { continue }
            result.append(RabbitMQVersion(version: version,
                                          directory: executable.deletingLastPathComponent().deletingLastPathComponent(),
                                          executable: executable, source: source, formula: formula))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    // 探测用的 PATH：erlang 的 bin 排最前（escript 要 erl），其余补上系统目录。
    private static func probeEnvironment(_ erlangHome: String?) -> [String: String] {
        var entries = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        if let erlangHome { entries.insert(erlangHome + "/bin", at: 0) }
        entries += ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return ["PATH": entries.filter { seen.insert($0).inserted }.joined(separator: ":"),
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
    }

    func adopt(_ versions: [RabbitMQVersion]) async {
        guard !supervisor.isRunning else { return }
        // exec 模式下 rabbitmq.pid 里记的就是 beam 的 PID；beam 的 argv 里带着
        // 脚本绝对路径（start 时当 plain argument 传下去的），据此认出是哪个版本。
        if let existing = supervisor.owned(pidFile: pidFile, binary: "beam.smp"),
           let version = versions.first(where: { existing.command.contains($0.executable.path) }) {
            runningVersion = version
            supervisor.adopt(existing)
        }
    }

    // MARK: - 启停

    func start(_ version: RabbitMQVersion) async throws {
        try prepare(version)
        guard let erlang = binding(for: version) else { throw CommandError(message: L("error.rabbitmqErlangMissing")) }
        let ports = self.ports(for: version)
        let errorLog = directory.appendingPathComponent("rabbitmq-\(version.version)-start-error.log")
        // RABBITMQ_ALLOW_INPUT 一设，rabbitmq-server 就 exec erl 把壳整个换成 beam：
        // 托管 PID 即真进程（同 Neo4j 的 exec java），SIGTERM 直接给 beam 就是上游
        // 设计的优雅停止路径（Docker 同款），没有壳、没有孤儿 beam。
        // 两个绕空格路径的机关：cwd 落 sbin + RABBITMQ_SCRIPTS_DIR="." ——
        // rabbitmq-env 第 89 行 source rabbitmq-defaults 没加引号，数据目录在
        // Application Support 底下路径带空格，不绕这一手当场 word-split 炸掉；
        // cwd 在 sbin，rmq_realpath("./..") 正好解析出版本目录。
        // 脚本绝对路径同时作为 erl 的 plain argument 一路带到 beam 的 argv 里，
        // supervisor 认领在跑进程（adopt）全靠它。
        let item = try supervisor.launch(at: version.executable,
                                         arguments: [version.executable.path],
                                         directory: version.executable.deletingLastPathComponent(),
                                         environment: environment(erlang: erlang, version: version),
                                         errorLog: errorLog)
        // 探活问管理插件的 HTTP 口（enabled_plugins 预写了 rabbitmq_management，
        // 浏览器那个界面就在这）：没起来时连接直接被拒，curl 必须 --fail 把拒绝当失败。
        // 首次启动要建 mnesia schema，比别的服务慢，给到 60 秒。
        var ready = false
        for _ in 0..<120 where item.isRunning {
            if let output = try? await Command.run("/usr/bin/curl", ["-s", "--fail", "--noproxy", "*", "--max-time", "2", "-o", "/dev/null", "http://127.0.0.1:\(ports.management)/"]),
               output.status == 0 { ready = true; break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard ready && item.isRunning else {
            try await Task { @MainActor in
                if let target = supervisor.target { try await supervisor.terminate(target, force: true) }
            }.value
            throw CommandError(message: ((try? String(contentsOf: errorLog, encoding: .utf8)) ?? "") + "\n" + L("error.serviceStartTimeout"))
        }
        runningVersion = version
        try String(item.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
    }

    func stop() async throws {
        // target 是本次 app 会话启动的 beam；pid 文件兜底是 app 重启后还没 refresh 的场景。
        let target = supervisor.target ?? supervisor.owned(pidFile: pidFile, binary: "beam.smp")
        guard let target else {
            supervisor.forget()
            runningVersion = nil
            try? FileManager.default.removeItem(at: pidFile)
            return
        }
        try await supervisor.terminate(target, force: true)
        runningVersion = nil
        try? FileManager.default.removeItem(at: pidFile)
    }

    private func environment(erlang: String, version: RabbitMQVersion) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // 壳脚本要调 dirname / hostname / sed，GUI app 继承的 PATH 不含 /usr/bin；
        // erlang 的 bin 排最前（erl / escript / epmd 全从这儿找），系统目录显式补上。
        // 去重必须保序 —— erlang/bin 要在最前面先被找到（Swift 的 Set 不保序，
        // 所以手写 filter 版去重，同 Neo4j）。
        let entries = [erlang + "/bin", version.executable.deletingLastPathComponent().path]
            + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        environment["PATH"] = entries.filter { seen.insert($0).inserted }.joined(separator: ":")
        // HOME 显式带上：erl 找 .erlang.cookie、写日志默认位置都用它。
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        // rabbitmq-env 会 source 这个文件拿 NODENAME / MNESIA_BASE 那一套；
        // 配置文件（ini）不被任何脚本读，只被 Erlang 侧的 rabbit_prelaunch 按
        // RABBITMQ_CONFIG_FILE 环境变量找，所以走进程环境而不是 env 文件。
        environment["RABBITMQ_CONF_ENV_FILE"] = envFile(for: version).path
        environment["RABBITMQ_CONFIG_FILE"] = configURL(for: version).path
        // 壳脚本链只认这几个：SCRIPTS_DIR 指 "."（cwd 是 sbin）绕开 rabbitmq-env 里
        // 没加引号的 source；ALLOW_INPUT 让 rabbitmq-server 走 exec erl 分支；
        // -noinput 必须显式补 —— ALLOW_INPUT 分支不像另一支会自动加，erl 会起交互
        // shell，stdin 一 EOF 整个 VM 当场终止（实测踩过）。
        environment["RABBITMQ_SCRIPTS_DIR"] = "."
        environment["RABBITMQ_ALLOW_INPUT"] = "1"
        environment["RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS"] = "-noinput"
        return environment
    }

    func log(_ version: RabbitMQVersion) -> String { readLogTail(logFile(for: version)) }
}
