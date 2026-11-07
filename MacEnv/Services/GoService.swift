import Foundation

@MainActor
final class GoService {
    let root: URL

    init(root: URL) { self.root = root }

    var versionsDirectory: URL { root.appendingPathComponent("server/golang/versions", isDirectory: true) }

    // MARK: - 已安装

    func installedVersions(customDirectories: [String] = []) async throws -> [GoVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String)] = []
        for item in (try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
            if let found = Self.findGo(in: item) { candidates.append((found, "Static")) }
        }
        for item in defaultDirectories {
            if let found = Self.findGo(in: item) { candidates.append((found, L("source.system"))) }
        }
        for item in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            if let found = Self.findGo(in: item) { candidates.append((found, L("source.custom"))) }
        }
        for item in gvmGoDirectories() {
            if let found = Self.findGo(in: item) { candidates.append((found, "GVM")) }
        }
        var seen = Set<String>()
        var result: [GoVersion] = []
        for (file, source) in candidates {
            let executable = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted else { continue }
            guard let version = try? await probe(executable) else { continue }
            result.append(GoVersion(version: version,
                                    directory: Self.goRoot(of: executable),
                                    executable: executable,
                                    source: source))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    private var defaultDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var result = ["/usr/local/go", "/opt/homebrew/opt/go", "/opt/local/lib/go"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        for (parent, prefix) in [(home.appendingPathComponent("sdk", isDirectory: true), "go"),
                                (home.appendingPathComponent("go", isDirectory: true), "go")] {
            let entries = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            result += entries.filter { Self.isDirectory($0) && $0.lastPathComponent.hasPrefix(prefix) }
        }
        return result
    }

    private static func findGo(in directory: URL) -> URL? {
        for path in ["bin/go", "go"] {
            let file = directory.appendingPathComponent(path)
            if FileManager.default.isExecutableFile(atPath: file.path), !isDirectory(file) { return file }
        }
        return nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    static func goRoot(of executable: URL) -> URL {
        let bin = executable.deletingLastPathComponent()
        return bin.lastPathComponent == "bin" ? bin.deletingLastPathComponent() : bin
    }

    private func probe(_ executable: URL) async throws -> String {
        let output = try await Command.run(executable.path, ["version"], environment: ["GOROOT": Self.goRoot(of: executable).path])
        guard output.status == 0, let version = firstCapture(#"go version go([0-9][^\s]*)"#, in: output.stdout) else {
            throw CommandError(message: output.text)
        }
        return version
    }

    func clearQuarantine(_ version: StaticVersion) async throws {
        let target = versionsDirectory.appendingPathComponent("golang-\(version.version)")
        _ = try? await Command.run("/usr/bin/xattr", ["-cr", target.path])
    }

    // MARK: - GVM

    var gvmRoot: URL {
        let configured = (ProcessInfo.processInfo.environment["GVM_ROOT"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gvm", isDirectory: true)
            : URL(fileURLWithPath: configured, isDirectory: true)
    }

    var gvmInitScript: URL { gvmRoot.appendingPathComponent("scripts/gvm") }

    var gvmInstalled: Bool { FileManager.default.fileExists(atPath: gvmInitScript.path) }

    func gvmGoDirectories() -> [URL] {
        let gos = gvmRoot.appendingPathComponent("gos", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: gos, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return entries.filter { Self.isDirectory($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func gvmVersions() async throws -> [GvmVersion] {
        guard gvmInstalled else { throw CommandError(message: L("error.gvmMissing")) }
        let setup = "source \(singleQuoted(gvmInitScript.path))"
        async let available = Command.run("/bin/zsh", ["-c", "\(setup) && gvm listall"])
        async let installed = Command.run("/bin/zsh", ["-c", "\(setup) && gvm list"])
        let (all, have) = try await (available, installed)
        return Self.mergeGvm(available: all.stdout, installed: have.stdout)
    }

    static func mergeGvm(available: String, installed: String) -> [GvmVersion] {
        var names: [String] = []
        var seen = Set<String>()
        for line in available.split(separator: "\n") {
            guard let name = gvmName(String(line)), seen.insert(name).inserted else { continue }
            names.append(name)
        }
        var defaults: [String: Bool] = [:]
        for line in installed.split(separator: "\n") {
            guard let (name, isDefault) = gvmInstalledLine(String(line)) else { continue }
            defaults[name] = isDefault
            if seen.insert(name).inserted { names.append(name) }
        }
        return names.map {
            GvmVersion(name: $0,
                       version: $0.hasPrefix("go") ? String($0.dropFirst(2)) : $0,
                       installed: defaults[$0] != nil,
                       isDefault: defaults[$0] ?? false)
        }
    }

    private static func gvmName(_ line: String) -> String? {
        let name = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return isGvmIdentifier(name) ? name : nil
    }

    private static func gvmInstalledLine(_ line: String) -> (String, Bool)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let isDefault = trimmed.hasPrefix("=>")
        guard let name = gvmName(isDefault ? String(trimmed.dropFirst(2)) : trimmed) else { return nil }
        return (name, isDefault)
    }

    private static func isGvmIdentifier(_ value: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"^go\d+\.\d+\.\d+$"#) else { return false }
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    private static let gvmInstaller = "https://raw.githubusercontent.com/moovweb/gvm/master/binscripts/gvm-installer"

    private static let gvmSanitize = #"if [ -n "$GOROOT" ] && [ ! -d "$GOROOT" ]; then rm -f "$GVM_ROOT/environments/default"; unset GOROOT GOPATH GOBIN gvm_go_name gvm_pkgset_name; fi"#

    var profileFiles: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".zshrc", ".zprofile", ".bashrc", ".bash_profile", ".profile"].map { home.appendingPathComponent($0) }
    }

    func uninstallGvm() throws {
        guard gvmInstalled else { throw CommandError(message: L("error.gvmMissing")) }
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        guard gvmRoot.resolvingSymlinksInPath().path != home else { throw CommandError(message: L("error.gvmRootUnsafe")) }
        try FileManager.default.removeItem(at: gvmRoot)
    }

    func installGvm(onStart: @escaping (Process) -> Void, onOutput: @escaping (String) -> Void) async throws {
        try await run("bash < <(curl -sSL \(Self.gvmInstaller))", onStart: onStart, onOutput: onOutput)
    }
    func gvm(_ action: GvmAction, version: GvmVersion, onStart: @escaping (Process) -> Void, onOutput: @escaping (String) -> Void) async throws {
        var script = ""
        switch action {
        case .install: script = "gvm install \(version.name) -B"
        case .uninstall:
            script = "gvm uninstall \(version.name)"
            if version.isDefault { script += #" && rm -f "$GVM_ROOT/environments/default""# }
        case .useDefault: script = "gvm use \(version.name) --default"
        }
        try await run("source \(singleQuoted(gvmInitScript.path)) && \(Self.gvmSanitize) && \(script)", onStart: onStart, onOutput: onOutput)
    }

    private func run(_ command: String, onStart: @escaping (Process) -> Void, onOutput: @escaping (String) -> Void) async throws {
        let status = try await Command.stream("/bin/zsh", ["-c", command], onStart: onStart, onOutput: onOutput)
        guard status == 0 else { throw CommandError(message: L("error.gvmFailed") + "（\(status)）") }
    }

}
