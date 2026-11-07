import Foundation

@MainActor
final class Neo4jService {
    let root: URL
    private let supervisor: ProcessSupervisor
    private(set) var runningVersion: Neo4jVersion?
    var onExit: (() -> Void)?

    var installedJava: [JavaVersion] = []

    var bindings: [String: String] = UserDefaults.standard.dictionary(forKey: "macenv.neo4j.java") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(bindings, forKey: "macenv.neo4j.java") }
    }

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
            "server.default_listen_address": "127.0.0.1"
        ])
        if content != existing { try content.write(to: file, atomically: true, encoding: .utf8) }
    }

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

    static func javaMajor(_ version: String) -> Int { Int(version.split(separator: ".").first.map(String.init) ?? "") ?? 0 }

    private func compatibleJava(_ version: String) -> [JavaVersion] {
        let majors = Self.supportedJavaMajors(version)
        return installedJava.filter { majors.contains(Self.javaMajor($0.version)) }
            .sorted { a, b in
                let ra = Self.javaMajor(a.version) == majors.first ? 0 : 1
                let rb = Self.javaMajor(b.version) == majors.first ? 0 : 1
                return ra != rb ? ra < rb : a.version.compare(b.version, options: .numeric) == .orderedDescending
            }
    }

    func reconcileBindings(_ installed: [Neo4jVersion]) {
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
            guard let javaHome = installedJava.first?.directory.path,
                  let output = try? await Command.run(executable.path, ["version"], environment: ["JAVA_HOME": javaHome]),
                  let version = Self.parseVersion(output.text) else { continue }
            result.append(Neo4jVersion(version: version, directory: executable.deletingLastPathComponent().deletingLastPathComponent(), executable: executable, source: source))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    func adopt(_ versions: [Neo4jVersion]) async {
        guard !supervisor.isRunning else { return }
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
        try? FileManager.default.removeItem(at: version.directory.appendingPathComponent("run/neo4j.pid"))
        let ports = self.ports(for: version)
        let errorLog = directory.appendingPathComponent("neo4j-\(version.version)-start-error.log")
        let item = try supervisor.launch(at: URL(fileURLWithPath: "/bin/sh"),
                                         arguments: [version.executable.path, "console"],
                                         directory: version.directory,
                                         environment: self.environment(javaHome: javaHome, version: version),
                                         errorLog: errorLog)
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
