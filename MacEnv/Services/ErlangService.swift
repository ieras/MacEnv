import Foundation

// Erlang/OTP 语言模块，同构于 Go / Java：无常驻进程，只管「机器上有哪些版本、把哪个放进 PATH」。
// 版本来源：Homebrew（erlang / erlang@主版本 一族）、MacPorts、用户自己装的
// （PATH 目录 + 自定义目录）。静态包没有 —— 官方 macOS 不发预编译发行版，
// one-env 那个接口实测返回空数组，唯一「官方包」是 kerl 现场编译，几十分钟，不惯着。
//
// version 记的是 OTP release（27 / 28）：brew 公式名、MacPorts port 名、
// RabbitMQ 的兼容矩阵、用户嘴里的「Erlang 27」全是这个口径。
// （erl -version 给的是 ERTS 版本 15.x，跟 OTP 不是一回事，不能拿来显示。）
@MainActor
final class ErlangService {
    let root: URL

    init(root: URL) { self.root = root }

    func installedVersions(customDirectories: [String] = []) async -> [ErlangVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String)] = []
        // brew：erlang 与 erlang@26/27/28 一族都装过的话，Cellar 下每个 keg 都有 bin/erl。
        for (file, _) in (try? await Brew.installedBinaries("erlang", binary: "erl")) ?? [] {
            candidates.append((file, "Homebrew"))
        }
        // MacPorts：固定落在 /opt/local/lib/erlang/bin/erl（FlyEnv 同款判据）。
        let port = URL(fileURLWithPath: "/opt/local/lib/erlang/bin/erl")
        if fm.isExecutableFile(atPath: port.path) { candidates.append((port, "MacPorts")) }
        // 用户自己装的（PATH 目录由 VM 一并传进来，kerl 默认装到 ~/erlang）。
        for item in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            if let found = Self.findErl(in: item) { candidates.append((found, L("source.custom"))) }
        }
        var seen = Set<String>()
        var result: [ErlangVersion] = []
        for (file, source) in candidates {
            // brew 的 keg 可能是软链，解析到真身再判重，否则同一个版本出现两行。
            let executable = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted else { continue }
            guard let version = try? await probe(executable) else { continue }
            result.append(ErlangVersion(version: version, directory: Self.erlRoot(of: executable), executable: executable, source: source))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    // 官方包的二进制在 bin 下；也有人直接把目录给到只有 erl 的那一层，两种都认（同 Go）。
    private static func findErl(in directory: URL) -> URL? {
        for path in ["bin/erl", "erl"] {
            let file = directory.appendingPathComponent(path)
            if FileManager.default.isExecutableFile(atPath: file.path), !isDirectory(file) { return file }
        }
        return nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    // ERL_ROOT = 装着 bin/ 的那一层。brew keg 根、/opt/local/lib/erlang 都算。
    static func erlRoot(of executable: URL) -> URL {
        let bin = executable.deletingLastPathComponent()
        return bin.lastPathComponent == "bin" ? bin.deletingLastPathComponent() : bin
    }

    private func probe(_ executable: URL) async throws -> String {
        // 起个 BEAM 问一句 OTP release 立即退，约 200ms；-noshell 不开 shell。
        // HOME 显式带上：GUI app 继承的环境里可能没有它，erl 找 .erlang.cookie 要用。
        let output = try await Command.run(executable.path, ["-noshell", "-eval", #"io:format("~s",[erlang:system_info(otp_release)]),halt()."#],
                                           environment: ["HOME": FileManager.default.homeDirectoryForCurrentUser.path])
        guard let version = Self.parseOtpRelease(output.stdout) else { throw CommandError(message: output.text) }
        return version
    }

    // 输出就是 "27"（io:format 直接写标准输出后立刻 halt）。
    // 宽松兜底：某些发行版会往标准输出混告警行，退而取任意两三位独立数字。
    // 但必须排除点分形态（15.2.1.2 这种是 ERTS 版本号，跟 OTP release 不是一回事，
    // 拿来显示就是错的），所以匹配后面不能跟着 .数字。
    static func parseOtpRelease(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return firstCapture(#"^(\d{1,3})$"#, in: trimmed) ?? firstCapture(#"\b(\d{2,3})\b(?!\.\d)"#, in: trimmed)
    }
}
