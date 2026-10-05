import Foundation

// 维护 MacEnv 自己的 PATH 软链接、shell 配置区块和命令别名。
@MainActor
final class PathService {
    let root: URL
    private(set) var allPath: [String] = []
    private var loaded = false

    var envDirectory: URL { root.appendingPathComponent("env", isDirectory: true) }
    var aliasDirectory: URL { root.appendingPathComponent("alias", isDirectory: true) }

    // 不是所有人都用 zsh，所以 shell 从 $SHELL 取，取不到或不可执行才退回 zsh。
    private var shell: String {
        let value = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        return FileManager.default.isExecutableFile(atPath: value) ? value : "/bin/zsh"
    }

    private var shellName: String { (shell as NSString).lastPathComponent }

    // fish 的配置文件和语法都跟 POSIX 系不同，单独认。
    private var shellFile: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch shellName {
        case "fish": return home.appendingPathComponent(".config/fish/config.fish")
        case "bash": return home.appendingPathComponent(".bash_profile")
        case "zsh": return home.appendingPathComponent(".zshrc")
        default: return home.appendingPathComponent(".profile")
        }
    }

    init(root: URL) { self.root = root }

    // 问 PATH 要跑一次交互式登录 shell（用户的整个 rc 都得执行），非常贵 —— 所以缓存住，
    // 只有第一次（或 force）才真正去问。启动时 phpVM.refresh 第一个跑完这次询问，
    // 其余 VM 全部命中缓存；togglePath 改完软链后必须 force 重读。
    func refresh(force: Bool = false) async throws {
        guard force || !loaded else { return }
        // 必须带 -i：PATH 一般写在 .zshrc / .bashrc 里，非交互 shell 压根不读这些文件，
        // 之前只加 -l，读出来的 PATH 里永远没有 MacEnv 自己写进去的那几行。
        // 结果用标记包起来，免得用户 rc 里 echo 的东西混进来。
        let marker = "__MACENV_PATH__"
        let value = shellName == "fish" ? "string join : $PATH" : "\"$PATH\""
        let output = try await Command.run(shell, ["-ilc", "printf '\(marker)%s\(marker)' \(value)"])
        guard output.status == 0 else { throw CommandError(message: output.text) }
        let parts = output.stdout.components(separatedBy: marker)
        allPath = parts.count >= 3 ? parts[1].split(separator: ":").map(String.init) : []
        loaded = true
    }

    func membership(kind: String, directory: URL) -> PathMembership {
        let paths = [directory.path, directory.appendingPathComponent("bin").path, directory.appendingPathComponent("sbin").path]
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: envDirectory.appendingPathComponent(kind).path), destination == directory.path { return .app }
        // PATH 里写的有可能是软链接（FlyEnv 的 env/php/bin 这类），两边都解析一次再比，
        // 否则二进制明明在 PATH 里能跑，界面上却显示成没启用。
        let resolved = paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        if allPath.contains(where: { resolved.contains(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path) }) { return .shell }
        return .none
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
        return environment
    }

    func saveAlias(_ alias: ServiceAlias, executable: URL) throws {
        let name = alias.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\") else { throw CommandError(message: L("error.aliasNameInvalid")) }
        try FileManager.default.createDirectory(at: aliasDirectory, withIntermediateDirectories: true)
        let file = aliasDirectory.appendingPathComponent(name)
        // 别名脚本要用用户自己的 shell 跑；fish 里 $@ 得写成 $argv。
        try "#!\(shell)\n\(doubleQuoted(executable.path)) \(shellName == "fish" ? "$argv" : "$@")\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        try rewriteShellPath()
    }

    func removeAlias(_ alias: ServiceAlias) throws {
        try? FileManager.default.removeItem(at: aliasDirectory.appendingPathComponent(alias.name))
    }

    private func managedPaths() -> [String] {
        let links = (try? FileManager.default.contentsOfDirectory(at: envDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return links.flatMap { [$0.path, $0.appendingPathComponent("bin").path, $0.appendingPathComponent("sbin").path] } + [aliasDirectory.path]
    }

    private func rewriteShellPath() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: envDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: aliasDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: shellFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let begin = "# >>> MacEnv PATH >>>"
        let end = "# <<< MacEnv PATH <<<"
        let original = (try? String(contentsOf: shellFile, encoding: .utf8)) ?? ""
        var content = original
        if let start = content.range(of: begin), let finish = content.range(of: end, range: start.lowerBound..<content.endIndex) {
            content.removeSubrange(start.lowerBound..<finish.upperBound)
        }
        let paths = managedPaths()
        // fish 的 PATH 是数组，得一个一个塞，不能用 export PATH="a:b:c" 那套。
        let block = shellName == "fish"
            ? "\(begin)\nset -gx PATH \(paths.map { "\"\($0)\"" }.joined(separator: " ")) $PATH\n\(end)\n"
            : "\(begin)\nexport PATH=\"\(paths.joined(separator: ":")):$PATH\"\n\(end)\n"
        if !content.isEmpty && !content.hasSuffix("\n") { content.append("\n") }
        let next = content + block
        // 内容一模一样就别动用户的文件，也别留备份。
        guard next != original else { return }
        try backup(original)
        try next.write(to: shellFile, atomically: true, encoding: .utf8)
    }

    // 改用户的 shell 配置文件之前先留一份。只保留最近 5 份，免得越攒越多。
    private func backup(_ content: String) throws {
        guard !content.isEmpty else { return }
        let fm = FileManager.default
        let directory = root.appendingPathComponent("backup", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = shellFile.lastPathComponent
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try content.write(to: directory.appendingPathComponent("\(name).\(stamp).bak"), atomically: true, encoding: .utf8)
        let olds = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(name + ".") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for item in olds.dropFirst(5) { try? fm.removeItem(at: item) }
    }
}
