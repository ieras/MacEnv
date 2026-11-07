import Foundation
import Darwin

struct ToolItem: Identifiable, Hashable {
    let name: String
    let version: String

    var id: String { name + "|" + version }
}

struct PortItem: Identifiable, Hashable {
    let name: String
    let version: String
    let installed: Bool

    var id: String { name }
}

@MainActor
protocol PortListHost: AnyObject {
    var state: AppState { get }
    var services: Services { get }
    var portApp: String { get }
    var portItems: [PortItem] { get set }
    var portLoading: Bool { get set }
    func refresh() async
}

extension PortListHost {
    func loadPortItems(force: Bool = false) async {
        portItems = services.tools.portCached(app: portApp)
        if !force, services.tools.portCacheFresh(app: portApp) { return }
        guard !portLoading else { return }
        portLoading = true
        defer { portLoading = false }
        portItems = await services.tools.portItems(app: portApp, force: force)
    }

    func portAction(_ action: String, _ item: PortItem) {
        state.runStreaming(taskTitle(action, item.name)) { report, _ in
            try await self.services.tools.port(action, app: self.portApp, name: item.name, report: report)
            await self.loadPortItems()
            await self.refresh()
        }
    }
}


@MainActor
final class ToolService {
    let root: URL

    init(root: URL) { self.root = root }

    private var downloads: URL { root.appendingPathComponent("cache", isDirectory: true) }

    private static let brewInstaller = URL(string: "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh")!
    private static let brewUninstaller = URL(string: "https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh")!
    private static let sdkmanInstaller = URL(string: "https://get.sdkman.io")!
    private static let macPortsReleases = URL(string: "https://api.github.com/repos/macports/macports-base/releases/latest")!

    // MARK: - Homebrew

    var brewInstalled: Bool { Brew.executable != nil }

    var brewPrefix: String {
        #if arch(arm64)
        return "/opt/homebrew"
        #else
        return "/usr/local"
        #endif
    }

    func brewVersion() async -> String {
        guard let executable = Brew.executable else { return "" }
        let output = try? await Command.run(executable, ["--version"], environment: Command.brewEnvironment)
        return output?.stdout.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    func brewItems() async -> [ToolItem] {
        guard let executable = Brew.executable,
              let output = try? await Command.run(executable, ["list", "--formula", "--versions"], environment: Command.brewEnvironment) else { return [] }
        return output.stdout.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2 else { return nil }
            return ToolItem(name: parts[0], version: parts.dropFirst().joined(separator: ", "))
        }.sorted { $0.name < $1.name }
    }

    func installBrew(report: @escaping (String) -> Void, onStart: @escaping (Process) -> Void) async throws {
        try await privileged("mkdir -p \(brewPrefix) && chown \(getuid()):\(getgid()) \(brewPrefix)")
        let script = try await download(Self.brewInstaller, named: "homebrew-install.sh", report: report)
        let status = try await Command.stream("/bin/bash", [script.path], environment: ["NONINTERACTIVE": "1"],
                                              onStart: onStart, onOutput: report)
        guard status == 0 else { throw CommandError(message: L("error.toolCommandFailed") + "（\(status)）") }
    }

    func uninstallBrew(report: @escaping (String) -> Void) async throws {
        let script = try await download(Self.brewUninstaller, named: "homebrew-uninstall.sh", report: report)
        try await Command.privilegedStream("NONINTERACTIVE=1 /bin/bash \(singleQuoted(script.path))", report: report)
    }

    // MARK: - MacPorts

    var macPortsInstalled: Bool { FileManager.default.isExecutableFile(atPath: "/opt/local/bin/port") }

    func macPortsVersion() async -> String {
        guard macPortsInstalled else { return "" }
        let output = try? await Command.run("/opt/local/bin/port", ["version"])
        return firstCapture(#"Version:\s*([0-9][^\s]*)"#, in: output?.stdout ?? "") ?? ""
    }

    func macPortsItems() async -> [ToolItem] {
        guard macPortsInstalled, let output = try? await Command.run("/opt/local/bin/port", ["installed"]) else { return [] }
        return output.stdout.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, parts[1].hasPrefix("@") else { return nil }
            return ToolItem(name: String(parts[0]), version: String(parts[1].dropFirst()))
        }.sorted { $0.name < $1.name }
    }

    static func macPortsAsset(names: [String], os: OperatingSystemVersion) -> String? {
        let key = os.majorVersion >= 11 ? "-\(os.majorVersion)-" : "-\(os.majorVersion).\(os.minorVersion)-"
        return names.first { $0.hasSuffix(".pkg") && $0.contains(key) }
    }

    func installMacPorts(report: @escaping (String) -> Void) async throws {
        let (data, _) = try await URLSession.shared.data(from: Self.macPortsReleases)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]] else {
            throw CommandError(message: L("error.macPortsReleaseFailed"))
        }
        let names = assets.compactMap { $0["name"] as? String }
        guard let name = Self.macPortsAsset(names: names, os: ProcessInfo.processInfo.operatingSystemVersion),
              let asset = assets.first(where: { $0["name"] as? String == name }),
              let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) else {
            throw CommandError(message: String(format: L("error.macPortsNoPackage"), ProcessInfo.processInfo.operatingSystemVersionString))
        }
        let pkg = try await download(url, named: name, report: report)
        _ = try? await Command.run("/usr/bin/xattr", ["-cr", pkg.path])
        try await Command.privilegedStream("/usr/sbin/installer -pkg \(singleQuoted(pkg.path)) -target /", report: report)
        guard macPortsInstalled else { throw CommandError(message: L("error.macPortsInstallFailed")) }
    }

    func uninstallMacPorts(report: @escaping (String) -> Void) async throws {
        guard macPortsInstalled else { throw CommandError(message: L("macports.missing")) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        try await Command.privilegedStream("""
        PATH=/opt/local/bin:/usr/bin:/bin /opt/local/bin/port -fp uninstall installed
        dscl . -delete /Users/macports
        dscl . -delete /Groups/macports
        rm -rf /opt/local /Applications/DarwinPorts /Applications/MacPorts \\
          /Library/LaunchDaemons/org.macports.* /Library/Receipts/DarwinPorts*.pkg \\
          /Library/Receipts/MacPorts*.pkg /Library/StartupItems/DarwinPortsStartup \\
          /Library/Tcl/darwinports1.0 /Library/Tcl/macports1.0 \(singleQuoted(home + "/.macports"))
        """, report: report)
    }

    func uninstallMacPortsPort(_ name: String, report: @escaping (String) -> Void) async throws {
        try await Command.privilegedStream("PATH=/opt/local/bin:/usr/bin:/bin /opt/local/bin/port -q uninstall \(singleQuoted(name))", report: report)
    }

    // MARK: - MacPorts 可装清单

    struct PortCatalog {
        let regex: String
        let descriptions: [String]
        let installed: (String) -> Bool
        let companions: (String) -> [String]
    }

    static let portCatalogs: [String: PortCatalog] = [
        "nginx": PortCatalog(
            regex: "^nginx\\d*$",
            descriptions: ["High-performance HTTP(S) server"],
            installed: { name in FileManager.default.isExecutableFile(atPath: "/opt/local/sbin/\(name)") },
            companions: { _ in [] }),
        "php": PortCatalog(
            regex: "^php\\d*$",
            descriptions: ["PHP: Hypertext Preprocessor"],
            installed: { name in FileManager.default.isExecutableFile(atPath: "/opt/local/bin/\(name)") },
            companions: { name in ["\(name)-fpm", "\(name)-mysql", "\(name)-apache2handler", "\(name)-iconv"] }),
        "mysql": PortCatalog(
            regex: "^mysql([\\d]+)?$",
            descriptions: ["Multithreaded SQL database server"],
            installed: { name in FileManager.default.isExecutableFile(atPath: "/opt/local/lib/\(name)/bin/mysqld") },
            companions: { name in ["\(name)-server"] }),
        "mariadb": PortCatalog(
            regex: "^mariadb(-[\\d.]*\\d)?$",
            descriptions: ["Multithreaded SQL database server"],
            installed: { name in FileManager.default.isExecutableFile(atPath: "/opt/local/lib/\(name)/bin/mariadbd") },
            companions: { name in ["\(name)-server"] }),
        "redis": PortCatalog(
            regex: "^redis\\d*$",
            descriptions: ["Redis is an open source, advanced key-value store."],
            installed: { name in FileManager.default.isExecutableFile(atPath: "/opt/local/bin/\(name)-server") },
            companions: { _ in [] }),
        "postgresql": PortCatalog(
            regex: "^postgresql\\d*$",
            descriptions: ["The most advanced open-source database available anywhere"],
            installed: { name in FileManager.default.isExecutableFile(atPath: "/opt/local/lib/\(name)/bin/postgres") },
            companions: { _ in [] }),
        "golang": PortCatalog(
            regex: "^go$",
            descriptions: ["programming language developed by Google"],
            installed: { _ in FileManager.default.isExecutableFile(atPath: "/opt/local/lib/go/bin/gofmt") },
            companions: { _ in [] }),
        "java": PortCatalog(
            regex: "^((open)?)jdk([\\d\\.]*)$",
            descriptions: ["Oracle Java SE Development Kit ", "OpenJDK "],
            installed: { name in
                ["/opt/local/Library/Java/JavaVirtualMachines", "/Library/Java/JavaVirtualMachines"].contains {
                    FileManager.default.isExecutableFile(atPath: "\($0)/\(name)/Contents/Home/bin/java")
                }
            },
            companions: { _ in [] }),
        "python": PortCatalog(
            regex: "^python\\d*$",
            descriptions: ["programming language"],
            installed: { name in
                guard let version = PythonService.macPortsVersion(name) else { return false }
                return FileManager.default.isExecutableFile(atPath: "/opt/local/Library/Frameworks/Python.framework/Versions/\(version)/bin/python\(version)")
            },
            companions: { _ in [] }),
        "maven": PortCatalog(
            regex: "^maven\\d*$",
            descriptions: ["build and project management environment"],
            installed: { name in FileManager.default.isExecutableFile(atPath: "/opt/local/share/java/\(name)/bin/mvn") },
            companions: { _ in [] }),
        "gradle": PortCatalog(
            regex: "^gradle\\d*$",
            descriptions: ["build system that is based on the Groovy language"],
            installed: { name in FileManager.default.isExecutableFile(atPath: "/opt/local/bin/\(name)") },
            companions: { _ in [] }),
        "mkcert": PortCatalog(
            regex: "^mkcert$",
            descriptions: ["locally trusted development certificates"],
            installed: { _ in FileManager.default.isExecutableFile(atPath: "/opt/local/bin/mkcert") },
            companions: { _ in [] }),
        "consul": PortCatalog(
            regex: "^consul$",
            descriptions: ["Consul is a distributed service mesh"],
            installed: { _ in FileManager.default.isExecutableFile(atPath: "/opt/local/bin/consul") },
            companions: { _ in [] }),
        "node": PortCatalog(
            regex: "^nodejs\\d*$",
            descriptions: ["JavaScript"],
            installed: { name in FileManager.default.fileExists(atPath: "/opt/local/var/macports/software/\(name)") },
            companions: { _ in [] })
    ]

    static func parsePortSearch(_ text: String, descriptions: [String]) -> [(name: String, version: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard descriptions.isEmpty || descriptions.contains(where: line.contains) else { return nil }
            let parts = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard parts.count >= 2, !parts[0].isEmpty else { return nil }
            return (name: parts[0], version: parts[1].hasPrefix("@") ? String(parts[1].dropFirst()) : parts[1])
        }
    }

    struct PortCachedItem: Codable {
        let name: String
        let version: String
    }

    private func portCacheURL(_ app: String) -> URL { root.appendingPathComponent("catalog/port-\(app).json") }
    private static let portRefreshInterval: TimeInterval = 3600

    private func readPortCache(_ app: String) -> [PortCachedItem] {
        guard let data = try? Data(contentsOf: portCacheURL(app)),
              let items = try? JSONDecoder().decode([PortCachedItem].self, from: data) else { return [] }
        return items
    }

    private func decorate(_ items: [PortCachedItem], app: String) -> [PortItem] {
        guard let catalog = Self.portCatalogs[app] else { return [] }
        return items.map { PortItem(name: $0.name, version: $0.version, installed: catalog.installed($0.name)) }
            .sorted {
                if $0.version == $1.version { return $0.name.localizedStandardCompare($1.name) == .orderedDescending }
                return $0.version.localizedStandardCompare($1.version) == .orderedDescending
            }
    }

    func portCached(app: String) -> [PortItem] {
        macPortsInstalled ? decorate(readPortCache(app), app: app) : []
    }

    func portCacheFresh(app: String) -> Bool {
        let modified = (try? FileManager.default.attributesOfItem(atPath: portCacheURL(app).path))?[.modificationDate] as? Date
        return modified.map { Date().timeIntervalSince($0) < Self.portRefreshInterval } ?? false
    }

    func portItems(app: String, force: Bool = false) async -> [PortItem] {
        guard macPortsInstalled, let catalog = Self.portCatalogs[app] else { return [] }
        if !force, portCacheFresh(app: app) { return portCached(app: app) }
        guard let output = try? await Command.run("/opt/local/bin/port", ["search", "--name", "--line", "--regex", catalog.regex]) else {
            return portCached(app: app)
        }
        let items = Self.parsePortSearch(output.stdout, descriptions: catalog.descriptions)
            .map { PortCachedItem(name: $0.name, version: $0.version) }
        if !items.isEmpty {
            try? FileManager.default.createDirectory(at: portCacheURL(app).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(items).write(to: portCacheURL(app), options: .atomic)
        }
        return decorate(items, app: app)
    }

    func port(_ action: String, app: String, name: String, report: @escaping (String) -> Void) async throws {
        let names = ([name] + (Self.portCatalogs[app]?.companions(name) ?? [])).map(singleQuoted).joined(separator: " ")
        let verb = action == "uninstall" ? "uninstall --follow-dependents" : "install"
        let env = "PATH=/opt/local/bin:/opt/local/sbin:/usr/bin:/bin"
        try await Command.privilegedStream("""
        \(env) /opt/local/bin/port clean \(names)
        \(env) /opt/local/bin/port \(verb) \(names)
        """, report: report)
    }

    // MARK: - SDKMAN
    var sdkmanRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sdkman", isDirectory: true) }
    var sdkmanInitScript: URL { sdkmanRoot.appendingPathComponent("bin/sdkman-init.sh") }
    var sdkmanInstalled: Bool { FileManager.default.fileExists(atPath: sdkmanInitScript.path) }

    func sdkmanItems() -> [ToolItem] {
        let fm = FileManager.default
        let candidates = sdkmanRoot.appendingPathComponent("candidates", isDirectory: true)
        var result: [ToolItem] = []
        for candidate in (try? fm.contentsOfDirectory(at: candidates, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
            let name = candidate.lastPathComponent
            for version in (try? fm.contentsOfDirectory(at: candidate, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
                guard version.lastPathComponent != "current" else { continue }
                result.append(ToolItem(name: name, version: version.lastPathComponent))
            }
        }
        return result.sorted { $0.id < $1.id }
    }

    func installSDKMAN(report: @escaping (String) -> Void, onStart: @escaping (Process) -> Void) async throws {
        let script = try await download(Self.sdkmanInstaller, named: "sdkman-install.sh", report: report)
        let status = try await Command.stream("/bin/zsh", [script.path], onStart: onStart, onOutput: report)
        guard status == 0 else { throw CommandError(message: L("error.toolCommandFailed") + "（\(status)）") }
    }

    func uninstallSDKMAN() throws {
        guard sdkmanInstalled else { throw CommandError(message: L("error.sdkmanMissing")) }
        try FileManager.default.removeItem(at: sdkmanRoot)
    }

    func uninstallSDKMANCandidate(_ candidate: String, version: String,
                                  report: @escaping (String) -> Void, onStart: @escaping (Process) -> Void) async throws {
        let command = "source \(singleQuoted(sdkmanInitScript.path)) && sdk uninstall \(singleQuoted(candidate)) \(singleQuoted(version))"
        let status = try await Command.stream("/bin/zsh", ["-c", command], onStart: onStart, onOutput: report)
        guard status == 0 else { throw CommandError(message: L("error.toolCommandFailed") + "（\(status)）") }
    }

    var sdkmanProfileFiles: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".zshrc", ".bashrc", ".bash_profile"].map { home.appendingPathComponent($0) }
    }

    // MARK: - 下载

    private func download(_ url: URL, named name: String, report: @escaping (String) -> Void) async throws -> URL {
        let file = downloads.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try await Command.download(url, to: file, report: report)
        return file
    }
}
