import Foundation

// 对应 FlyEnv 的 Composer 模块。composer 不是服务，没有进程要托管：
// 一个自包含的 .phar，拷成 composer 加个可执行位就能用，剩下的只有版本管理和 PATH。
@MainActor
final class ComposerService {
    let root: URL

    var directory: URL { root.appendingPathComponent("server/composer", isDirectory: true) }
    var versionsDirectory: URL { directory.appendingPathComponent("versions", isDirectory: true) }

    init(root: URL) { self.root = root }

    func installedVersions(customDirectories: [String] = []) throws -> [ComposerVersion] {
        let fm = FileManager.default
        var candidates: [URL] = []
        for item in (try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
            candidates.append(item.appendingPathComponent("bin/composer"))
        }
        for item in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            for path in ["composer", "bin/composer"] { candidates.append(item.appendingPathComponent(path)) }
        }
        var seen = Set<String>()
        var result: [ComposerVersion] = []
        for file in candidates {
            let executable = file.resolvingSymlinksInPath()
            // composer 是个 phar：__HALT_COMPILER() 之后紧跟二进制清单和压缩负载，
            // 整个文件不是合法 UTF-8。String(contentsOf:encoding:.utf8) 是严格解码，
            // 碰到非法字节直接返回 nil，会把候选整个吃掉 —— 用户自己装在 PATH 里的
            // composer 就是这么消失的。改用 String(decoding:as:)，非法字节变替换字符，
            // 不抛错；VERSION 那行本身是 ASCII，正则照样能命中。
            // 读文件也比执行它省事，不用管用户有没有装能跑得起来的 php。
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted,
                  let data = try? Data(contentsOf: executable, options: .mappedIfSafe),
                  let version = firstCapture("public const VERSION = '(\\d+(?:\\.\\d+){1,4})'", in: String(decoding: data, as: UTF8.self)) else { continue }
            result.append(ComposerVersion(version: version,
                                          directory: executable.deletingLastPathComponent().deletingLastPathComponent(),
                                          executable: executable))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    func install(_ version: StaticVersion) async throws {
        let fm = FileManager.default
        // 放 bin/ 里，跟 PHP / Swoole 的结构对齐，PathService 往 PATH 里塞的就是 <版本目录>/bin。
        let bin = versionsDirectory.appendingPathComponent("composer-\(version.version)").appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let composer = bin.appendingPathComponent("composer")
        let (temporary, response) = try await URLSession.shared.download(from: version.url)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw CommandError(message: L("error.downloadFailed") + "（HTTP \(status)）")
        }
        try? fm.removeItem(at: composer)
        try fm.moveItem(at: temporary, to: composer)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: composer.path)
    }

    func uninstall(_ version: StaticVersion) throws {
        try FileManager.default.removeItem(at: versionsDirectory.appendingPathComponent("composer-\(version.version)"))
    }
}
