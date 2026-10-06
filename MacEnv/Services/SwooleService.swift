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
            // 每次扫描都补一遍运行时文件：用户手删了 php 或 composer 能自愈，已存在的不覆盖。
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
        // 装完还要补 composer.phar 和 cacert.pem（两个网络下载），日志里得看得见。
        try await prepareRuntime(executable, download: true, report: report)
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
    private func prepareRuntime(_ executable: URL, download: Bool, report: @escaping (String) -> Void = { _ in }) async throws {
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
            try await Command.download(composerURL, to: composer, report: report)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: composer.path)
            try await Command.download(cacertURL, to: base.appendingPathComponent("cacert.pem"), report: report)
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
}
