import Foundation

@MainActor
final class KafkaService {
    let root: URL
    private let supervisor: ProcessSupervisor
    private(set) var runningVersion: KafkaVersion?
    var onExit: (() -> Void)?

    var installedJava: [JavaVersion] = []

    var bindings: [String: String] = UserDefaults.standard.dictionary(forKey: "macenv.kafka.java") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(bindings, forKey: "macenv.kafka.java") }
    }

    var directory: URL { root.appendingPathComponent("server/kafka", isDirectory: true) }
    var versionsDirectory: URL { directory.appendingPathComponent("versions", isDirectory: true) }
    var pidFile: URL { directory.appendingPathComponent("kafka.pid") }

    init(root: URL) {
        self.root = root
        supervisor = ProcessSupervisor(marker: root.appendingPathComponent("server/kafka", isDirectory: true).path)
        supervisor.onExit = { [weak self] in
            self?.runningVersion = nil
            self?.onExit?()
        }
    }

    func confDirectory(for version: KafkaVersion) -> URL { directory.appendingPathComponent("conf-\(version.version)", isDirectory: true) }
    func configURL(for version: KafkaVersion) -> URL { confDirectory(for: version).appendingPathComponent("server.properties") }
    func dataURL(for version: KafkaVersion) -> URL { directory.appendingPathComponent("data-\(version.version)", isDirectory: true) }
    func logsURL(for version: KafkaVersion) -> URL { directory.appendingPathComponent("logs-\(version.version)", isDirectory: true) }
    func logFile(for version: KafkaVersion) -> URL { logsURL(for: version).appendingPathComponent("server.log") }
    func errorLogFile() -> URL { directory.appendingPathComponent("kafka-start-error.log") }

    func running(_ version: KafkaVersion) -> Bool { supervisor.isRunning && runningVersion?.id == version.id }

    // MARK: - 配置

    func prepare(_ version: KafkaVersion) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: versionsDirectory, withIntermediateDirectories: true)
        for url in [confDirectory(for: version), dataURL(for: version), logsURL(for: version)] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let file = configURL(for: version)
        guard !fm.fileExists(atPath: file.path) else { return }
        let config = """
        process.roles=broker,controller
        node.id=1
        controller.quorum.voters=1@127.0.0.1:9093
        listeners=PLAINTEXT://127.0.0.1:9092,CONTROLLER://127.0.0.1:9093
        advertised.listeners=PLAINTEXT://127.0.0.1:9092
        controller.listener.names=CONTROLLER
        log.dirs=\(dataURL(for: version).path)
        offsets.topic.replication.factor=1
        transaction.state.log.replication.factor=1
        transaction.state.log.min.isr=1
        """
        try config.write(to: file, atomically: true, encoding: .utf8)
    }

    static func parsePorts(_ content: String) -> (broker: Int, controller: Int) {
        for line in content.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.hasPrefix("#"), text.hasPrefix("listeners=") else { continue }
            return (Int(firstCapture(#"PLAINTEXT://[^:]+:(\d+)"#, in: text) ?? "") ?? 9092,
                    Int(firstCapture(#"CONTROLLER://[^:]+:(\d+)"#, in: text) ?? "") ?? 9093)
        }
        return (9092, 9093)
    }

    func ports(for version: KafkaVersion) -> (broker: Int, controller: Int) {
        guard let content = try? String(contentsOf: configURL(for: version), encoding: .utf8) else { return (9092, 9093) }
        return Self.parsePorts(content)
    }

    // MARK: - Java 绑定

    static func supportsJava(_ version: String) -> Bool {
        (Int(version.prefix(while: \.isNumber)) ?? 0) >= 17
    }

    func javaCandidates() -> [JavaVersion] {
        installedJava.filter { Self.supportsJava($0.version) }
            .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    func reconcileBindings(_ installed: [KafkaVersion]) {
        let valid = Set(installed.map(\.executable.path))
        for bin in Array(bindings.keys).filter({ !valid.contains($0) }) { bindings[bin] = nil }
        for version in installed where bindings[version.executable.path] == nil {
            if let best = javaCandidates().first { bindings[version.executable.path] = best.directory.path }
        }
    }

    func binding(for version: KafkaVersion) -> String? { bindings[version.executable.path] }
    func setBinding(_ version: KafkaVersion, _ javaHome: String) { bindings[version.executable.path] = javaHome }

    // MARK: - 版本扫描

    static func parseVersion(_ text: String) -> String? { firstCapture(#"^(\d+\.\d+\.\d+)"#, in: text) }

    func installedVersions(customDirectories: [String] = []) async throws -> [KafkaVersion] {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let items = try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            candidates += items.map { $0.appendingPathComponent("bin/kafka-server-start.sh") }
        }
        for dir in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            candidates += [dir.appendingPathComponent("bin/kafka-server-start.sh"), dir.appendingPathComponent("kafka-server-start.sh")]
        }
        var seen = Set<String>()
        var result: [KafkaVersion] = []
        for file in candidates {
            let executable = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted else { continue }
            let parent = executable.deletingLastPathComponent()
            let package = parent.lastPathComponent == "bin" ? parent.deletingLastPathComponent() : parent
            let name = package.lastPathComponent
            let version: String
            if name.hasPrefix("kafka-") { version = String(name.dropFirst("kafka-".count)) }
            else if let javaHome = javaCandidates().first?.directory.path,
                    let probe = try? alias(package, "probe-\(name)"),
                    let output = try? await Command.run(probe.appendingPathComponent("bin/kafka-topics.sh").path, ["--version"], environment: ["JAVA_HOME": javaHome]),
                    let parsed = Self.parseVersion(output.stdout) { version = parsed }
            else { continue }
            result.append(KafkaVersion(version: version, directory: package, executable: executable, source: "Static"))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    func adopt(_ versions: [KafkaVersion]) async {
        guard !supervisor.isRunning else { return }
        guard let existing = supervisor.owned(pidFile: pidFile, binary: "java"),
              let version = versions.first(where: { existing.command.contains(confDirectory(for: $0).path) }) else { return }
        runningVersion = version
        supervisor.adopt(existing)
    }

    // MARK: - 空格路径

    private var aliasRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MacEnv/kafka", isDirectory: true)
    }

    private func alias(_ target: URL, _ name: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: aliasRoot, withIntermediateDirectories: true)
        let link = aliasRoot.appendingPathComponent(name)
        guard (try? fm.destinationOfSymbolicLink(atPath: link.path)) != target.path else { return link }
        try? fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        return link
    }

    // MARK: - 启停

    func start(_ version: KafkaVersion) async throws {
        try prepare(version)
        if let existing = supervisor.owned(pidFile: pidFile, binary: "java") {
            try await supervisor.terminate(existing, force: true)
        }
        guard let javaHome = binding(for: version) else { throw CommandError(message: L("error.kafkaJavaMissing")) }
        let package = try alias(version.directory, "pkg-\(version.version)")
        let logs = try alias(logsURL(for: version), "logs-\(version.version)")
        try await formatStorage(version, javaHome: javaHome, package: package)
        let errorLog = errorLogFile()
        let item = try supervisor.launch(at: package.appendingPathComponent("bin/kafka-server-start.sh"),
                                         arguments: [configURL(for: version).path],
                                         directory: package,
                                         environment: environment(javaHome: javaHome, logs: logs),
                                         errorLog: errorLog)
        let port = ports(for: version).broker
        var ready = false
        for _ in 0..<60 where item.isRunning {
            if let check = try? await Command.run("/usr/bin/nc", ["-z", "-G", "2", "127.0.0.1", String(port)]),
               check.status == 0 { ready = true; break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard ready && item.isRunning else {
            if let target = supervisor.target { try await supervisor.terminate(target, force: true) }
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

    private func formatStorage(_ version: KafkaVersion, javaHome: String, package: URL) async throws {
        guard !FileManager.default.fileExists(atPath: dataURL(for: version).appendingPathComponent("meta.properties").path) else { return }
        let storage = package.appendingPathComponent("bin/kafka-storage.sh")
        let java = ["JAVA_HOME": javaHome]
        let uuid = try await Command.run(storage.path, ["random-uuid"], environment: java)
        let id = uuid.stdout.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        guard uuid.status == 0, !id.isEmpty else { throw CommandError(message: uuid.text + "\n" + L("error.kafkaFormatFailed")) }
        let result = try await Command.run(storage.path, ["format", "-t", id, "-c", configURL(for: version).path], environment: java)
        guard result.status == 0 else { throw CommandError(message: result.text) }
    }

    private func environment(javaHome: String, logs: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["JAVA_HOME"] = javaHome
        environment["PATH"] = javaHome + "/bin:" + (environment["PATH"] ?? "")
        environment["LOG_DIR"] = logs.path
        environment["KAFKA_HEAP_OPTS"] = "-Xmx1G -Xms1G"
        return environment
    }

    func log(_ version: KafkaVersion) -> String {
        let server = readLogTail(logFile(for: version))
        let error = readLogTail(errorLogFile())
        return error.isEmpty ? server : server + "\n" + error
    }

    // MARK: - 版本源

    static let mirrors = ["https://downloads.apache.org/kafka/", "https://archive.apache.org/dist/kafka/"]

    static func parseDirectory(_ html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"href="(\d+\.\d+\.\d+)/""#) else { return [] }
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
            Range($0.range(at: 1), in: html).map { String(html[$0]) }
        }
    }

    static func parseCatalog(_ pages: [(String, String)]) -> [StaticVersion] {
        var chosen: [String: StaticVersion] = [:]
        for (base, html) in pages {
            for version in parseDirectory(html) where version.compare("3.5.0", options: .numeric) != .orderedAscending {
                let group = version.split(separator: ".").prefix(2).joined(separator: ".")
                if let current = chosen[group], current.version.compare(version, options: .numeric) != .orderedAscending { continue }
                chosen[group] = StaticVersion(name: "Kafka-\(version)", version: version,
                                              url: URL(string: "\(base)\(version)/kafka_2.13-\(version).tgz")!,
                                              downloaded: false, installed: false)
            }
        }
        return chosen.values.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    static func versions() async throws -> [StaticVersion] {
        var pages: [(String, String)] = []
        for mirror in mirrors {
            guard let (data, _) = try? await URLSession.shared.data(from: URL(string: mirror)!) else { continue }
            pages.append((mirror, String(decoding: data, as: UTF8.self)))
        }
        guard !pages.isEmpty else { throw CommandError(message: L("error.catalogRequestFailed")) }
        return parseCatalog(pages)
    }
}
