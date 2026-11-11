import Foundation

@MainActor
final class RustFSService {
    let root: URL
    private let supervisor: ProcessSupervisor
    private(set) var runningVersion: RustFSVersion?
    var onExit: (() -> Void)?

    var directory: URL { root.appendingPathComponent("server/rustfs", isDirectory: true) }
    var versionsDirectory: URL { directory.appendingPathComponent("versions", isDirectory: true) }
    var pidFile: URL { directory.appendingPathComponent("rustfs.pid") }
    var configURL: URL { directory.appendingPathComponent("rustfs.conf") }
    // 数据目录（无空格路径）
    var defaultDataURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".rustfs/data", isDirectory: true) }

    var dataDirectories: [String: String] = UserDefaults.standard.dictionary(forKey: "macenv.rustfs.dataDirs") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(dataDirectories, forKey: "macenv.rustfs.dataDirs") }
    }

    static let defaultConfig = """
    # RustFS configuration. Uncomment a line to enable it, then restart the service.
    # RUSTFS_ADDRESS=:9000
    # RUSTFS_SERVER_DOMAINS=
    # RUSTFS_ACCESS_KEY=
    # RUSTFS_ACCESS_KEY_FILE=
    # RUSTFS_SECRET_KEY=
    # RUSTFS_SECRET_KEY_FILE=
    # RUSTFS_CONSOLE_ENABLE=true
    # RUSTFS_CONSOLE_ADDRESS=:9001
    # RUSTFS_OBS_ENDPOINT=
    # RUSTFS_TLS_PATH=
    # RUSTFS_LICENSE=
    # RUSTFS_REGION=
    # RUSTFS_KMS_ENABLE=false
    # RUSTFS_KMS_BACKEND=local
    # RUSTFS_KMS_KEY_DIR=
    # RUSTFS_KMS_VAULT_ADDRESS=
    # RUSTFS_KMS_VAULT_TOKEN=
    # RUSTFS_KMS_DEFAULT_KEY_ID=
    # RUSTFS_BUFFER_PROFILE_DISABLE=false
    # RUSTFS_BUFFER_PROFILE=GeneralPurpose
    """

    init(root: URL) {
        self.root = root
        supervisor = ProcessSupervisor(marker: root.appendingPathComponent("server/rustfs", isDirectory: true).path)
        supervisor.onExit = { [weak self] in
            self?.runningVersion = nil
            self?.onExit?()
        }
    }

    func dataURL(for version: RustFSVersion) -> URL {
        guard let path = dataDirectories[version.executable.path] else { return defaultDataURL }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func setDataURL(_ url: URL, for version: RustFSVersion) { dataDirectories[version.executable.path] = url.path }

    func logURL(_ version: RustFSVersion, error: Bool) -> URL {
        directory.appendingPathComponent("rustfs-\(version.version)-start-\(error ? "error" : "out").log")
    }

    func log(_ version: RustFSVersion, error: Bool) -> String { readLogTail(logURL(version, error: error)) }

    func running(_ version: RustFSVersion) -> Bool { supervisor.isRunning && runningVersion?.id == version.id }

    // MARK: - 配置解析

    static func parseConf(_ content: String) -> [String: String] {
        var env: [String: String] = [:]
        for line in content.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("RUSTFS_"), let eq = text.firstIndex(of: "=") else { continue }
            env[String(text[..<eq])] = String(text[text.index(after: eq)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        return env
    }

    func ports() -> (api: Int, console: Int) {
        let env = Self.parseConf((try? String(contentsOf: configURL, encoding: .utf8)) ?? "")
        let api = Int((env["RUSTFS_ADDRESS"] ?? "").split(separator: ":").last.map(String.init) ?? "") ?? 9000
        let console = Int((env["RUSTFS_CONSOLE_ADDRESS"] ?? "").split(separator: ":").last.map(String.init) ?? "") ?? 9001
        return (api, console)
    }

    static func parseVersion(_ text: String) -> String? {
        firstCapture(#"(?i)rustfs[^\n]*?v?(\d+(?:\.\d+){1,3})"#, in: text)
    }

    func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.createDirectory(at: versionsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: defaultDataURL, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: configURL.path) else { return }
        try Self.defaultConfig.write(to: configURL, atomically: true, encoding: .utf8)
    }

    // MARK: - 版本扫描

    func installedVersions(customDirectories: [String] = []) async throws -> [RustFSVersion] {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let items = try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for item in items {
                let file = item.appendingPathComponent("bin/rustfs")
                if fm.isExecutableFile(atPath: file.path) { candidates.append(file) }
            }
        }
        for dir in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            for path in ["rustfs", "bin/rustfs"] {
                let file = dir.appendingPathComponent(path)
                if fm.isExecutableFile(atPath: file.path) { candidates.append(file) }
            }
        }
        var seen = Set<String>()
        var result: [RustFSVersion] = []
        for file in candidates {
            let executable = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted else { continue }
            let output = try await Command.run(executable.path, ["--version"])
            guard let version = Self.parseVersion(output.text) else { continue }
            let parent = executable.deletingLastPathComponent()
            let package = parent.lastPathComponent == "bin" ? parent.deletingLastPathComponent() : parent
            result.append(RustFSVersion(version: version, directory: package,
                                        executable: executable, source: "Static"))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    func adopt(_ versions: [RustFSVersion]) async {
        guard !supervisor.isRunning else { return }
        guard let existing = supervisor.owned(pidFile: pidFile, binary: "rustfs"),
              let version = versions.first(where: { $0.executable.path == existing.executable }) else { return }
        runningVersion = version
        supervisor.adopt(existing)
    }

    // MARK: - 启停

    func start(_ version: RustFSVersion) async throws {
        try prepare()
        if let existing = supervisor.owned(pidFile: pidFile, binary: "rustfs") {
            try await supervisor.terminate(existing, force: true)
        }
        let env = Self.parseConf((try? String(contentsOf: configURL, encoding: .utf8)) ?? "")
        let data = dataURL(for: version)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let errorLog = logURL(version, error: true)
        let item = try supervisor.launch(at: version.executable,
                                         arguments: ["server", data.path],
                                         directory: version.directory,
                                         environment: ProcessInfo.processInfo.environment.merging(env) { _, new in new },
                                         errorLog: errorLog,
                                         outputLog: logURL(version, error: false))
        let port = ports().api
        var ready = false
        for _ in 0..<20 where item.isRunning {
            if let output = try? await Command.run("/usr/bin/curl", ["-s", "-o", "/dev/null", "--noproxy", "*", "--connect-timeout", "1", "--max-time", "2", "http://127.0.0.1:\(port)/"]),
               output.status == 0 { ready = true; break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard ready && item.isRunning else {
            if let target = supervisor.target { try await supervisor.terminate(target, force: true) }
            throw CommandError(message: ((try? String(contentsOf: errorLog, encoding: .utf8)) ?? "") + "\n" + L("error.serviceStartTimeout"))
        }
        runningVersion = version
        try String(item.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
    }

    func stop() async throws {
        guard let target = supervisor.target ?? supervisor.owned(pidFile: pidFile, binary: "rustfs") else {
            supervisor.forget()
            runningVersion = nil
            try? FileManager.default.removeItem(at: pidFile)
            return
        }
        try await supervisor.terminate(target, force: true)
        runningVersion = nil
        try? FileManager.default.removeItem(at: pidFile)
    }
}
