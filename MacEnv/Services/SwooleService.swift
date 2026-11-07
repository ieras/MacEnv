import Foundation

@MainActor
final class SwooleService {
    let root: URL

    var directory: URL { root.appendingPathComponent("server/swoole-cli", isDirectory: true) }
    var versionsDirectory: URL { directory.appendingPathComponent("versions", isDirectory: true) }
    private var archives: URL { root.appendingPathComponent("cache", isDirectory: true) }

    private let composerURL = URL(string: "https://getcomposer.org/download/latest-stable/composer.phar")!
    private let cacertURL = URL(string: "https://curl.se/ca/cacert.pem")!

    init(root: URL) { self.root = root }

    func installedVersions(customDirectories: [String] = []) async throws -> [SwooleVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String)] = []
        for item in (try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
            for path in ["bin/swoole-cli", "swoole-cli"] {
                let file = item.appendingPathComponent(path)
                if fm.isExecutableFile(atPath: file.path) { candidates.append((file, "Static")); break }
            }
        }
        for item in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            for path in ["swoole-cli", "bin/swoole-cli"] {
                let file = item.appendingPathComponent(path)
                if fm.isExecutableFile(atPath: file.path) { candidates.append((file, L("source.custom"))) }
            }
        }
        var seen = Set<String>()
        var result: [SwooleVersion] = []
        for (file, source) in candidates {
            let executable = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted else { continue }
            try? await prepareRuntime(executable, download: false)
            guard let probe = try? await probe(executable) else { continue }
            result.append(SwooleVersion(version: probe.swoole,
                                        phpVersion: probe.php,
                                        directory: executable.deletingLastPathComponent().deletingLastPathComponent(),
                                        executable: executable,
                                        source: source))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    func install(_ version: StaticVersion, report: @escaping (String) -> Void = { _ in }, onStart: ((Process) -> Void)? = nil) async throws {
        let archive = archives.appendingPathComponent("static-swoole-cli-\(version.version).tar.\(version.url.pathExtension)")
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        try await Command.download(version.url, to: archive, report: report, onStart: onStart)

        let target = versionsDirectory.appendingPathComponent("swoole-cli-\(version.version)")
        try? FileManager.default.removeItem(at: target)
        let bin = target.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let status = try await Command.stream("/usr/bin/tar", ["-xJf", archive.path, "-C", bin.path], onOutput: report)
        guard status == 0 else { throw CommandError(message: L("error.unpackFailed") + "（\(status)）") }
        let executable = bin.appendingPathComponent("swoole-cli")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CommandError(message: L("error.binaryMissing") + "swoole-cli")
        }
        try await prepareRuntime(executable, download: true, report: report)
    }

    private func probe(_ executable: URL) async throws -> (swoole: String, php: String) {
        let ini = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("php.ini")
        var arguments = FileManager.default.fileExists(atPath: ini.path) ? ["-c", ini.path] : []
        arguments += ["-r", "echo PHP_VERSION, \" \", swoole_version();"]
        let output = try await Command.run(executable.path, arguments)
        let parts = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard output.status == 0, parts.count == 2 else { throw CommandError(message: output.text) }
        return (String(parts[1]), String(parts[0]))
    }

    private func prepareRuntime(_ executable: URL, download: Bool, report: @escaping (String) -> Void = { _ in }) async throws {
        let fm = FileManager.default
        let bin = executable.deletingLastPathComponent()
        let base = bin.deletingLastPathComponent()

        let php = bin.appendingPathComponent("php")
        if !fm.fileExists(atPath: php.path) {
            try fm.copyItem(at: executable, to: php)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: php.path)
        }
        _ = try? await Command.run("/usr/bin/xattr", ["-cr", bin.path])

        if download {
            let composer = bin.appendingPathComponent("composer")
            try await Command.download(composerURL, to: composer, report: report)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: composer.path)
            try await Command.download(cacertURL, to: base.appendingPathComponent("cacert.pem"), report: report)
        }

        for (name, template) in [("php.ini", "swoole.ini"), ("php-fpm.conf", "swoole-fpm.conf")] {
            let target = base.appendingPathComponent(name)
            guard !fm.fileExists(atPath: target.path),
                  let source = Bundle.main.url(forResource: "PhpDefaults", withExtension: nil)?
                      .appendingPathComponent("swoole-cli").appendingPathComponent(template) else { continue }
            let content = try String(contentsOf: source, encoding: .utf8)
                .replacingOccurrences(of: "__MACENV_CACERT__", with: base.appendingPathComponent("cacert.pem").path)
            try content.write(to: target, atomically: true, encoding: .utf8)
        }
    }
}
