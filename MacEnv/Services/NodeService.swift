import Foundation

@MainActor
final class NodeService {
    let root: URL

    init(root: URL) { self.root = root }

    var versionsDirectory: URL { root.appendingPathComponent("server/node/versions", isDirectory: true) }

    // MARK: - 版本源（nodejs.org/dist）

    static let distIndex = URL(string: "https://nodejs.org/dist/index.json")!

    struct DistEntry: Decodable {
        let version: String
        let files: [String]
        let lts: Lts

        enum Lts: Decodable {
            case off
            case on(String)

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let flag = try? container.decode(Bool.self) {
                    self = flag ? .on("") : .off
                } else if let name = try? container.decode(String.self) {
                    self = .on(name)
                } else {
                    self = .off
                }
            }

            var codename: String? {
                if case .on(let name) = self, !name.isEmpty { return name }
                return nil
            }
        }
    }

    static func distEntries() async throws -> [DistEntry] {
        let (data, response) = try await URLSession.shared.data(from: distIndex)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw CommandError(message: L("error.catalogRequestFailed") + "（HTTP \(status)）")
        }
        return try JSONDecoder().decode([DistEntry].self, from: data)
    }

    static func parseDist(_ entries: [DistEntry]) -> [StaticVersion] {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x64"
        #endif
        return entries.compactMap { entry in
            guard entry.files.contains("osx-\(arch)-tar") else { return nil }
            let bare = String(entry.version.dropFirst())  // "v22.11.0" → "22.11.0"
            let url = URL(string: "https://nodejs.org/dist/\(entry.version)/node-\(entry.version)-darwin-\(arch).tar.gz")!
            return StaticVersion(name: "Node-\(bare)", version: bare, url: url,
                                 downloaded: false, installed: false, lts: entry.lts.codename)
        }
        .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    // MARK: - 已安装

    func installedVersions(customDirectories: [String] = []) async -> [NodeVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String)] = []
        for item in contents(of: versionsDirectory) {
            if let found = Self.findNode(in: item) { candidates.append((found, "Static")) }
        }
        for item in brewKegs() {
            if let found = Self.findNode(in: item) { candidates.append((found, "Homebrew")) }
        }
        if let found = macPortsNode() {
            candidates.append((found, "MacPorts"))
        }
        for item in await nvmDirectories() {
            if let found = Self.findNode(in: item) { candidates.append((found, "nvm")) }
        }
        for item in await fnmDirectories() {
            if let found = Self.findNode(in: item) { candidates.append((found, "fnm")) }
        }
        for item in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            if let found = Self.findNode(in: item) {
                candidates.append((found, L("source.custom")))
            } else {
                for child in contents(of: item) {
                    if let found = Self.findNode(in: child) { candidates.append((found, L("source.custom"))) }
                }
            }
        }
        let nvmDefault = await nvmDefaultVersion()
        let fnmDefault = await fnmDefaultVersion()
        var seen = Set<String>()
        var result: [NodeVersion] = []
        for (file, source) in candidates {
            let resolved = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: resolved.path), seen.insert(resolved.path).inserted else { continue }
            guard let version = await probe(file) else { continue }
            result.append(NodeVersion(version: version,
                                      directory: Self.nodeRoot(of: file),
                                      executable: file,
                                      source: source,
                                      isNvmDefault: source == "nvm" && version == nvmDefault,
                                      isFnmDefault: source == "fnm" && version == fnmDefault))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    private func contents(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
    }

    private func brewKegs() -> [URL] {
        ["/opt/homebrew/opt", "/usr/local/opt"].flatMap { path in
            contents(of: URL(fileURLWithPath: path, isDirectory: true)).filter {
                $0.lastPathComponent == "node" || $0.lastPathComponent.hasPrefix("node@")
            }
        }
    }

    private func macPortsNode() -> URL? {
        let registry = URL(fileURLWithPath: "/opt/local/var/macports/software", isDirectory: true)
        let hasPort = contents(of: registry).contains { $0.lastPathComponent.hasPrefix("nodejs") }
        let binary = URL(fileURLWithPath: "/opt/local/bin/node", isDirectory: false)
        guard hasPort, FileManager.default.isExecutableFile(atPath: binary.path) else { return nil }
        return binary
    }

    private static func findNode(in directory: URL) -> URL? {
        let fm = FileManager.default
        for path in ["bin/node", "installation/bin/node", "node"] {
            let file = directory.appendingPathComponent(path)
            if fm.isExecutableFile(atPath: file.path), !Self.isDirectory(file) { return file }
        }
        return nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    static func nodeRoot(of executable: URL) -> URL {
        let bin = executable.deletingLastPathComponent()
        return bin.lastPathComponent == "bin" ? bin.deletingLastPathComponent() : bin
    }

    private func probe(_ executable: URL) async -> String? {
        let output = try? await Command.run(executable.path, ["--version"])
        return firstCapture("v([0-9][^\\s]*)", in: output?.text ?? "")
    }

    func clearQuarantine(_ version: StaticVersion) async {
        let target = versionsDirectory.appendingPathComponent("node-\(version.version)")
        _ = try? await Command.run("/usr/bin/xattr", ["-cr", target.path])
    }

    // MARK: - nvm

    func nvmRoot() async -> URL {
        if let value = await envValue("NVM_DIR"), !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nvm", isDirectory: true)
    }

    func nvmInstalled() async -> Bool {
        FileManager.default.fileExists(atPath: (await nvmRoot()).appendingPathComponent("nvm.sh").path)
    }

    func nvmDirectories() async -> [URL] {
        guard await nvmInstalled() else { return [] }
        return contents(of: (await nvmRoot()).appendingPathComponent("versions/node", isDirectory: true))
    }

    func nvmDefaultVersion() async -> String? {
        guard await nvmInstalled() else { return nil }
        let root = await nvmRoot()
        let script = "export NVM_DIR=\"\(root.path)\"; . \"\(root.path)/nvm.sh\"; nvm alias default"
        guard let output = try? await Command.run("/bin/zsh", ["-c", script]) else { return nil }
        return Self.parseNvmDefault(output.text)
    }

    static func parseNvmDefault(_ text: String) -> String? {
        firstCapture("default\\s*->\\s*v?([0-9][^\\s]*)", in: text)
    }

    func nvm(_ action: String, version: String, onStart: @escaping (Process) -> Void, onOutput: @escaping (String) -> Void) async throws {
        let root = await nvmRoot()
        let status = try await Command.stream("/bin/zsh", ["-c",
            "export NVM_DIR=\"\(root.path)\"; . \"\(root.path)/nvm.sh\"; nvm \(action) \(version)"],
            onStart: onStart, onOutput: onOutput)
        guard status == 0 else { throw CommandError(message: L("error.nvmFailed") + "（\(status)）") }
    }

    // MARK: - fnm

    func fnmDirectory() async -> URL? {
        if let value = await envValue("FNM_DIR"), FileManager.default.fileExists(atPath: value) {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for candidate in ["Library/Application Support/fnm", ".local/share/fnm"] {
            let url = home.appendingPathComponent(candidate, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    func fnmInstalled() async -> Bool {
        guard let output = try? await Command.run("/bin/zsh", ["-lc", "fnm --version"]) else { return false }
        return output.status == 0 && output.stdout.contains(where: \.isNumber)
    }

    func fnmDirectories() async -> [URL] {
        guard await fnmInstalled(), let dir = await fnmDirectory() else { return [] }
        return contents(of: dir.appendingPathComponent("node-versions", isDirectory: true))
    }

    func fnmDefaultVersion() async -> String? {
        guard let dir = await fnmDirectory() else { return nil }
        let text = (try? String(contentsOf: dir.appendingPathComponent("aliases/default"), encoding: .utf8)) ?? ""
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func fnm(_ action: String, version: String, onStart: @escaping (Process) -> Void, onOutput: @escaping (String) -> Void) async throws {
        let status = try await Command.stream("/bin/zsh", ["-lc", "fnm \(action) \(version)"],
            onStart: onStart, onOutput: onOutput)
        guard status == 0 else { throw CommandError(message: L("error.fnmFailed") + "（\(status)）") }
    }

    // MARK: - 工具

    private func envValue(_ name: String) async -> String? {
        guard let output = try? await Command.run("/bin/zsh", ["-lc", "printf '%s' \"$\(name)\""]) else { return nil }
        let value = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - 本体装卸（版本管理页顶栏「安装 / 更新 / 卸载」操作的是管理器自己）

    private static let nvmInstaller = "https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh"
    private static let fnmInstaller = "https://fnm.vercel.app/install"

    var profileFiles: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".zshrc", ".zprofile", ".bashrc", ".bash_profile", ".profile"].map { home.appendingPathComponent($0) }
    }

    func installManager(_ manager: String, onStart: @escaping (Process) -> Void, onOutput: @escaping (String) -> Void) async throws {
        let url = manager == "nvm" ? Self.nvmInstaller : Self.fnmInstaller
        let status = try await Command.stream("/bin/zsh", ["-lc", "curl -o- \(url) | bash"],
                                             onStart: onStart, onOutput: onOutput)
        guard status == 0 else {
            throw CommandError(message: L(manager == "nvm" ? "error.nvmFailed" : "error.fnmFailed") + "（\(status)）")
        }
    }

    func uninstallManager(_ manager: String) async throws {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        if manager == "nvm" {
            let root = await nvmRoot()
            guard root.resolvingSymlinksInPath().path != home else { throw CommandError(message: L("error.nvmRootUnsafe")) }
            guard fm.fileExists(atPath: root.appendingPathComponent("nvm.sh").path) else { throw CommandError(message: L("error.nvmMissing")) }
            try fm.removeItem(at: root)
        } else {
            guard let dir = await fnmDirectory() else { throw CommandError(message: L("error.fnmMissing")) }
            guard dir.resolvingSymlinksInPath().path != home else { throw CommandError(message: L("error.fnmRootUnsafe")) }
            try fm.removeItem(at: dir)
        }
    }
}
