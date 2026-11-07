import Foundation

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

    func ports(_ version: EtcdVersion) -> (client: Int, peer: Int) {
        let text = configText(version)
        return (Self.port(in: text, key: "listen-client-urls") ?? 2379,
                Self.port(in: text, key: "listen-peer-urls") ?? 2380)
    }

    private static func port(in text: String, key: String) -> Int? {
        guard let range = text.range(of: key) else { return nil }
        return firstCapture(#":(\d{2,5})"#, in: String(text[range.upperBound...].prefix(200))).flatMap(Int.init)
    }

    func prepare(_ version: EtcdVersion) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.createDirectory(at: dataDirectory(version), withIntermediateDirectories: true)
        try fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: configFile(version).path) {
            try configContent(version).write(to: configFile(version), atomically: true, encoding: .utf8)
        }
    }

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

    static func parseVersion(_ text: String) -> String? {
        firstCapture(#"etcd Version: (\d+(?:\.\d+){1,4})"#, in: text)
    }

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
        let port = ports(version).client
        do {
            var ready = false
            for _ in 0..<50 where item.isRunning {
                if let output = try? await Command.run("/usr/bin/curl", ["-s", "--fail", "--noproxy", "*", "--max-time", "1", "http://127.0.0.1:\(port)/health"]),
                   output.status == 0 { ready = true; break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            guard ready && item.isRunning else {
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
        try await supervisor.terminate(target, force: true)
        runningVersion = nil
        try? FileManager.default.removeItem(at: pidFile)
    }

    func log() -> String { readLogTail(logFile()) }
}
