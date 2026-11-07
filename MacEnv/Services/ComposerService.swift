import Foundation

@MainActor
final class ComposerService {
    let root: URL

    var directory: URL { root.appendingPathComponent("server/composer", isDirectory: true) }
    var versionsDirectory: URL { directory.appendingPathComponent("versions", isDirectory: true) }

    init(root: URL) { self.root = root }

    func installedVersions(customDirectories: [String] = []) throws -> [ComposerVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String)] = []
        for item in (try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
            candidates.append((item.appendingPathComponent("bin/composer"), "Static"))
        }
        for item in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            for path in ["composer", "bin/composer"] { candidates.append((item.appendingPathComponent(path), L("source.custom"))) }
        }
        var seen = Set<String>()
        var result: [ComposerVersion] = []
        for (file, fallback) in candidates {
            let executable = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted,
                  let data = try? Data(contentsOf: executable, options: .mappedIfSafe),
                  let version = firstCapture("public const VERSION = '(\\d+(?:\\.\\d+){1,4})'", in: String(decoding: data, as: UTF8.self)) else { continue }
            result.append(ComposerVersion(version: version,
                                          directory: executable.deletingLastPathComponent().deletingLastPathComponent(),
                                          executable: executable,
                                          source: source(of: executable, fallback: fallback)))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    func install(_ version: StaticVersion, report: @escaping (String) -> Void = { _ in }, onStart: ((Process) -> Void)? = nil) async throws {
        let bin = versionsDirectory.appendingPathComponent("composer-\(version.version)").appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let composer = bin.appendingPathComponent("composer")
        try await Command.download(version.url, to: composer, report: report, onStart: onStart)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: composer.path)
    }

    func uninstall(_ version: StaticVersion) throws {
        try FileManager.default.removeItem(at: versionsDirectory.appendingPathComponent("composer-\(version.version)"))
    }

    private func source(of executable: URL, fallback: String) -> String {
        if executable.path.hasPrefix("/opt/homebrew") { return "Homebrew" }
        if executable.path.hasPrefix("/opt/local") { return "MacPorts" }
        return fallback
    }
}
