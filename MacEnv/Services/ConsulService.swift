import Foundation

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

    func ports(_ version: ConsulVersion) -> (http: Int, dns: Int) {
        let object = (try? JSONSerialization.jsonObject(with: Data(configText(version).utf8))) as? [String: Any]
        let ports = object?["ports"] as? [String: Any]
        return ((ports?["http"] as? Int) ?? 8500, (ports?["dns"] as? Int) ?? 8600)
    }

    func prepare(_ version: ConsulVersion) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.createDirectory(at: dataDirectory(version), withIntermediateDirectories: true)
        try fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: configFile(version).path) {
            try configContent(version).write(to: configFile(version), atomically: true, encoding: .utf8)
        }
    }

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

    static func parseVersion(_ text: String) -> String? {
        firstCapture(#"Consul v(\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?)"#, in: text)
    }

    // 过期元数据
    static func clearStaleServerMetadata(_ dataDirectory: URL) {
        let fm = FileManager.default
        let file = dataDirectory.appendingPathComponent("server_metadata.json")
        guard let data = try? Data(contentsOf: file),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let lastSeen = (object["last_seen_unix"] as? NSNumber)?.doubleValue else { return }
        let maxAge: TimeInterval = 168 * 3600
        guard Date().timeIntervalSince1970 - lastSeen > maxAge else { return }
        let backup = dataDirectory.appendingPathComponent("server_metadata.json.stale.bak")
        try? fm.removeItem(at: backup)
        try? fm.moveItem(at: file, to: backup)
    }

    func installedVersions(customDirectories: [String] = []) async throws -> [ConsulVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String)] = []
        if let items = try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for item in items {
                for path in ["bin/consul", "consul"] {
                    let file = item.appendingPathComponent(path)
                    if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Static")) }
                }
            }
        }
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
        Self.clearStaleServerMetadata(dataDirectory(version))
        if let existing = supervisor.owned(pidFile: pidFile, binary: "consul") {
            try await supervisor.terminate(existing, force: true)
        }
        let item = try supervisor.launch(at: version.executable,
                                         arguments: ["agent", "-config-file=\(configFile(version).path)"],
                                         directory: version.directory,
                                         environment: ProcessInfo.processInfo.environment,
                                         errorLog: logDirectory.appendingPathComponent("consul.start.err.log"))
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
        try await supervisor.terminate(target, force: true)
        runningVersion = nil
        try? FileManager.default.removeItem(at: pidFile)
    }

    func log() -> String { readLogTail(logFile()) }
}
