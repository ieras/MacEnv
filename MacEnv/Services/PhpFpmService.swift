import Foundation

@MainActor
final class PhpFpmService {
    let root: URL
    private var supervisors: [String: ProcessSupervisor] = [:]
    var onExit: (() -> Void)?

    var directory: URL { root.appendingPathComponent("server/php-fpm", isDirectory: true) }


    init(root: URL) { self.root = root }

    private func num(_ version: PhpVersion) -> String { version.version.split(separator: ".").prefix(2).joined() }

    private func supervisor(_ version: PhpVersion) -> ProcessSupervisor {
        if let item = supervisors[num(version)] { return item }
        let item = ProcessSupervisor(marker: versionDirectory(version).path)
        item.onExit = { [weak self] in self?.onExit?() }
        supervisors[num(version)] = item
        return item
    }

    func running(_ version: PhpVersion) -> Bool { supervisor(version).target?.executable == version.fpm.resolvingSymlinksInPath().path }
    var anyRunning: Bool { supervisors.values.contains { $0.isRunning } }

    func configURL(_ version: PhpVersion) -> URL { versionDirectory(version).appendingPathComponent("php-fpm.conf") }
    func socketPath(_ version: PhpVersion) -> String { "/tmp/macenv-php-cgi-\(num(version)).sock" }

    private func versionDirectory(_ version: PhpVersion) -> URL { directory.appendingPathComponent(num(version), isDirectory: true) }

    func prepare(_ version: PhpVersion) throws {
        let fm = FileManager.default
        let base = versionDirectory(version)
        for path in ["log", "run"] { try fm.createDirectory(at: base.appendingPathComponent(path), withIntermediateDirectories: true) }
        let file = configURL(version)
        guard !fm.fileExists(atPath: file.path),
              let template = Bundle.main.url(forResource: "PhpDefaults", withExtension: nil)?.appendingPathComponent("php-fpm.conf") else { return }
        try String(contentsOf: template, encoding: .utf8)
            .replacingOccurrences(of: "##PHP-CGI-VERSION##", with: num(version))
            .write(to: file, atomically: true, encoding: .utf8)
    }

    func adopt(_ versions: [PhpVersion]) async {
        for version in versions { try? prepare(version) }
        if !anyRunning {
            let live = Set(versions.map { num($0) })
            for item in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            where !live.contains(item.lastPathComponent) {
                try? FileManager.default.removeItem(at: item)
            }
        }
        for version in versions {
            let item = supervisor(version)
            guard !item.isRunning else { continue }
            let existing = try? await item.find("php-fpm")
            guard let target = existing,
                  target.executable == version.fpm.resolvingSymlinksInPath().path else { continue }
            item.adopt(target)
        }
    }

    func start(_ version: PhpVersion) async throws {
        guard FileManager.default.isExecutableFile(atPath: version.fpm.path) else { throw CommandError(message: L("error.phpFpmMissing")) }
        try prepare(version)
        let item = supervisor(version)
        if running(version) { return }
        if let target = item.target { try await item.terminate(target) }
        let base = versionDirectory(version)
        let startupLog = base.appendingPathComponent("log/start-error.log")
        let process = try item.launch(at: version.fpm,
                                      arguments: ["-p", base.path, "-y", configURL(version).path,
                                                  "-g", base.appendingPathComponent("run/php-fpm.pid").path, "-F"],
                                      directory: version.directory,
                                      environment: ProcessInfo.processInfo.environment,
                                      errorLog: startupLog)
        do {
            for _ in 0..<100 where process.isRunning && !FileManager.default.fileExists(atPath: socketPath(version)) {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard process.isRunning && FileManager.default.fileExists(atPath: socketPath(version)) else {
                throw CommandError(message: ((try? String(contentsOf: startupLog, encoding: .utf8)) ?? "") + "\n" + L("error.serviceStartTimeout"))
            }
        } catch {
            try await Task { @MainActor in
                if let target = item.target { try await item.terminate(target, force: true) }
            }.value
            throw error
        }

    }

    func stop(_ version: PhpVersion) async throws {
        let item = supervisor(version)
        guard running(version) else { return }
        guard let target = item.target else {
            item.forget()
            return
        }
        try await item.terminate(target)
    }

    func stopAll() async throws {
        for item in supervisors.values where item.isRunning {
            if let target = try await item.find("php-fpm") { try await item.terminate(target) }
            else { item.forget() }
        }
    }

    func logPath(_ version: PhpVersion, kind: String) -> URL {
        let name = ["slow": "php-fpm-slow.log", "start": "start-error.log"][kind] ?? "php-fpm.log"
        return versionDirectory(version).appendingPathComponent("log/\(name)")
    }

    func log(_ version: PhpVersion, kind: String) -> String { readLogTail(logPath(version, kind: kind)) }
}
