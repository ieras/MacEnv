import Foundation

// 对应 FlyEnv 的 SwooleCli 模块。swoole-cli 是自包含的 PHP 运行时：
// 同一个二进制既能当 swoole-cli 也能当 php，所以装完要拷一份改名 php，
// 再把 composer 和 cacert.pem 放进 bin，它才算真的能用。
//
// 包是平铺的（swoole-cli / LICENSE / pack-sfx.php），所以不能复用
// StaticCatalogService.install —— 它按「二进制往上退两级」找包根目录，
// 平铺包会一路退到 versions 目录本身。跟 PHP 的裸二进制是同一个坑。
@MainActor
final class SwooleService {
    let root: URL

    var directory: URL { root.appendingPathComponent("server/swoole-cli", isDirectory: true) }
    var versionsDirectory: URL { directory.appendingPathComponent("versions", isDirectory: true) }
    private var archives: URL { root.appendingPathComponent("cache", isDirectory: true) }

    private let composerURL = URL(string: "https://getcomposer.org/download/latest-stable/composer.phar")!
    private let cacertURL = URL(string: "https://curl.se/ca/cacert.pem")!

    init(root: URL) { self.root = root }

    // 二进制放 bin/ 而不是版本根目录，这样跟 PHP 的 bin/php 结构一致，
    // StaticCatalogService 的「已安装」标记也能直接对上。
    func installedVersions(customDirectories: [String] = []) async throws -> [SwooleVersion] {
        let fm = FileManager.default
        var candidates: [URL] = []
        for item in (try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
            for path in ["bin/swoole-cli", "swoole-cli"] {
                let file = item.appendingPathComponent(path)
                if fm.isExecutableFile(atPath: file.path) { candidates.append(file); break }
            }
        }
        for item in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            for path in ["swoole-cli", "bin/swoole-cli"] {
                let file = item.appendingPathComponent(path)
                if fm.isExecutableFile(atPath: file.path) { candidates.append(file) }
            }
        }
        var seen = Set<String>()
        var result: [SwooleVersion] = []
        for file in candidates {
            let executable = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted else { continue }
            // 每次扫描都补一遍运行时文件：用户手删了 php 或 composer 能自愈，已存在的不覆盖。
            try? await prepareRuntime(executable, download: false)
            guard let probe = try? await probe(executable) else { continue }
            result.append(SwooleVersion(version: probe.swoole,
                                        phpVersion: probe.php,
                                        directory: executable.deletingLastPathComponent().deletingLastPathComponent(),
                                        executable: executable))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    func install(_ version: StaticVersion) async throws {
        let archive = archives.appendingPathComponent("static-swoole-cli-\(version.version).tar.\(version.url.pathExtension)")
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        try await fetch(version.url, to: archive)

        let target = versionsDirectory.appendingPathComponent("swoole-cli-\(version.version)")
        try? FileManager.default.removeItem(at: target)
        let bin = target.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let output = try await Command.run("/usr/bin/tar", ["-xJf", archive.path, "-C", bin.path])
        guard output.status == 0 else { throw CommandError(message: output.text) }
        let executable = bin.appendingPathComponent("swoole-cli")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CommandError(message: L("error.binaryMissing") + "swoole-cli")
        }
        try await prepareRuntime(executable, download: true)
    }

    // 一次调用拿两个版本号：PHP_VERSION 是内置的 PHP，swoole_version() 是 swoole 自己。
    // FlyEnv 为了这两个值要按顺序试 5 条命令，这里一条就够。
    private func probe(_ executable: URL) async throws -> (swoole: String, php: String) {
        let ini = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("php.ini")
        // 显式带上 -c，否则加载的是编译时写死的路径，我们写的 php.ini 就白配了。
        var arguments = FileManager.default.fileExists(atPath: ini.path) ? ["-c", ini.path] : []
        arguments += ["-r", "echo PHP_VERSION, \" \", swoole_version();"]
        let output = try await Command.run(executable.path, arguments)
        let parts = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard output.status == 0, parts.count == 2 else { throw CommandError(message: output.text) }
        return (String(parts[1]), String(parts[0]))
    }

    // 把版本目录补成一个能用的运行时。幂等：文件已存在就跳过，用户改过的配置不会被扫描抹掉。
    private func prepareRuntime(_ executable: URL, download: Bool) async throws {
        let fm = FileManager.default
        let bin = executable.deletingLastPathComponent()
        let base = bin.deletingLastPathComponent()

        // swoole-cli 靠文件名决定自己扮演 swoole-cli 还是 php，所以必须有一份叫 php 的。
        let php = bin.appendingPathComponent("php")
        if !fm.fileExists(atPath: php.path) {
            try fm.copyItem(at: executable, to: php)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: php.path)
        }
        // 从网络下来的二进制会被打上 quarantine 标记，不清掉 Gatekeeper 直接拦。
        _ = try? await Command.run("/usr/bin/xattr", ["-cr", bin.path])

        if download {
            let composer = bin.appendingPathComponent("composer")
            try await fetch(composerURL, to: composer)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: composer.path)
            try await fetch(cacertURL, to: base.appendingPathComponent("cacert.pem"))
        }

        // 模板在 PhpDefaults/swoole-cli/ 下，落地时改名成 swoole-cli 真正会读的 php.ini / php-fpm.conf。
        for (name, template) in [("php.ini", "swoole.ini"), ("php-fpm.conf", "swoole-fpm.conf")] {
            let target = base.appendingPathComponent(name)
            guard !fm.fileExists(atPath: target.path),
                  let source = Bundle.main.url(forResource: "PhpDefaults", withExtension: nil)?
                      .appendingPathComponent("swoole-cli").appendingPathComponent(template) else { continue }
            // 模板里的 cacert 路径得指向这个版本自己的目录，否则 curl / openssl 找不到证书。
            let content = try String(contentsOf: source, encoding: .utf8)
                .replacingOccurrences(of: "__MACENV_CACERT__", with: base.appendingPathComponent("cacert.pem").path)
            try content.write(to: target, atomically: true, encoding: .utf8)
        }
    }

    private func fetch(_ source: URL, to file: URL) async throws {
        if FileManager.default.fileExists(atPath: file.path) { return }
        let (temporary, response) = try await URLSession.shared.download(from: source)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw CommandError(message: L("error.downloadFailed") + "（HTTP \(status)）")
        }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
    }
}
