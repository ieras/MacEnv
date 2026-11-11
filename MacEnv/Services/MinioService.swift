import Foundation

@MainActor
final class MinioService {
    let root: URL
    private let supervisor: ProcessSupervisor
    private(set) var runningVersion: MinioVersion?
    var onExit: (() -> Void)?

    let defaultAPIPort = 9000
    let defaultConsolePort = 9001

    var directory: URL { root.appendingPathComponent("server/minio", isDirectory: true) }
    var versionsDirectory: URL { directory.appendingPathComponent("versions", isDirectory: true) }
    var logDirectory: URL { directory.appendingPathComponent("log", isDirectory: true) }
    var configFile: URL { directory.appendingPathComponent("minio.conf") }
    var pidFile: URL { directory.appendingPathComponent("minio.pid") }
    var dataDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: "macenv.minio.dataDir"), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return directory.appendingPathComponent("data", isDirectory: true)
    }

    init(root: URL) {
        self.root = root
        supervisor = ProcessSupervisor(marker: root.appendingPathComponent("server/minio", isDirectory: true).path)
        supervisor.onExit = { [weak self] in
            self?.runningVersion = nil
            self?.onExit?()
        }
    }

    func logFile() -> URL { logDirectory.appendingPathComponent("minio.log") }
    func errorLogFile() -> URL { logDirectory.appendingPathComponent("minio.start.err.log") }

    func running(_ version: MinioVersion) -> Bool { supervisor.isRunning && runningVersion?.id == version.id }

    func configText() -> String { (try? String(contentsOf: configFile, encoding: .utf8)) ?? "" }

    // MARK: - 配置解析

    static func parseConf(_ content: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in content.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("MINIO_"), let separator = text.firstIndex(of: "=") else { continue }
            let key = String(text[..<separator]).trimmingCharacters(in: .whitespaces)
            result[key] = String(text[text.index(after: separator)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        return result
    }

    static func normalizeAddress(_ value: String, fallback: String) -> String {
        let text = value.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return fallback }
        if text.allSatisfy(\.isNumber) { return "127.0.0.1:" + text }
        if text.hasPrefix(":") { return "127.0.0.1" + text }
        return text.contains(":") ? text : fallback
    }

    static func port(_ address: String, fallback: Int) -> Int {
        if let colon = address.lastIndex(of: ":"), let value = Int(address[address.index(after: colon)...]) { return value }
        return Int(address) ?? fallback
    }

    static func parseVersion(_ text: String) -> String? {
        firstCapture(#"(?i)version\s+(RELEASE\.[0-9A-Za-z:.\-]+|[0-9][0-9A-Za-z.\-]*)"#, in: text)
    }

    func ports() -> (api: Int, console: Int) {
        let conf = Self.parseConf(configText())
        let console = Self.normalizeAddress(conf["MINIO_CONSOLE_ADDRESS"] ?? "", fallback: "127.0.0.1:\(defaultConsolePort)")
        return (Self.port(conf["MINIO_ADDRESS"] ?? "", fallback: defaultAPIPort),
                Self.port(console, fallback: defaultConsolePort))
    }

    func consoleURL() -> URL { URL(string: "http://127.0.0.1:\(ports().console)/")! }

    func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: versionsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: configFile.path) else { return }
        let config = """
        # MinIO environment variables. Lines starting with # are ignored.
        MINIO_ADDRESS=:9000
        MINIO_CONSOLE_ADDRESS=:9001
        MINIO_ROOT_USER=minioadmin
        MINIO_ROOT_PASSWORD=minioadmin
        # MINIO_CERTS_DIR=\(NSHomeDirectory())/.minio/certs
        """
        try config.write(to: configFile, atomically: true, encoding: .utf8)
    }

    // MARK: - 已安装

    func installedVersions(customDirectories: [String] = []) async throws -> [MinioVersion] {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let items = try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for item in items {
                for path in ["bin/minio", "minio"] {
                    let file = item.appendingPathComponent(path)
                    if fm.isExecutableFile(atPath: file.path) { candidates.append(file); break }
                }
            }
        }
        for dir in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            for path in ["minio", "bin/minio"] {
                let file = dir.appendingPathComponent(path)
                if fm.isExecutableFile(atPath: file.path) { candidates.append(file); break }
            }
        }
        var seen = Set<String>()
        var result: [MinioVersion] = []
        for file in candidates {
            let executable = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted else { continue }
            let parent = executable.deletingLastPathComponent()
            let package = ["bin", "sbin"].contains(parent.lastPathComponent) ? parent.deletingLastPathComponent() : parent
            let version: String
            if package.deletingLastPathComponent().standardizedFileURL == versionsDirectory.standardizedFileURL,
               package.lastPathComponent.hasPrefix("minio-") {
                version = String(package.lastPathComponent.dropFirst("minio-".count))
            } else {
                let output = try await Command.run(executable.path, ["--version"])
                guard let parsed = Self.parseVersion(output.text) else { continue }
                version = parsed
            }
            result.append(MinioVersion(version: version, directory: package, executable: executable, source: "Static"))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    func adopt(_ versions: [MinioVersion]) async {
        guard !supervisor.isRunning else { return }
        guard let existing = supervisor.owned(pidFile: pidFile, binary: "minio"),
              let version = versions.first(where: { $0.executable.path == existing.executable }) else { return }
        runningVersion = version
        supervisor.adopt(existing)
    }

    // MARK: - 进程

    func start(_ version: MinioVersion) async throws {
        try prepare()
        _ = try? await Command.run("/usr/bin/xattr", ["-cr", version.executable.path])
        if let existing = supervisor.owned(pidFile: pidFile, binary: "minio") {
            try await supervisor.terminate(existing, force: true)
        }
        let conf = Self.parseConf(configText())
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in conf { environment[key] = value }
        var arguments = ["server", dataDirectory.path]
        if let address = conf["MINIO_ADDRESS"], !address.isEmpty {
            arguments += ["--address", address]
        }
        let console = Self.normalizeAddress(conf["MINIO_CONSOLE_ADDRESS"] ?? "", fallback: "127.0.0.1:\(defaultConsolePort)")
        environment["MINIO_CONSOLE_ADDRESS"] = console
        arguments += ["--console-address", console]
        if let certs = conf["MINIO_CERTS_DIR"], !certs.isEmpty {
            arguments += ["--certs-dir", certs]
        }
        let item = try supervisor.launch(at: version.executable, arguments: arguments,
                                         directory: version.directory, environment: environment,
                                         errorLog: errorLogFile(), outputLog: logFile())
        let apiPort = Self.port(conf["MINIO_ADDRESS"] ?? "", fallback: defaultAPIPort)
        var ready = false
        for _ in 0..<40 where item.isRunning {
            if let output = try? await Command.run("/usr/bin/curl", ["-s", "--fail", "--noproxy", "*", "--max-time", "1", "-o", "/dev/null", "http://127.0.0.1:\(apiPort)/minio/health/live"]),
               output.status == 0 { ready = true; break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard ready && item.isRunning else {
            if let target = supervisor.target { try await supervisor.terminate(target, force: true) }
            throw CommandError(message: ((try? String(contentsOf: errorLogFile(), encoding: .utf8)) ?? "") + "\n" + L("error.serviceStartTimeout"))
        }
        runningVersion = version
        try String(item.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
    }

    func stop() async throws {
        guard let target = supervisor.target ?? supervisor.owned(pidFile: pidFile, binary: "minio") else {
            supervisor.forget()
            runningVersion = nil
            try? FileManager.default.removeItem(at: pidFile)
            return
        }
        try await supervisor.terminate(target, force: true)
        runningVersion = nil
        try? FileManager.default.removeItem(at: pidFile)
    }

    func log() -> String {
        let output = readLogTail(logFile())
        let error = readLogTail(errorLogFile())
        return error.isEmpty ? output : output + "\n" + error
    }
}
