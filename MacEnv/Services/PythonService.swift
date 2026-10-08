import Foundation

// 对应 FlyEnv 的 Python 模块（src/fork/module/Python/index.ts）。
// Python 跟 Go / Java 同构：没有常驻进程、没有配置文件、没有日志（FlyEnv 那边
// getConfigFiles / getLogFiles 都是空数组），只管两件事 —— 机器上有哪些解释器、把哪个放进 PATH。
//
// 比 Go / Java 多出来的唯一一层是 shim：没有任何一个目录能同时提供 python 和 python3
// （Homebrew 的 keg 里 bin/ 只有 python3、libexec/bin/ 只有 python；MacPorts 的 Portfile
// 在 post-destroot 里直接把 ${prefix}/bin/python3 删掉，交给 port select 管），
// 所以不能像 Java 那样把 Home 直接塞进 PATH —— 用户启用之后敲 python 会找不到解释器。
@MainActor
final class PythonService {
    let root: URL

    init(root: URL) { self.root = root }

    // 必须跟 StaticCatalogService(app: "python") 算出来的完全一致，
    // 否则版本管理刚装完的解释器，已安装列表扫不到 —— 两边指的不是同一个地方。
    var versionsDirectory: URL { root.appendingPathComponent("server/python/versions", isDirectory: true) }

    // shim 必须放在 env/ 外面：managedPaths() 会把 env/ 下**每一个**条目都塞进 PATH，
    // 放里面的话所有版本的 shim 一起生效，等于没隔离。
    var shimsDirectory: URL { root.appendingPathComponent("shims/python", isDirectory: true) }

    // MARK: - 已安装

    func installedVersions(customDirectories: [String] = []) async -> [PythonVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String)] = []
        for item in (try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
            if let found = Self.findPython(in: item) { candidates.append((found, "Static")) }
        }
        for (parent, source) in defaultParents {
            for item in (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
                if let found = Self.findPython(in: item) { candidates.append((found, source)) }
            }
        }
        for (home, source) in defaultHomes {
            if let found = Self.findPython(in: home) { candidates.append((found, source)) }
        }
        for item in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            // 用户加的既可能是一个 Python Home，也可能是「装着若干版本的目录」，两种都认。
            if let found = Self.findPython(in: item) {
                candidates.append((found, L("source.custom")))
            } else {
                for child in (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
                    if let found = Self.findPython(in: child) { candidates.append((found, L("source.custom"))) }
                }
            }
        }
        var seen = Set<String>()
        var result: [PythonVersion] = []
        for (file, source) in candidates {
            // 解析软链再判重：brew 的 opt 链接和 Cellar 真身是同一个解释器，不解析会出两行。
            // 但记下来的仍是未解析的那条路径 —— 它跨 brew upgrade 不变，shim 指向它才不会漂。
            let resolved = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: resolved.path), seen.insert(resolved.path).inserted else { continue }
            guard let version = await probe(file) else { continue }
            result.append(PythonVersion(version: version,
                                        directory: Self.pythonHome(of: file),
                                        executable: file,
                                        source: source))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    // 「装着若干版本的目录」和「自己就是 Python Home 的目录」是两回事，必须分开列。混进一个
    // 数组、调用点统一多枚举一层，Homebrew 的 keg 就会被整条跳过去（JavaService 栽过这个跟头）。
    private var defaultParents: [(URL, String)] {
        [(URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions", isDirectory: true), "python.org"),
         (URL(fileURLWithPath: "/opt/local/Library/Frameworks/Python.framework/Versions", isDirectory: true), "MacPorts")]
    }

    private var defaultHomes: [(URL, String)] {
        let entries = ["/opt/homebrew/opt", "/usr/local/opt"].flatMap {
            (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: $0), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        }
        // 公式族是 python / python@3.9 … python@3.14，按名字前缀挑 —— 整个 opt 目录不能扫，
        // 那底下全是别的公式。写成 hasPrefix("python") 会把 python-yq 这类也捞进来。
        let kegs = entries.filter { $0.lastPathComponent == "python" || $0.lastPathComponent.hasPrefix("python@") }
        // /usr/bin/python3 是 Xcode CLT 带的那个，用户 which python3 看到的就是它 ——
        // 不显示会让人以为自己的 python3 凭空消失了。
        return kegs.map { ($0, "Homebrew") } + [(URL(fileURLWithPath: "/usr", isDirectory: true), L("source.system"))]
    }

    // 解释器的落点就这几种。MacPorts 和 python.org 的 framework 里只有带小版本名的入口
    // （python3.12），裸 python3 不一定有，所以最后再扫一遍 bin/。
    private static func findPython(in directory: URL) -> URL? {
        let fm = FileManager.default
        for path in ["libexec/bin/python", "bin/python3", "bin/python", "python3", "python"] {
            let file = directory.appendingPathComponent(path)
            if fm.isExecutableFile(atPath: file.path) { return file }
        }
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        let entries = [bin, directory].flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] }
        return entries.first { entry in
            entry.lastPathComponent.range(of: "^python[23]\\.\\d+$", options: .regularExpression) != nil
                && fm.isExecutableFile(atPath: entry.path)
        }
    }

    // Python Home = 装着 bin/ 的那一级。Homebrew 把解释器藏在 libexec/bin 下，多一层 ——
    // libexec 那层不是 Home，直接退两级会退成 python@3.12/libexec。
    static func pythonHome(of executable: URL) -> URL {
        let bin = executable.deletingLastPathComponent()
        guard bin.lastPathComponent == "bin" else { return bin }
        let parent = bin.deletingLastPathComponent()
        return parent.lastPathComponent == "libexec" ? parent.deletingLastPathComponent() : parent
    }

    private func probe(_ executable: URL) async -> String? {
        // Python 2 把 --version 的结果写到 stderr，CommandOutput.text 已经把两路合并。
        let output = try? await Command.run(executable.path, ["--version"])
        return Self.parseVersion(output?.text ?? "")
    }

    static func parseVersion(_ text: String) -> String? {
        firstCapture("Python\\s+([0-9][^\\s]*)", in: text)
    }

    // 静态包解完要清 Gatekeeper 的隔离标记：不清的话第一次跑 python3 系统直接弹「无法打开」。
    func clearQuarantine(_ version: StaticVersion) async {
        let target = versionsDirectory.appendingPathComponent("python-\(version.version)")
        _ = try? await Command.run("/usr/bin/xattr", ["-cr", target.path])
    }

    // MARK: - Static 源（python-build-standalone）

    // one-env 对 python 返回空数组 —— 它认这个 app 名，但一个包都没有。所以换 astral 的
    // python-build-standalone（uv 和 Rye 底层用的就是它）：releases/latest 一次请求就能拿到
    // macOS 全部 install_only 资产（5 个活跃分支 × 2 个架构），不用翻 release 列表。
    static let standaloneReleases = URL(string: "https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest")!

    private struct GitHubRelease: Decodable {
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
    }

    static func standaloneVersions() async throws -> [StaticVersion] {
        let (data, response) = try await URLSession.shared.data(from: standaloneReleases)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw CommandError(message: L("error.catalogRequestFailed") + "（HTTP \(status)）")
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        return parseStandalone(release.assets.map { ($0.name, $0.browserDownloadURL) })
            .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    // 纯函数，喂样例就能验。资产名自带版本、构建号和架构，一次正则挑完。
    static func parseStandalone(_ assets: [(name: String, url: URL)]) -> [StaticVersion] {
        #if arch(arm64)
        let arch = "aarch64"
        #else
        let arch = "x86_64"
        #endif
        let pattern = "^cpython-([0-9]+\\.[0-9]+\\.[0-9]+)\\+\\d+-" + arch + "-apple-darwin-install_only\\.tar\\.gz$"
        return assets.compactMap { name, url in
            guard let version = firstCapture(pattern, in: name) else { return nil }
            return StaticVersion(name: "Python-\(version)", version: version, url: url, downloaded: false, installed: false)
        }
    }

    // MARK: - PATH shim

    // 把名字补全：python / python3 / python3.12 三条软链，都指向同一个解释器。
    // Python 2 没有 python3 这个名字，硬建一个指到 2.7 上去纯属误导。
    static func shimNames(_ version: String) -> [String] {
        let parts = version.split(separator: ".").map(String.init)
        guard parts.first == "3" else { return ["python"] }
        return ["python", "python3"] + (parts.count >= 2 ? ["python3.\(parts[1])"] : [])
    }

    // 目录名带版本和路径摘要，按版本隔离 —— env/python 的软链目标才会跟着版本变，
    // PathService.membership 才能判出当前启用的是哪一个（共用一个目录就永远判不出来）。
    func shimDirectory(for version: PythonVersion) -> URL {
        shimsDirectory.appendingPathComponent("python-\(version.version)-\(Self.fnv1a(version.executable.path))", isDirectory: true)
    }

    // 建好 shim 目录再交回给 PathService：往后的事（软链、写 shell 配置、判 membership）
    // 跟 Java / Go 完全一样。
    func shim(for version: PythonVersion) throws -> URL {
        let fm = FileManager.default
        let directory = shimDirectory(for: version)
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in Self.shimNames(version.version) {
            let link = bin.appendingPathComponent(name)
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != version.executable.path {
                try? fm.removeItem(at: link)
                try fm.createSymbolicLink(at: link, withDestinationURL: version.executable)
            }
        }
        return directory
    }

    private func shimTargets() -> [(shim: URL, interpreter: URL)] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: shimsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return entries.compactMap { entry in
            let bin = entry.appendingPathComponent("bin", isDirectory: true)
            guard let destination = try? fm.destinationOfSymbolicLink(atPath: bin.appendingPathComponent("python").path) else { return nil }
            return (entry, URL(fileURLWithPath: destination, relativeTo: bin).standardizedFileURL)
        }
    }

    // 版本被删掉之后（brew uninstall 我们不知道什么时候发生），它的 shim 目录和 env/python
    // 软链就变成死链了。判据是「shim 指向的解释器还在不在」，交回给调用方顺手删掉 ——
    // 删 env 软链要重写 shell 配置，那是 PathService 的事。
    func staleShims() -> [URL] {
        let fm = FileManager.default
        return shimTargets().filter { !fm.isExecutableFile(atPath: $0.interpreter.path) }.map(\.shim)
    }

    // 卸载静态包时用：找出解释器落在 directory 内的那些 shim，得在删目录之前连它们一起摘掉，
    // 否则 env/python 会指向一个空壳（shim 目录还在，只是链接全断了）。
    func shims(pointingInside directory: URL) -> [URL] {
        let prefix = directory.resolvingSymlinksInPath().path + "/"
        return shimTargets().filter { $0.interpreter.resolvingSymlinksInPath().path.hasPrefix(prefix) }.map(\.shim)
    }

    // 摘要不能用 String.hashValue：它带进程级随机种子，重启就变，软链路径会漂。
    static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    // MacPorts 的 port 名不带点（python312），framework 的目录名带点（Versions/3.12）。
    nonisolated static func macPortsVersion(_ name: String) -> String? {
        let digits = name.dropFirst("python".count)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return digits.count > 1 ? "\(digits.first!).\(digits.dropFirst())" : String(digits)
    }
}
