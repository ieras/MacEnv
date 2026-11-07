import Foundation

@MainActor
final class PathService {
    let root: URL
    private(set) var allPath: [String] = []
    private var pathSources: [String: String] = [:]
    private var loaded = false

    var envDirectory: URL { root.appendingPathComponent("env", isDirectory: true) }
    var aliasDirectory: URL { root.appendingPathComponent("alias", isDirectory: true) }

    private var shell: String {
        let value = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        return FileManager.default.isExecutableFile(atPath: value) ? value : "/bin/zsh"
    }

    private var shellName: String { (shell as NSString).lastPathComponent }

    private var shellFile: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch shellName {
        case "fish": return home.appendingPathComponent(".config/fish/config.fish")
        case "bash": return home.appendingPathComponent(".bash_profile")
        case "zsh": return home.appendingPathComponent(".zshrc")
        default: return home.appendingPathComponent(".profile")
        }
    }

    private var sourceFiles: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var files: [URL]
        switch shellName {
        case "fish": files = [home.appendingPathComponent(".config/fish/config.fish")]
        case "bash": files = [home.appendingPathComponent(".bash_profile"), home.appendingPathComponent(".bashrc"), home.appendingPathComponent(".profile")]
        case "zsh": files = [home.appendingPathComponent(".zshenv"), home.appendingPathComponent(".zprofile"), home.appendingPathComponent(".zshrc"), home.appendingPathComponent(".zlogin")]
        default: files = [home.appendingPathComponent(".profile")]
        }
        files += [URL(fileURLWithPath: "/etc/paths"), URL(fileURLWithPath: "/etc/profile")]
        if shellName == "zsh" {
            files += ["/etc/zshenv", "/etc/zprofile", "/etc/zshrc", "/etc/zlogin"].map { URL(fileURLWithPath: $0) }
        } else if shellName == "fish" {
            files.append(URL(fileURLWithPath: "/etc/fish/config.fish"))
        }
        let pathsDirectory = URL(fileURLWithPath: "/etc/paths.d", isDirectory: true)
        files += (try? FileManager.default.contentsOfDirectory(at: pathsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return files
    }

    init(root: URL) { self.root = root }

    func refresh(force: Bool = false) async throws {
        guard force || !loaded else { return }
        let marker = "__MACENV_PATH__"
        let value = shellName == "fish" ? "string join : $PATH" : "\"$PATH\""
        let output = try await Command.run(shell, ["-ilc", "printf '\(marker)%s\(marker)' \(value)"])
        guard output.status == 0 else { throw CommandError(message: output.text) }
        let parts = output.stdout.components(separatedBy: marker)
        allPath = parts.count >= 3 ? parts[1].split(separator: ":").map(String.init) : []
        pathSources = allPath.reduce(into: [:]) { result, path in
            if let source = sourceLocation(for: path) { result[path] = source }
        }
        loaded = true
    }

    func membership(kind: String, directory: URL) -> PathMembership {
        let paths = [directory.path, directory.appendingPathComponent("bin").path, directory.appendingPathComponent("sbin").path]
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: envDirectory.appendingPathComponent(kind).path), destination == directory.path { return .app }
        let resolved = paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        if let path = allPath.first(where: { resolved.contains(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path) }) {
            return PathMembership(state: .shell, source: pathSources[path])
        }
        return .none
    }

    private func sourceLocation(for path: String) -> String? {
        let candidates = [path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path]
        for file in sourceFiles {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (index, line) in content.components(separatedBy: .newlines).enumerated()
                where !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") && candidates.contains(where: { line.contains($0) }) {
                return "\(tilde(file.path)):\(index + 1)"
            }
        }
        return nil
    }

    func removeLinks(pointingInside directory: URL) throws {
        let fm = FileManager.default
        let prefix = directory.resolvingSymlinksInPath().path + "/"
        let links = (try? fm.contentsOfDirectory(at: envDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        for link in links where link.resolvingSymlinksInPath().path.hasPrefix(prefix) {
            try? fm.removeItem(at: link)
        }
        try rewriteShellPath()
    }

    func removeLines(containing needle: String, from files: [URL]) throws -> Int {
        var changed = 0
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            let original = try String(contentsOf: file, encoding: .utf8)
            let next = original.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !String($0).localizedCaseInsensitiveContains(needle) }
                .joined(separator: "\n")
            guard next != original else { continue }
            try backup(original, name: file.lastPathComponent)
            try next.write(toFile: file.path, atomically: false, encoding: .utf8)
            changed += 1
        }
        return changed
    }

    func toggle(kind: String, directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: envDirectory, withIntermediateDirectories: true)
        let link = envDirectory.appendingPathComponent(kind)
        if let destination = try? fm.destinationOfSymbolicLink(atPath: link.path), destination == directory.path {
            try fm.removeItem(at: link)
        } else {
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(at: link, withDestinationURL: directory)
        }
        try rewriteShellPath()
    }

    func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = managedPaths().joined(separator: ":") + ":" + (environment["PATH"] ?? "")
        for (name, link) in managedExports() { environment[name] = link.resolvingSymlinksInPath().path }
        return environment
    }

    func saveAlias(_ alias: ServiceAlias, executable: URL) throws {
        let name = alias.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\") else { throw CommandError(message: L("error.aliasNameInvalid")) }
        try FileManager.default.createDirectory(at: aliasDirectory, withIntermediateDirectories: true)
        let file = aliasDirectory.appendingPathComponent(name)
        try "#!/bin/sh\nexec \(singleQuoted(executable.path)) \"$@\"\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        try rewriteShellPath()
    }

    func removeAlias(_ alias: ServiceAlias) throws {
        try? FileManager.default.removeItem(at: aliasDirectory.appendingPathComponent(alias.name))
    }

    private static let homeVariables = ["java": "JAVA_HOME"]

    private func managedExports() -> [(String, URL)] {
        let links = (try? FileManager.default.contentsOfDirectory(at: envDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return links.compactMap { link in
            guard let name = Self.homeVariables[link.lastPathComponent] else { return nil }
            return (name, link)
        }
    }

    private func managedPaths() -> [String] {
        let links = (try? FileManager.default.contentsOfDirectory(at: envDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return links.flatMap { [$0.path, $0.appendingPathComponent("bin").path, $0.appendingPathComponent("sbin").path] } + [aliasDirectory.path]
    }

    static func shellBlock(paths: [String], exports: [(String, String)], fish: Bool) -> String {
        let begin = "# >>> MacEnv PATH >>>"
        let end = "# <<< MacEnv PATH <<<"
        let quote: (String) -> String = { value in
            fish ? "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'" : singleQuoted(value)
        }
        let pathLine = fish
            ? "set -gx PATH \(paths.map(quote).joined(separator: " ")) $PATH\n"
            : "export PATH=\(quote(paths.joined(separator: ":"))):\"$PATH\"\n"
        let homeLines = exports.map { name, value in
            fish ? "set -gx \(name) \(quote(value))\n" : "export \(name)=\(quote(value))\n"
        }.joined()
        return "\(begin)\n\(pathLine)\(homeLines)\(end)\n"
    }

    private func rewriteShellPath() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: envDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: aliasDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: shellFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let begin = "# >>> MacEnv PATH >>>"
        let end = "# <<< MacEnv PATH <<<"
        let original = fm.fileExists(atPath: shellFile.path) ? try String(contentsOf: shellFile, encoding: .utf8) : ""
        var content = original
        if let start = content.range(of: begin), let finish = content.range(of: end, range: start.lowerBound..<content.endIndex) {
            content.removeSubrange(start.lowerBound..<finish.upperBound)
        }
        let block = Self.shellBlock(paths: managedPaths(),
                                    exports: managedExports().map { ($0.0, $0.1.path) },
                                    fish: shellName == "fish")
        if !content.isEmpty && !content.hasSuffix("\n") { content.append("\n") }
        let next = content + block
        guard next != original else { return }
        try backup(original, name: shellFile.lastPathComponent)
        try next.write(toFile: shellFile.path, atomically: false, encoding: .utf8)
    }

    private func backup(_ content: String, name: String) throws {
        guard !content.isEmpty else { return }
        let fm = FileManager.default
        let directory = root.appendingPathComponent("backup", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try content.write(to: directory.appendingPathComponent("\(name).\(stamp).bak"), atomically: true, encoding: .utf8)
        let olds = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(name + ".") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for item in olds.dropFirst(5) { try? fm.removeItem(at: item) }
    }
}
