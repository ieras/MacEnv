import Foundation

@MainActor
final class DatabaseService {
    let kind: DatabaseKind
    let root: URL
    private let supervisor: ProcessSupervisor
    private(set) var runningVersion: DatabaseVersion?
    var onExit: (() -> Void)?

    var directory: URL { root.appendingPathComponent("server/\(kind.rawValue)", isDirectory: true) }
    var versionsDirectory: URL { directory.appendingPathComponent("versions", isDirectory: true) }
    func errorLog(for version: DatabaseVersion) -> URL { directory.appendingPathComponent("error-\(version.majorMinor).log") }
    func slowLog(for version: DatabaseVersion) -> URL { directory.appendingPathComponent("slow-\(version.majorMinor).log") }
    var pidFile: URL { directory.appendingPathComponent("\(kind.rawValue).pid") }

    init(kind: DatabaseKind, root: URL) {
        self.kind = kind
        self.root = root
        supervisor = ProcessSupervisor(marker: root.appendingPathComponent("server/\(kind.rawValue)", isDirectory: true).path)
        supervisor.onExit = { [weak self] in
            self?.runningVersion = nil
            self?.onExit?()
        }
    }

    func configURL(for version: DatabaseVersion) -> URL { directory.appendingPathComponent("my-\(version.majorMinor).cnf") }
    func dataURL(for version: DatabaseVersion) -> URL { directory.appendingPathComponent("data-\(version.majorMinor)", isDirectory: true) }

    func running(_ version: DatabaseVersion) -> Bool { supervisor.isRunning && runningVersion?.id == version.id }

    func port(for version: DatabaseVersion) -> Int {
        guard let content = try? String(contentsOf: configURL(for: version), encoding: .utf8),
              let value = configValue("port", content: content),
              let port = Int(value) else { return kind.defaultPort }
        return port
    }

    func prepare(_ version: DatabaseVersion) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.createDirectory(at: versionsDirectory, withIntermediateDirectories: true)
        let file = configURL(for: version)
        guard !fm.fileExists(atPath: file.path) else { return }
        let logOption = kind == .mysql ? "slow-query-log" : "slow_query_log"
        let logFileOption = kind == .mysql ? "slow-query-log-file" : "slow_query_log_file"
        let errorOption = kind == .mysql ? "log-error" : "log_error"
        let pidOption = kind == .mysql ? "pid-file" : "pid_file"
        let content = """
        [\(kind.configSection)]
        bind-address=127.0.0.1
        port=\(kind.defaultPort)
        socket=\(kind.socketPath)
        datadir=\(dataURL(for: version).path)
        \(pidOption)=\(pidFile.path)
        \(errorOption)=\(errorLog(for: version).path)
        \(logOption)=ON
        \(logFileOption)=\(slowLog(for: version).path)
        sql-mode=NO_ENGINE_SUBSTITUTION
        """
        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    func installedVersions(customDirectories: [String] = []) async throws -> [DatabaseVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String, String?)] = []
        for (file, formula) in try await Brew.installedBinaries(kind.rawValue, binary: kind.binaryName) {
            candidates.append((file, "Homebrew", formula))
        }
        if let items = try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for item in items {
                for path in ["bin/\(kind.binaryName)", "sbin/\(kind.binaryName)", kind.binaryName] {
                    let file = item.appendingPathComponent(path)
                    if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Static", nil)); break }
                }
            }
        }
        for directory in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            for path in [kind.binaryName, "bin/\(kind.binaryName)", "sbin/\(kind.binaryName)"] {
                let file = directory.appendingPathComponent(path)
                if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Static", nil)) }
            }
        }
        if let items = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/opt/local/lib", isDirectory: true), includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for item in items where item.lastPathComponent.lowercased().hasPrefix(kind.rawValue) {
                let file = item.appendingPathComponent("bin/\(kind.binaryName)")
                if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "MacPorts", nil)) }
            }
        }
        var seen = Set<String>()
        var result: [DatabaseVersion] = []
        for (file, source, formula) in candidates {
            let executable = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted else { continue }
            let output = try await Command.run(executable.path, ["--version"])
            guard let version = versionFromOutput(output.text) else { continue }
            result.append(DatabaseVersion(kind: kind, version: version, directory: executable.deletingLastPathComponent().deletingLastPathComponent(), executable: executable, source: source, formula: formula))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    func brewFormulae() async throws -> [BrewFormulaItem] { try await Brew.formulae(kind.rawValue) }

    func adopt(_ versions: [DatabaseVersion]) async {
        guard !supervisor.isRunning else { return }
        guard let existing = try? await supervisor.find(kind.binaryName), let version = versions.first(where: { existing.command.contains(configURL(for: $0).path) }) else { return }
        runningVersion = version
        supervisor.adopt(existing)
        try? String(existing.pid).write(to: pidFile, atomically: true, encoding: .utf8)
    }

    func start(_ version: DatabaseVersion) async throws {
        try prepare(version)
        if let existing = try await supervisor.find(kind.binaryName) {
            try await supervisor.terminate(existing, graceful: { try? await self.shutdown(version) }, force: true)
        }
        let data = dataURL(for: version)
        let passwordPending = data.appendingPathComponent(".macenv-password-pending")
        if !FileManager.default.fileExists(atPath: data.appendingPathComponent("mysql").path) {
            if let contents = try? FileManager.default.contentsOfDirectory(at: data, includingPropertiesForKeys: nil), !contents.isEmpty {
                throw CommandError(message: String(format: L("error.databaseDataDirIncomplete"), kind.title, data.lastPathComponent))
            }
            try await initialize(version, config: configURL(for: version), data: data)
            try Data().write(to: passwordPending)
        }
        let startupLog = directory.appendingPathComponent("\(kind.rawValue)-\(version.version)-start-error.log")
        let item = try supervisor.launch(at: version.executable,
                                         arguments: ["--defaults-file=\(configURL(for: version).path)"],
                                         directory: version.directory,
                                         environment: ProcessInfo.processInfo.environment,
                                         errorLog: startupLog)
        do {
            for _ in 0..<150 where item.isRunning && !FileManager.default.fileExists(atPath: kind.socketPath) {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard item.isRunning && FileManager.default.fileExists(atPath: kind.socketPath) else {
                throw CommandError(message: ((try? String(contentsOf: startupLog, encoding: .utf8)) ?? "") + "\n" + L("error.serviceStartTimeout"))
            }
            runningVersion = version
            try String(item.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
            if FileManager.default.fileExists(atPath: passwordPending.path) {
                try await setRootPassword(version)
                try FileManager.default.removeItem(at: passwordPending)
            }
        } catch {
            try await Task { @MainActor in
                if let target = supervisor.target { try await supervisor.terminate(target, force: true) }
            }.value
            runningVersion = nil
            throw error
        }
    }

    func stop() async throws {
        guard let target = try await supervisor.find(kind.binaryName) else {
            supervisor.forget()
            runningVersion = nil
            try? FileManager.default.removeItem(at: pidFile)
            return
        }
        if let version = runningVersion { try await supervisor.terminate(target, graceful: { try? await self.shutdown(version) }, force: true) }
        else { try await supervisor.terminate(target, force: true) }
        runningVersion = nil
        try? FileManager.default.removeItem(at: pidFile)
        try? FileManager.default.removeItem(atPath: kind.socketPath)
    }

    private func shutdown(_ version: DatabaseVersion) async throws {
        let admin = version.executable.deletingLastPathComponent().appendingPathComponent(kind.adminBinaryName)
        guard FileManager.default.isExecutableFile(atPath: admin.path) else { return }
        _ = try await Command.run(admin.path, ["--connect-timeout=3", "--socket=\(kind.socketPath)", "-uroot", "-proot", "shutdown"])
    }

    private func setRootPassword(_ version: DatabaseVersion) async throws {
        let names = kind == .mysql ? [kind.adminBinaryName] : [kind.adminBinaryName, "mysqladmin"]
        guard let admin = names.map({ version.directory.appendingPathComponent("bin/\($0)") }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw CommandError(message: L("error.binaryMissing") + kind.adminBinaryName) }
        let output = try await Command.run(admin.path, ["--socket=\(kind.socketPath)", "-uroot", "password", "root"])
        guard output.status == 0 else { throw CommandError(message: output.text) }
    }

    private func initialize(_ version: DatabaseVersion, config: URL, data: URL) async throws {
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        if kind == .mysql {
            let output = try await Command.run(version.executable.path, ["--defaults-file=\(config.path)", "--initialize-insecure"])
            guard output.status == 0 else { throw CommandError(message: output.text) }
        } else {
            let names = ["mariadb-install-db", "mysql_install_db"]
            guard let installer = names.map({ version.directory.appendingPathComponent("bin/\($0)") }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
                throw CommandError(message: L("error.mariadbInstallerMissing"))
            }
            let output = try await Command.run(installer.path, ["--no-defaults", "--datadir=\(data.path)", "--basedir=\(version.directory.path)", "--auth-root-authentication-method=normal"])
            guard output.status == 0 else { throw CommandError(message: output.text) }
        }
    }

    func log(_ name: String, for version: DatabaseVersion) -> String {
        readLogTail(name == "error" ? errorLog(for: version) : slowLog(for: version))
    }

    private func configValue(_ key: String, content: String) -> String? {
        for line in content.split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.hasPrefix("#"), let index = value.firstIndex(of: "=") else { continue }
            guard value[..<index].trimmingCharacters(in: .whitespacesAndNewlines) == key else { continue }
            return value[value.index(after: index)...].trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    private func versionFromOutput(_ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\d+(?:\.\d+){1,3}"#) else { return nil }
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }
}
