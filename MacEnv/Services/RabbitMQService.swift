import Foundation

@MainActor
final class RabbitMQService {
    let root: URL
    private let supervisor: ProcessSupervisor
    private(set) var runningVersion: RabbitMQVersion?
    var onExit: (() -> Void)?

    var installedErlang: [ErlangVersion] = []

    var bindings: [String: String] = UserDefaults.standard.dictionary(forKey: "macenv.rabbitmq.erlang") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(bindings, forKey: "macenv.rabbitmq.erlang") }
    }

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
        var ini = (try? String(contentsOf: configURL(for: version), encoding: .utf8)) ?? ""
        let original = ini
        ini = IniFile.set("listeners.tcp.default", to: "5672", in: ini)
        ini = IniFile.set("management.tcp.port", to: "15672", in: ini)
        if ini != original { try ini.write(to: configURL(for: version), atomically: true, encoding: .utf8) }
        let content = Self.upsert((try? String(contentsOf: envFile(for: version), encoding: .utf8)) ?? "", [
            "NODE_IP_ADDRESS": "127.0.0.1",
            "NODENAME": "rabbit@localhost",
            "RABBITMQ_LOG_BASE": logDirectory(for: version).path,
            "MNESIA_BASE": mnesiaURL(for: version).path,
            "RABBITMQ_ENABLED_PLUGINS_FILE": pluginsFile(for: version).path,
            "PLUGINS_DIR": version.directory.appendingPathComponent("plugins").path
        ])
        try content.write(to: envFile(for: version), atomically: true, encoding: .utf8)
        if !fm.fileExists(atPath: pluginsFile(for: version).path) {
            try "[rabbitmq_management].\n".write(to: pluginsFile(for: version), atomically: true, encoding: .utf8)
        }
    }

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

    static func otpMajor(_ version: String) -> Int { Int(version.split(separator: ".").first.map(String.init) ?? "") ?? 0 }

    private func compatibleErlang(_ version: String) -> [ErlangVersion] {
        let majors = Self.supportedOtpMajors(version)
        return installedErlang.filter { majors.contains(Self.otpMajor($0.version)) }
            .sorted { a, b in
                let ra = Self.otpMajor(a.version) == majors.first ? 0 : 1
                let rb = Self.otpMajor(b.version) == majors.first ? 0 : 1
                return ra != rb ? ra < rb : a.version.compare(b.version, options: .numeric) == .orderedDescending
            }
    }

    func reconcileBindings(_ installed: [RabbitMQVersion]) {
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
        firstCapture(#"\b(\d+\.\d+(?:\.\d+)?)\b"#, in: text)
    }

    func installedVersions(customDirectories: [String] = []) async throws -> [RabbitMQVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String, String?)] = []
        for item in (try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
            let file = item.appendingPathComponent("sbin/rabbitmq-server")
            if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Static", nil)) }
        }
        for (file, formula) in (try? await Brew.installedBinaries("rabbitmq", binary: "rabbitmq-server", subdirectory: "sbin")) ?? [] {
            candidates.append((file, "Homebrew", formula))
        }
        for (file, formula) in (try? await Brew.installedBinaries("rabbitmq", binary: "rabbitmq-server")) ?? [] {
            candidates.append((file, "Homebrew", formula))
        }
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
            let executable = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted else { continue }
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
        let item = try supervisor.launch(at: version.executable,
                                         arguments: [version.executable.path],
                                         directory: version.executable.deletingLastPathComponent(),
                                         environment: environment(erlang: erlang, version: version),
                                         errorLog: errorLog)
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
        let entries = [erlang + "/bin", version.executable.deletingLastPathComponent().path]
            + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        environment["PATH"] = entries.filter { seen.insert($0).inserted }.joined(separator: ":")
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        environment["RABBITMQ_CONF_ENV_FILE"] = envFile(for: version).path
        environment["RABBITMQ_CONFIG_FILE"] = configURL(for: version).path
        environment["RABBITMQ_SCRIPTS_DIR"] = "."
        environment["RABBITMQ_ALLOW_INPUT"] = "1"
        environment["RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS"] = "-noinput"
        return environment
    }

    func log(_ version: RabbitMQVersion) -> String { readLogTail(logFile(for: version)) }
}
