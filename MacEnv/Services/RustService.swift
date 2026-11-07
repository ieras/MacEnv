import Foundation

@MainActor
final class RustService {
    let root: URL

    init(root: URL) { self.root = root }

    var versionsDirectory: URL { root.appendingPathComponent("server/rust/versions", isDirectory: true) }
    private var archives: URL { root.appendingPathComponent("cache", isDirectory: true) }

    // MARK: - 版本源（static.rust-lang.org/dist）

    static func versions() async throws -> [StaticVersion] {
        parseVersions(try await StaticCatalogService.oneEnv(app: "rust", displayName: "Rust"), host: currentHost)
    }

    static var currentHost: String {
        #if arch(arm64)
        "aarch64-apple-darwin"
        #else
        "x86_64-apple-darwin"
        #endif
    }

    static func parseVersions(_ entries: [StaticVersion], host: String) -> [StaticVersion] {
        entries.map { entry in
            StaticVersion(name: entry.name,
                          version: entry.version,
                          url: URL(string: "https://static.rust-lang.org/dist/rust-\(entry.version)-\(host).tar.xz")!,
                          downloaded: false, installed: false)
        }
    }

    // MARK: - 已安装

    func installedVersions(customDirectories: [String] = []) async -> [RustVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String)] = []
        for item in contents(of: versionsDirectory) {
            if let found = Self.findRustc(in: item) { candidates.append((found, "Static")) }
        }
        for item in brewKegs() {
            if let found = Self.findRustc(in: item) { candidates.append((found, "Homebrew")) }
        }
        if let found = macPortsRustc() { candidates.append((found, "MacPorts")) }
        for item in await rustupToolchainDirectories() {
            if let found = Self.findRustc(in: item) { candidates.append((found, "rustup")) }
        }
        for item in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            if let found = Self.findRustc(in: item) {
                candidates.append((found, L("source.custom")))
            } else {
                for child in contents(of: item) {
                    if let found = Self.findRustc(in: child) { candidates.append((found, L("source.custom"))) }
                }
            }
        }
        let rustupDefault = await rustupDefaultDirectory()?.resolvingSymlinksInPath().path
        var seen = Set<String>()
        var result: [RustVersion] = []
        for (file, source) in candidates {
            let resolved = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: resolved.path), seen.insert(resolved.path).inserted else { continue }
            guard let version = await probe(file) else { continue }
            let directory = Self.rustRoot(of: file)
            result.append(RustVersion(version: version,
                                      directory: directory,
                                      executable: file,
                                      source: source,
                                      isRustupDefault: source == "rustup"
                                          && directory.resolvingSymlinksInPath().path == rustupDefault))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    private func contents(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
    }

    private func brewKegs() -> [URL] {
        ["/opt/homebrew/opt", "/usr/local/opt"].flatMap { path in
            contents(of: URL(fileURLWithPath: path, isDirectory: true)).filter { $0.lastPathComponent == "rust" }
        }
    }

    private func macPortsRustc() -> URL? {
        let registry = URL(fileURLWithPath: "/opt/local/var/macports/software", isDirectory: true)
        let hasPort = contents(of: registry).contains { $0.lastPathComponent.hasPrefix("rust") }
        let binary = URL(fileURLWithPath: "/opt/local/bin/rustc", isDirectory: false)
        guard hasPort, FileManager.default.isExecutableFile(atPath: binary.path) else { return nil }
        return binary
    }

    private static func findRustc(in directory: URL) -> URL? {
        for path in ["bin/rustc", "rustc"] {
            let file = directory.appendingPathComponent(path)
            if FileManager.default.isExecutableFile(atPath: file.path), !isDirectory(file) { return file }
        }
        return nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    static func rustRoot(of executable: URL) -> URL {
        let bin = executable.deletingLastPathComponent()
        return bin.lastPathComponent == "bin" ? bin.deletingLastPathComponent() : bin
    }

    static func parseVersion(_ output: String) -> String? {
        firstCapture(#"rustc (\d+\.\d+\.\d+)"#, in: output)
    }

    private func probe(_ executable: URL) async -> String? {
        let output = try? await Command.run(executable.path, ["--version"])
        guard output?.status == 0 else { return nil }
        return Self.parseVersion(output?.stdout ?? "")
    }

    func clearQuarantine(_ version: StaticVersion) async {
        let target = versionsDirectory.appendingPathComponent("rust-\(version.version)")
        _ = try? await Command.run("/usr/bin/xattr", ["-cr", target.path])
    }

    // MARK: - 静态包装卸

    func install(_ version: StaticVersion, report: @escaping (String) -> Void = { _ in }, onStart: ((Process) -> Void)? = nil) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: archives, withIntermediateDirectories: true)
        try fm.createDirectory(at: versionsDirectory, withIntermediateDirectories: true)
        let archive = archives.appendingPathComponent("static-rust-\(version.version).tar.xz")
        if !fm.fileExists(atPath: archive.path) {
            try await Command.download(version.url, to: archive, report: report, onStart: onStart)
        }
        let staging = versionsDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        let target = versionsDirectory.appendingPathComponent("rust-\(version.version)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let status = try await Command.stream("/usr/bin/tar", ["-xJf", archive.path, "-C", staging.path],
                                              onStart: onStart, onOutput: report)
        guard status == 0 else {
            try? fm.removeItem(at: archive)
            throw CommandError(message: L("error.unpackFailed") + "（\(status)）")
        }
        guard let packageRoot = contents(of: staging).first(where: Self.isDirectory),
              fm.isExecutableFile(atPath: packageRoot.appendingPathComponent("install.sh").path) else {
            try? fm.removeItem(at: archive)
            throw CommandError(message: L("error.binaryMissing") + "rustc")
        }
        let out = staging.appendingPathComponent("out", isDirectory: true)
        let script = "cd \(singleQuoted(packageRoot.path)) && ./install.sh --prefix=/ --destdir=\(singleQuoted(out.path))"
        let installStatus = try await Command.stream("/bin/sh", ["-c", script], onStart: onStart, onOutput: report)
        guard installStatus == 0 else {
            try? fm.removeItem(at: archive)
            throw CommandError(message: L("error.unpackFailed") + "（\(installStatus)）")
        }
        try Task.checkCancellation()
        guard fm.isExecutableFile(atPath: out.appendingPathComponent("bin/rustc").path) else {
            throw CommandError(message: L("error.binaryMissing") + "rustc")
        }
        try fm.replaceDirectory(at: target, with: out)
    }

    func uninstall(_ version: StaticVersion) throws {
        try FileManager.default.removeItem(at: versionsDirectory.appendingPathComponent("rust-\(version.version)"))
    }

    // MARK: - rustup

    func cargoHome() async -> URL {
        if let value = await envValue("CARGO_HOME"), !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cargo", isDirectory: true)
    }

    func rustupHome() async -> URL {
        if let value = await envValue("RUSTUP_HOME"), !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".rustup", isDirectory: true)
    }

    func rustupInstalled() async -> Bool {
        FileManager.default.isExecutableFile(atPath: (await rustupBinary()).path)
    }

    private func rustupBinary() async -> URL {
        await cargoHome().appendingPathComponent("bin/rustup")
    }

    func rustupToolchainDirectories() async -> [URL] {
        guard await rustupInstalled() else { return [] }
        return contents(of: (await rustupHome()).appendingPathComponent("toolchains", isDirectory: true))
    }

    func rustupDefaultDirectory() async -> URL? {
        guard await rustupInstalled() else { return nil }
        guard let output = try? await Command.run((await rustupBinary()).path, ["show", "active-toolchain"]),
              output.status == 0 else { return nil }
        guard let name = Self.parseActiveToolchain(output.stdout) else { return nil }
        return (await rustupHome()).appendingPathComponent("toolchains/\(name)", isDirectory: true)
    }

    static func parseActiveToolchain(_ output: String) -> String? {
        let name = output.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return name.isEmpty || name.hasPrefix("error") ? nil : name
    }

    func rustup(_ arguments: [String], onStart: @escaping (Process) -> Void, onOutput: @escaping (String) -> Void) async throws {
        guard await rustupInstalled() else { throw CommandError(message: L("error.rustupMissing")) }
        let status = try await Command.stream((await rustupBinary()).path, arguments, onStart: onStart, onOutput: onOutput)
        guard status == 0 else { throw CommandError(message: L("error.rustupFailed") + "（\(status)）") }
    }

    // MARK: - 本体装卸（版本管理页顶栏「安装 / 更新 / 卸载」操作的是 rustup 自己）

    private static let rustupInstaller = "https://sh.rustup.rs"

    func installManager(onStart: @escaping (Process) -> Void, onOutput: @escaping (String) -> Void) async throws {
        let script = "curl --proto '=https' --tlsv1.2 -sSf \(Self.rustupInstaller) | sh -s -- -y"
        let status = try await Command.stream("/bin/sh", ["-c", script], onStart: onStart, onOutput: onOutput)
        guard status == 0 else { throw CommandError(message: L("error.rustupFailed") + "（\(status)）") }
    }

    func uninstallManager(onStart: @escaping (Process) -> Void, onOutput: @escaping (String) -> Void) async throws {
        try await rustup(["self", "uninstall", "-y"], onStart: onStart, onOutput: onOutput)
    }

    // MARK: - 工具

    private func envValue(_ name: String) async -> String? {
        guard let output = try? await Command.run("/bin/zsh", ["-lc", "printf '%s' \"$\(name)\""]) else { return nil }
        let value = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
