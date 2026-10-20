import Foundation

// Neo4j 图数据库模块。跟 Qdrant / ClickHouse 同属「只有静态包一条路」的数据库，
// 特殊点只有一个：它自己不带运行时，起进程必须有兼容的 JDK（JAVA_HOME + PATH）。
// Java 兼容性照搬 FlyEnv 的策略表（src/shared/neo4j-policy.ts），但实测
// Neo4j 2026.09 用策略外的 Java 22 也能跑（只在 neo4j.log 里 warn），
// 所以策略表只用于「Java 列下拉过滤 + 自动绑定推荐值」，启动不硬拦。
@MainActor
final class Neo4jService {
    let root: URL
    private let supervisor: ProcessSupervisor
    private(set) var runningVersion: Neo4jVersion?
    var onExit: (() -> Void)?

    // 已安装 JDK 列表由 Neo4jViewModel.refresh() 刷 Java 模块时注入 ——
    // Java 的扫描范围（ brew keg / sdkman / 系统目录）全在 JavaService 里，
    // 这里只消费，不自己扫一遍。
    var installedJava: [JavaVersion] = []

    // Neo4j bin 路径 → JAVA_HOME。bin 路径是安装目录的唯一稳定身份（同版本重装路径不变）。
    var bindings: [String: String] = UserDefaults.standard.dictionary(forKey: "macenv.neo4j.java") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(bindings, forKey: "macenv.neo4j.java") }
    }

    // 配置 / 数据 / 日志全放 MacEnv 自己管的目录（server/neo4j 下按版本号分），
    // 不往发行版的 conf/data 里写 —— 那下面是安装目录，卸载重装要连数据一起没。
    var directory: URL { root.appendingPathComponent("server/neo4j", isDirectory: true) }
    var versionsDirectory: URL { directory.appendingPathComponent("versions", isDirectory: true) }
    var pidFile: URL { directory.appendingPathComponent("neo4j.pid") }

    init(root: URL) {
        self.root = root
        supervisor = ProcessSupervisor(marker: root.appendingPathComponent("server/neo4j", isDirectory: true).path)
        supervisor.onExit = { [weak self] in
            self?.runningVersion = nil
            self?.onExit?()
        }
    }

    func confDirectory(for version: Neo4jVersion) -> URL { directory.appendingPathComponent("conf-\(version.version)", isDirectory: true) }
    func configURL(for version: Neo4jVersion) -> URL { confDirectory(for: version).appendingPathComponent("neo4j.conf") }
    func dataURL(for version: Neo4jVersion) -> URL { directory.appendingPathComponent("data-\(version.version)", isDirectory: true) }
    func logFile(for version: Neo4jVersion) -> URL { directory.appendingPathComponent("logs-\(version.version)/neo4j.log") }
    private func logsURL(for version: Neo4jVersion) -> URL { directory.appendingPathComponent("logs-\(version.version)", isDirectory: true) }
    private func importURL(for version: Neo4jVersion) -> URL { directory.appendingPathComponent("import-\(version.version)", isDirectory: true) }
    private func pluginsURL(for version: Neo4jVersion) -> URL { directory.appendingPathComponent("plugins-\(version.version)", isDirectory: true) }

    func running(_ version: Neo4jVersion) -> Bool { supervisor.isRunning && runningVersion?.id == version.id }

    // MARK: - 配置

    func prepare(_ version: Neo4jVersion) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: versionsDirectory, withIntermediateDirectories: true)
        for url in [confDirectory(for: version), dataURL(for: version), logsURL(for: version), importURL(for: version), pluginsURL(for: version)] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let file = configURL(for: version)
        if !fm.fileExists(atPath: file.path) {
            // 从发行版随包的 conf/neo4j.conf 复制，保住上游那一大堆默认值
            // （server.jvm.additional 之类），只改目录类设置。自己从零写一份会丢默认值。
            let dist = version.directory.appendingPathComponent("conf/neo4j.conf")
            if fm.fileExists(atPath: dist.path) { try fm.copyItem(at: dist, to: file) }
            else { try "".write(to: file, atomically: true, encoding: .utf8) }
        }
        let existing = try String(contentsOf: file, encoding: .utf8)
        let content = Self.upsert(existing, [
            "server.directories.data": dataURL(for: version).path,
            "server.directories.logs": logsURL(for: version).path,
            "server.directories.import": importURL(for: version).path,
            "server.directories.plugins": pluginsURL(for: version).path,
            // 其余数据库一律回环监听（redis bind 127.0.0.1、clickhouse listen_host）；
            // 要对外开放自己去配置页改 default_listen_address。
            "server.default_listen_address": "127.0.0.1"
        ])
        if content != existing { try content.write(to: file, atomically: true, encoding: .utf8) }
    }

    // neo4j.conf 是 Java properties 语义：同一个 key 出现两行活跃值直接启动失败
    // （实测报 "server.directories.import declared multiple times"）。
    // 发行版里 server.directories.import 恰好是未注释的那一行，所以必须原地替换，
    // 不能偷懒追加。注释行一律不动 —— 取消注释等于替用户改上游语义。
    static func upsert(_ content: String, _ settings: [String: String]) -> String {
        var lines = content.components(separatedBy: .newlines)
        for (key, value) in settings {
            let prefix = key + "="
            var replaced = false
            lines = lines.map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !replaced, !trimmed.hasPrefix("#"), trimmed.hasPrefix(prefix) else { return line }
                replaced = true
                return prefix + value
            }
            if !replaced { lines.append(prefix + value) }
        }
        return lines.joined(separator: "\n")
    }

    func ports(for version: Neo4jVersion) -> (http: Int, https: Int, bolt: Int) {
        guard let content = try? String(contentsOf: configURL(for: version), encoding: .utf8) else { return (7474, 7473, 7687) }
        return (Self.parsePort(content, "server.http.listen_address") ?? 7474,
                Self.parsePort(content, "server.https.listen_address") ?? 7473,
                Self.parsePort(content, "server.bolt.listen_address") ?? 7687)
    }

    // 值是 ":7474" / "0.0.0.0:7474" 这种 host:port 形式，取冒号后那截。
    static func parsePort(_ content: String, _ key: String) -> Int? {
        for line in content.split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard !value.hasPrefix("#"), value.hasPrefix(key + "=") else { continue }
            return Int(value.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces).split(separator: ":").last.map(String.init) ?? "")
        }
        return nil
    }

    // MARK: - Java 绑定与策略

    static func supportedJavaMajors(_ version: String) -> [Int] {
        let numbers = version.split(separator: ".").compactMap { Int($0) }
        let year = numbers.count > 0 ? numbers[0] : 0
        let month = numbers.count > 1 ? numbers[1] : 0
        if year == 2025, month >= 1, month <= 9 { return [21] }
        if year > 2025 || (year == 2025 && month >= 10) { return [21, 25] }
        return [17, 21]
    }

    // JDK 版本形如 "21.0.12"，大版本号就是第一段。
    static func javaMajor(_ version: String) -> Int { Int(version.split(separator: ".").first.map(String.init) ?? "") ?? 0 }

    private func compatibleJava(_ version: String) -> [JavaVersion] {
        let majors = Self.supportedJavaMajors(version)
        // supportedJavaMajors 第一个就是官方 recommended（21），同大版本里取版本号最高的。
        return installedJava.filter { majors.contains(Self.javaMajor($0.version)) }
            .sorted { a, b in
                let ra = Self.javaMajor(a.version) == majors.first ? 0 : 1
                let rb = Self.javaMajor(b.version) == majors.first ? 0 : 1
                return ra != rb ? ra < rb : a.version.compare(b.version, options: .numeric) == .orderedDescending
            }
    }

    // 新装版本自动绑推荐的 JDK；JDK 被卸掉的绑定当场清掉（留着启动必失败）。
    func reconcileBindings(_ installed: [Neo4jVersion]) {
        // 先物化成数组再删：Dictionary 不允许迭代 keys 的同时 mutate，直接绑会上。
        let valid = Set(installed.map(\.executable.path))
        for bin in Array(bindings.keys).filter({ !valid.contains($0) }) { bindings[bin] = nil }
        for version in installed where bindings[version.executable.path] == nil {
            if let best = compatibleJava(version.version).first { bindings[version.executable.path] = best.directory.path }
        }
    }

    func javaCandidates(_ version: String) -> [JavaVersion] { compatibleJava(version) }
    func binding(for version: Neo4jVersion) -> String? { bindings[version.executable.path] }
    func setBinding(_ version: Neo4jVersion, _ javaHome: String) { bindings[version.executable.path] = javaHome }

    // MARK: - 版本扫描

    static func parseVersion(_ text: String) -> String? {
        // bin/neo4j version 输出："neo4j 2026.09.0"（大小写不敏感）。
        firstCapture(#"(?i)neo4j[ ]?v?(\d+(?:\.\d+){1,3})"#, in: text)
    }

    func installedVersions(customDirectories: [String] = []) async throws -> [Neo4jVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String)] = []
        if let items = try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for item in items {
                let file = item.appendingPathComponent("bin/neo4j")
                if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Static")) }
            }
        }
        for directory in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            for path in ["bin/neo4j", "neo4j"] {
                let file = directory.appendingPathComponent(path)
                if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Static")) }
            }
        }
        var seen = Set<String>()
        var result: [Neo4jVersion] = []
        for (file, source) in candidates {
            let executable = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted else { continue }
            // bin/neo4j 是 sh 壳，JAVA_HOME 缺失时直接 exit 1。探测只问版本号不跑服务，
            // 随便借一个已装 JDK 的 JAVA_HOME；机器上一个 JDK 都没有时整个列表为空（同 FlyEnv）。
            guard let javaHome = installedJava.first?.directory.path,
                  let output = try? await Command.run(executable.path, ["version"], environment: ["JAVA_HOME": javaHome]),
                  let version = Self.parseVersion(output.text) else { continue }
            result.append(Neo4jVersion(version: version, directory: executable.deletingLastPathComponent().deletingLastPathComponent(), executable: executable, source: source))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    func adopt(_ versions: [Neo4jVersion]) async {
        guard !supervisor.isRunning else { return }
        // 壳脚本 exec java，pid 文件里存的就是 java 的 PID，按 java 认领（同 qdrant 走 pid 文件）。
        guard let existing = supervisor.owned(pidFile: pidFile, binary: "java"),
              let version = versions.first(where: { $0.executable.path == existing.executable }) else { return }
        runningVersion = version
        supervisor.adopt(existing)
    }

    // MARK: - 启停

    func start(_ version: Neo4jVersion) async throws {
        try prepare(version)
        if let existing = supervisor.owned(pidFile: pidFile, binary: "java") {
            try await supervisor.terminate(existing, force: true)
        }
        guard let javaHome = binding(for: version) else { throw CommandError(message: L("error.neo4jJavaMissing")) }
        // NeoBoot 起来第一件事是读安装目录里自管的 run/neo4j.pid，发现 pid 活着
        // 就整句拒绝（"Neo4j is already running (pid:96631)"）。上一实例被 SIGKILL
        // （停止等待只有 3 秒）时这个文件不会自己清，而 pid 一旦被机器上别的 java
        // 进程复用，第二次启动必挂。所以每次启动前先删，让 NeBoot 重写。
        try? FileManager.default.removeItem(at: version.directory.appendingPathComponent("run/neo4j.pid"))
        let ports = self.ports(for: version)
        let errorLog = directory.appendingPathComponent("neo4j-\(version.version)-start-error.log")
        // console 前台跑；bin/neo4j 是 exec java 的壳，托管 PID 即 java 本身，
        // 退出/认领都按 java 走（不像 redis 那种 fork 后父进程秒退的坑）。
        // 用 /bin/sh 显式唤壳而不是直接跑脚本：launch 的 marker 认领要求 argv 里
        // 带服务自身路径（其他服务的 argv 里都有配置文件路径），NeoBoot 只吃
        // NEO4J_CONF 环境变量、命令行上没路径可带，把脚本绝对路径放进 argv 顶上。
        let item = try supervisor.launch(at: URL(fileURLWithPath: "/bin/sh"),
                                         arguments: [version.executable.path, "console"],
                                         directory: version.directory,
                                         environment: self.environment(javaHome: javaHome, version: version),
                                         errorLog: errorLog)
        // 探活问 HTTP 口的 /：Neo4j 没有 /ping 这类专用端点（/browser 是 301），
        // 没起来时连接直接被拒，curl 必须 --fail 把拒绝当失败。
        var ready = false
        for _ in 0..<60 where item.isRunning {
            if let output = try? await Command.run("/usr/bin/curl", ["-s", "--fail", "--noproxy", "*", "--max-time", "2", "-o", "/dev/null", "http://127.0.0.1:\(ports.http)/"]),
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
        guard let target = supervisor.target ?? supervisor.owned(pidFile: pidFile, binary: "java") else {
            supervisor.forget()
            runningVersion = nil
            try? FileManager.default.removeItem(at: pidFile)
            return
        }
        try await supervisor.terminate(target, force: true)
        runningVersion = nil
        try? FileManager.default.removeItem(at: pidFile)
    }

    private func environment(javaHome: String, version: Neo4jVersion) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // 壳脚本要调 dirname / uname / expr，GUI app 继承的 PATH 不含 /usr/bin，
        // 系统目录显式补上（照 FlyEnv 的 neo4jPathEnv）。去重必须保序 ——
        // JAVA_HOME/bin 要在最前面先被找到（JS 的 Set 保序，Swift 的 Set 不保，
        // 所以手写 filter 版去重，不用 Array(Set(...))）。
        let entries = [javaHome + "/bin", version.executable.deletingLastPathComponent().path]
            + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        environment["PATH"] = entries.filter { seen.insert($0).inserted }.joined(separator: ":")
        environment["JAVA_HOME"] = javaHome
        environment["NEO4J_CONF"] = confDirectory(for: version).path
        environment["NEO4J_HOME"] = version.directory.path
        return environment
    }

    func log(_ version: Neo4jVersion) -> String { readLogTail(logFile(for: version)) }
}
