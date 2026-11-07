import Foundation

@MainActor
final class PythonService {
    let root: URL

    init(root: URL) { self.root = root }

    var versionsDirectory: URL { root.appendingPathComponent("server/python/versions", isDirectory: true) }

    var shimsDirectory: URL { root.appendingPathComponent("shims/python", isDirectory: true) }

    // MARK: - 已安装

    func installedVersions(customDirectories: [String] = []) async -> [PythonVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String)] = []
        for item in (try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
            if let found = Self.findPython(in: item) { candidates.append((found, "Static")) }
        }
        for (parent, source) in defaultParents {
            for item in (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
                if let found = Self.findPython(in: item) { candidates.append((found, source)) }
            }
        }
        for (home, source) in defaultHomes {
            if let found = Self.findPython(in: home) { candidates.append((found, source)) }
        }
        for item in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            if let found = Self.findPython(in: item) {
                candidates.append((found, L("source.custom")))
            } else {
                for child in (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
                    if let found = Self.findPython(in: child) { candidates.append((found, L("source.custom"))) }
                }
            }
        }
        var seen = Set<String>()
        var result: [PythonVersion] = []
        for (file, source) in candidates {
            let resolved = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: resolved.path), seen.insert(resolved.path).inserted else { continue }
            guard let version = await probe(file) else { continue }
            result.append(PythonVersion(version: version,
                                        directory: Self.pythonHome(of: file),
                                        executable: file,
                                        source: source))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    private var defaultParents: [(URL, String)] {
        [(URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions", isDirectory: true), "python.org"),
         (URL(fileURLWithPath: "/opt/local/Library/Frameworks/Python.framework/Versions", isDirectory: true), "MacPorts")]
    }

    private var defaultHomes: [(URL, String)] {
        let entries = ["/opt/homebrew/opt", "/usr/local/opt"].flatMap {
            (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: $0), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        }
        let kegs = entries.filter { $0.lastPathComponent == "python" || $0.lastPathComponent.hasPrefix("python@") }
        return kegs.map { ($0, "Homebrew") } + [(URL(fileURLWithPath: "/usr", isDirectory: true), L("source.system"))]
    }

    private static func findPython(in directory: URL) -> URL? {
        let fm = FileManager.default
        for path in ["libexec/bin/python", "bin/python3", "bin/python", "python3", "python"] {
            let file = directory.appendingPathComponent(path)
            if fm.isExecutableFile(atPath: file.path) { return file }
        }
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        let entries = [bin, directory].flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] }
        return entries.first { entry in
            entry.lastPathComponent.range(of: "^python[23]\\.\\d+$", options: .regularExpression) != nil
                && fm.isExecutableFile(atPath: entry.path)
        }
    }

    static func pythonHome(of executable: URL) -> URL {
        let bin = executable.deletingLastPathComponent()
        guard bin.lastPathComponent == "bin" else { return bin }
        let parent = bin.deletingLastPathComponent()
        return parent.lastPathComponent == "libexec" ? parent.deletingLastPathComponent() : parent
    }

    private func probe(_ executable: URL) async -> String? {
        let output = try? await Command.run(executable.path, ["--version"])
        return Self.parseVersion(output?.text ?? "")
    }

    static func parseVersion(_ text: String) -> String? {
        firstCapture("Python\\s+([0-9][^\\s]*)", in: text)
    }

    func clearQuarantine(_ version: StaticVersion) async {
        let target = versionsDirectory.appendingPathComponent("python-\(version.version)")
        _ = try? await Command.run("/usr/bin/xattr", ["-cr", target.path])
    }

    // MARK: - Static 源（python-build-standalone）

    static let standaloneReleases = URL(string: "https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest")!

    private struct GitHubRelease: Decodable {
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
    }

    static func standaloneVersions() async throws -> [StaticVersion] {
        let (data, response) = try await URLSession.shared.data(from: standaloneReleases)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw CommandError(message: L("error.catalogRequestFailed") + "（HTTP \(status)）")
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        return parseStandalone(release.assets.map { ($0.name, $0.browserDownloadURL) })
            .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    static func parseStandalone(_ assets: [(name: String, url: URL)]) -> [StaticVersion] {
        #if arch(arm64)
        let arch = "aarch64"
        #else
        let arch = "x86_64"
        #endif
        let pattern = "^cpython-([0-9]+\\.[0-9]+\\.[0-9]+)\\+\\d+-" + arch + "-apple-darwin-install_only\\.tar\\.gz$"
        return assets.compactMap { name, url in
            guard let version = firstCapture(pattern, in: name) else { return nil }
            return StaticVersion(name: "Python-\(version)", version: version, url: url, downloaded: false, installed: false)
        }
    }

    // MARK: - PATH shim

    static func shimNames(_ version: String) -> [String] {
        let parts = version.split(separator: ".").map(String.init)
        guard parts.first == "3" else { return ["python"] }
        return ["python", "python3"] + (parts.count >= 2 ? ["python3.\(parts[1])"] : [])
    }

    func shimDirectory(for version: PythonVersion) -> URL {
        shimsDirectory.appendingPathComponent("python-\(version.version)-\(Self.fnv1a(version.executable.path))", isDirectory: true)
    }

    func shim(for version: PythonVersion) throws -> URL {
        let fm = FileManager.default
        let directory = shimDirectory(for: version)
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in Self.shimNames(version.version) {
            let link = bin.appendingPathComponent(name)
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != version.executable.path {
                try? fm.removeItem(at: link)
                try fm.createSymbolicLink(at: link, withDestinationURL: version.executable)
            }
        }
        return directory
    }

    private func shimTargets() -> [(shim: URL, interpreter: URL)] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: shimsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return entries.compactMap { entry in
            let bin = entry.appendingPathComponent("bin", isDirectory: true)
            guard let destination = try? fm.destinationOfSymbolicLink(atPath: bin.appendingPathComponent("python").path) else { return nil }
            return (entry, URL(fileURLWithPath: destination, relativeTo: bin).standardizedFileURL)
        }
    }

    func staleShims() -> [URL] {
        let fm = FileManager.default
        return shimTargets().filter { !fm.isExecutableFile(atPath: $0.interpreter.path) }.map(\.shim)
    }

    func shims(pointingInside directory: URL) -> [URL] {
        let prefix = directory.resolvingSymlinksInPath().path + "/"
        return shimTargets().filter { $0.interpreter.resolvingSymlinksInPath().path.hasPrefix(prefix) }.map(\.shim)
    }

    static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    nonisolated static func macPortsVersion(_ name: String) -> String? {
        let digits = name.dropFirst("python".count)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return digits.count > 1 ? "\(digits.first!).\(digits.dropFirst())" : String(digits)
    }
}
