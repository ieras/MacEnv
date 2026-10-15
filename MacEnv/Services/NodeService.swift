import Foundation

// NodeJs 没有常驻进程、没有配置文件、没有日志，只管两件事 —— 机器上有哪些 node、
// 把哪个放进 PATH。同构于 GoService，差异是版本来源多了 nvm / fnm 两个第三方管理器
// 和 MacPorts 的 nodejs 系 port。
//
// nvm / fnm 的策略跟 GVM 在 GoService 里的处境一样：只读地扫进「已安装」列表 + 命令
// 代理装卸（zsh 流式输出），不接管它们的目录结构。nvm 的 default 只显示成徽章 ——
// PATH 归属走 MacEnv 自己的 env/node 软链，跟 nvm 的 use/default 语义正交。
@MainActor
final class NodeService {
    let root: URL

    init(root: URL) { self.root = root }

    // 必须跟 StaticCatalogService(app: "node") 算出来的完全一致，
    // 否则版本管理刚装完的包，已安装列表扫不到 —— 两边指的不是同一个地方。
    var versionsDirectory: URL { root.appendingPathComponent("server/node/versions", isDirectory: true) }

    // MARK: - 版本源（nodejs.org/dist）

    static let distIndex = URL(string: "https://nodejs.org/dist/index.json")!

    struct DistEntry: Decodable {
        let version: String
        let files: [String]
        let lts: Lts

        // lts 字段是 false 或代号字符串（"Jod"），两种都要接住。
        enum Lts: Decodable {
            case off
            case on(String)

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let flag = try? container.decode(Bool.self) {
                    self = flag ? .on("") : .off
                } else if let name = try? container.decode(String.self) {
                    self = .on(name)
                } else {
                    self = .off
                }
            }

            var codename: String? {
                if case .on(let name) = self, !name.isEmpty { return name }
                return nil
            }
        }
    }

    // one-env 不支持 node（实测「app 类型错误」），直连 nodejs.org 官方的 index.json ——
    // 结构化数据，比解析 dist 目录 HTML 稳得多。LTS 代号留在这层，
    // VM 拿去渲染徽章（StaticVersion 没有这个字段，不该为 Node 去改那个共用结构）。
    static func distEntries() async throws -> [DistEntry] {
        let (data, response) = try await URLSession.shared.data(from: distIndex)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw CommandError(message: L("error.catalogRequestFailed") + "（HTTP \(status)）")
        }
        return try JSONDecoder().decode([DistEntry].self, from: data)
    }

    // 纯函数，喂样例就能验。只留带本架构 macOS 包的条目，URL 按官方模板拼
    // （tar.gz 比 tar.xz 小，StaticCatalogService 对 .gz 走 -xzf）。
    // ⚠️ index.json 的 files 标识是 osx-arm64-tar / osx-x64-tar（不是 darwin-arm64，
    // 那个只在下载文件名里出现）—— 曾经照文件名口径写过滤条件，真实数据每条都被毙掉，
    // 静态列表静默全空，单测 fixture 又跟着臆想写，全绿也照样漏。
    static func parseDist(_ entries: [DistEntry]) -> [StaticVersion] {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x64"
        #endif
        return entries.compactMap { entry in
            guard entry.files.contains("osx-\(arch)-tar") else { return nil }
            let bare = String(entry.version.dropFirst())  // "v22.11.0" → "22.11.0"
            let url = URL(string: "https://nodejs.org/dist/\(entry.version)/node-\(entry.version)-darwin-\(arch).tar.gz")!
            return StaticVersion(name: "Node-\(bare)", version: bare, url: url,
                                 downloaded: false, installed: false, lts: entry.lts.codename)
        }
        .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    // MARK: - 已安装

    func installedVersions(customDirectories: [String] = []) async -> [NodeVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String)] = []
        for item in contents(of: versionsDirectory) {
            if let found = Self.findNode(in: item) { candidates.append((found, "Static")) }
        }
        for item in brewKegs() {
            if let found = Self.findNode(in: item) { candidates.append((found, "Homebrew")) }
        }
        if let found = macPortsNode() {
            candidates.append((found, "MacPorts"))
        }
        for item in await nvmDirectories() {
            if let found = Self.findNode(in: item) { candidates.append((found, "nvm")) }
        }
        for item in await fnmDirectories() {
            if let found = Self.findNode(in: item) { candidates.append((found, "fnm")) }
        }
        for item in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            // 用户加的既可能是 Node 根，也可能是「装着若干版本的目录」，两种都认。
            if let found = Self.findNode(in: item) {
                candidates.append((found, L("source.custom")))
            } else {
                for child in contents(of: item) {
                    if let found = Self.findNode(in: child) { candidates.append((found, L("source.custom"))) }
                }
            }
        }
        // nvm default 的版本号。命令失败（没装 / 挂掉）就 nil —— 徽章不显示，
        // 但不该把上面的扫描结果一起判成失败。fnm 的 default 是纯文件读（aliases/default）。
        let nvmDefault = await nvmDefaultVersion()
        let fnmDefault = await fnmDefaultVersion()
        var seen = Set<String>()
        var result: [NodeVersion] = []
        for (file, source) in candidates {
            // 解析软链再判重：brew 的 opt 链接和 Cellar 真身是同一个版本，不解析会出两行。
            // 但记下来的仍是未解析的那条路径 —— 它跨 brew upgrade 不变，env/node 软链指向它才不会漂。
            let resolved = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: resolved.path), seen.insert(resolved.path).inserted else { continue }
            guard let version = await probe(file) else { continue }
            result.append(NodeVersion(version: version,
                                      directory: Self.nodeRoot(of: file),
                                      executable: file,
                                      source: source,
                                      isNvmDefault: source == "nvm" && version == nvmDefault,
                                      isFnmDefault: source == "fnm" && version == fnmDefault))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    private func contents(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
    }

    // Homebrew 的 node 公式族：node 本身 + node@20 / node@22 这些版本化公式。
    // 扫 opt 目录挑 keg —— 跟 PythonService 的 defaultHomes 一个路子。
    private func brewKegs() -> [URL] {
        ["/opt/homebrew/opt", "/usr/local/opt"].flatMap { path in
            contents(of: URL(fileURLWithPath: path, isDirectory: true)).filter {
                $0.lastPathComponent == "node" || $0.lastPathComponent.hasPrefix("node@")
            }
        }
    }

    // MacPorts 的 nodejs 系 port 二进制同名（nodejs / nodejs18 / nodejs22 都装
    // /opt/local/bin/node），按二进制分不出装的是哪个 port —— 判据用 MacPorts 自己的
    // registry（/opt/local/var/macports/software/<port名>/），纯文件检查。
    // /opt/local/bin/node 也可能是 Intel 版 brew 装的：那个会被 brewKegs 那条路扫到
    // （软链解析后判重），所以这里先要求 registry 里有 nodejs 系 port。
    private func macPortsNode() -> URL? {
        let registry = URL(fileURLWithPath: "/opt/local/var/macports/software", isDirectory: true)
        let hasPort = contents(of: registry).contains { $0.lastPathComponent.hasPrefix("nodejs") }
        let binary = URL(fileURLWithPath: "/opt/local/bin/node", isDirectory: false)
        guard hasPort, FileManager.default.isExecutableFile(atPath: binary.path) else { return nil }
        return binary
    }

    // 官方包是 <包根>/bin/node；用户也可能把目录给到只有 node 的那一层；
    // fnm 的版本目录多一层 installation（<版本>/installation/bin/node）。三种都认。
    private static func findNode(in directory: URL) -> URL? {
        let fm = FileManager.default
        for path in ["bin/node", "installation/bin/node", "node"] {
            let file = directory.appendingPathComponent(path)
            if fm.isExecutableFile(atPath: file.path), !Self.isDirectory(file) { return file }
        }
        return nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    // Node 根 = 装着 bin/ 的那一级 —— PATH 上加的其实是它下面的 bin/
    // （PathService.managedPaths 对 env 软链补 bin 和 sbin 两条）。fnm 的版本目录
    // 多一层 installation（<版本>/installation/bin），它的 PATH 单元就是 installation
    // —— 退两级正好落到它，别再多退一级。
    static func nodeRoot(of executable: URL) -> URL {
        let bin = executable.deletingLastPathComponent()
        return bin.lastPathComponent == "bin" ? bin.deletingLastPathComponent() : bin
    }

    private func probe(_ executable: URL) async -> String? {
        let output = try? await Command.run(executable.path, ["--version"])
        return firstCapture("v([0-9][^\\s]*)", in: output?.text ?? "")
    }

    // 静态包装完清 Gatekeeper 隔离标记，不清第一次跑 node 系统弹「无法打开」（同 Go / Python）。
    func clearQuarantine(_ version: StaticVersion) async {
        let target = versionsDirectory.appendingPathComponent("node-\(version.version)")
        _ = try? await Command.run("/usr/bin/xattr", ["-cr", target.path])
    }

    // MARK: - nvm

    // NVM_DIR 在 GUI 进程里大概率没有（用户只在 shell rc 里 export），先问登录 shell，
    // 拿不到按 nvm 自己的默认值 ~/.nvm。
    func nvmRoot() async -> URL {
        if let value = await envValue("NVM_DIR"), !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nvm", isDirectory: true)
    }

    // nvm 装没装看它的初始化脚本在不在 —— 跟 GoService 判 GVM 一模一样。
    func nvmInstalled() async -> Bool {
        FileManager.default.fileExists(atPath: (await nvmRoot()).appendingPathComponent("nvm.sh").path)
    }

    // nvm 的版本目录：$NVM_DIR/versions/node/v*。
    func nvmDirectories() async -> [URL] {
        guard await nvmInstalled() else { return [] }
        return contents(of: (await nvmRoot()).appendingPathComponent("versions/node", isDirectory: true))
    }

    // 跑 `nvm alias default` 拿 nvm 自己的默认版本（输出形如 `default -> v22.11.0 (-> N/A)`）。
    func nvmDefaultVersion() async -> String? {
        guard await nvmInstalled() else { return nil }
        let root = await nvmRoot()
        let script = "export NVM_DIR=\"\(root.path)\"; . \"\(root.path)/nvm.sh\"; nvm alias default"
        guard let output = try? await Command.run("/bin/zsh", ["-c", script]) else { return nil }
        return Self.parseNvmDefault(output.text)
    }

    // 单拎出来为了能单测：正则写错一个字，default 徽章就永远不显示，
    // 而这种错跑真 nvm 才暴露 —— 测不起。
    static func parseNvmDefault(_ text: String) -> String? {
        firstCapture("default\\s*->\\s*v?([0-9][^\\s]*)", in: text)
    }

    // nvm 是 shell 函数不是二进制，必须 source nvm.sh 再跑子命令（同 GVM 在 GoService 里的做法）。
    // 走 /bin/zsh -c：nvm.sh 自包含，不读 rc。
    func nvm(_ action: String, version: String, onStart: @escaping (Process) -> Void, onOutput: @escaping (String) -> Void) async throws {
        let root = await nvmRoot()
        let status = try await Command.stream("/bin/zsh", ["-c",
            "export NVM_DIR=\"\(root.path)\"; . \"\(root.path)/nvm.sh\"; nvm \(action) \(version)"],
            onStart: onStart, onOutput: onOutput)
        guard status == 0 else { throw CommandError(message: L("error.nvmFailed") + "（\(status)）") }
    }

    // MARK: - fnm

    // FNM_DIR 同理问登录 shell；拿不到试 fnm 的平台默认（macOS 是
    // ~/Library/Application Support/fnm，Linux/通用是 ~/.local/share/fnm）。
    func fnmDirectory() async -> URL? {
        if let value = await envValue("FNM_DIR"), FileManager.default.fileExists(atPath: value) {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for candidate in ["Library/Application Support/fnm", ".local/share/fnm"] {
            let url = home.appendingPathComponent(candidate, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    func fnmInstalled() async -> Bool {
        guard let output = try? await Command.run("/bin/zsh", ["-lc", "fnm --version"]) else { return false }
        return output.status == 0 && output.stdout.contains(where: \.isNumber)
    }

    // fnm 的版本目录：$FNM_DIR/node-versions/v*。
    func fnmDirectories() async -> [URL] {
        guard await fnmInstalled(), let dir = await fnmDirectory() else { return [] }
        return contents(of: dir.appendingPathComponent("node-versions", isDirectory: true))
    }

    // fnm 的默认版本：$FNM_DIR/aliases/default 文件里存的就是版本号（纯文件读，
    // 跟 nvm 的 `nvm alias default` 命令同效）。没这个文件就是没设默认。
    func fnmDefaultVersion() async -> String? {
        guard let dir = await fnmDirectory() else { return nil }
        let text = (try? String(contentsOf: dir.appendingPathComponent("aliases/default"), encoding: .utf8)) ?? ""
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // fnm 是二进制，但 GUI 的 PATH 里不一定有（brew 装的和手动装的落点不一样），
    // 用登录 shell 跑 —— PATH 是用户 rc 里那份。
    func fnm(_ action: String, version: String, onStart: @escaping (Process) -> Void, onOutput: @escaping (String) -> Void) async throws {
        let status = try await Command.stream("/bin/zsh", ["-lc", "fnm \(action) \(version)"],
            onStart: onStart, onOutput: onOutput)
        guard status == 0 else { throw CommandError(message: L("error.fnmFailed") + "（\(status)）") }
    }

    // MARK: - 工具

    // 登录 shell 里问一个变量的值。GUI app 继承不到 rc 里的 export，
    // nvm / fnm 的目录变量（NVM_DIR / FNM_DIR）只在 shell 里有，必须这么问。
    // 只取 stdout —— rc 里 echo 的东西都走 stderr，别混进来。
    private func envValue(_ name: String) async -> String? {
        guard let output = try? await Command.run("/bin/zsh", ["-lc", "printf '%s' \"$\(name)\""]) else { return nil }
        let value = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - 本体装卸（版本管理页顶栏「安装 / 更新 / 卸载」操作的是管理器自己）

    // 官方安装脚本。nvm 钉 v0.40.4（nvm 官方 README 的推荐装法就是
    // curl 这个带版本号的脚本）；fnm 用官方 install 入口（永远指向最新）。
    // 两者都没有自更新命令 —— 「更新」= 重跑安装脚本，官方脚本幂等，重跑即升级。
    private static let nvmInstaller = "https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh"
    private static let fnmInstaller = "https://fnm.vercel.app/install"

    // 安装脚本往这些文件里挑**已存在的**追加初始化行（NVM_DIR + source nvm.sh），
    // 没有标记注释，所以卸载时只能挨个扫一遍、按内容删行（同 GoService 的 GVM）。
    var profileFiles: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".zshrc", ".zprofile", ".bashrc", ".bash_profile", ".profile"].map { home.appendingPathComponent($0) }
    }

    // 安装 / 更新本体：跑官方脚本（curl | bash，zsh -lc 带上用户 PATH）。
    func installManager(_ manager: String, onStart: @escaping (Process) -> Void, onOutput: @escaping (String) -> Void) async throws {
        let url = manager == "nvm" ? Self.nvmInstaller : Self.fnmInstaller
        let status = try await Command.stream("/bin/zsh", ["-lc", "curl -o- \(url) | bash"],
                                             onStart: onStart, onOutput: onOutput)
        guard status == 0 else {
            throw CommandError(message: L(manager == "nvm" ? "error.nvmFailed" : "error.fnmFailed") + "（\(status)）")
        }
    }

    // 删 nvm / fnm 本体目录 —— 它装的所有 Node 版本都在里面，一起删才算干净。
    // 调用方（VM）负责先摘 env 软链、后清 shell 配置里的初始化行。
    // 防呆：nvm 的判据目录里必须有 nvm.sh；NVM_DIR / FNM_DIR 理论上能指到家目录，
    // 那个绝不能删（同 GoService.uninstallGvm 的守卫）。
    func uninstallManager(_ manager: String) async throws {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        if manager == "nvm" {
            let root = await nvmRoot()
            guard root.resolvingSymlinksInPath().path != home else { throw CommandError(message: L("error.nvmRootUnsafe")) }
            guard fm.fileExists(atPath: root.appendingPathComponent("nvm.sh").path) else { throw CommandError(message: L("error.nvmMissing")) }
            try fm.removeItem(at: root)
        } else {
            guard let dir = await fnmDirectory() else { throw CommandError(message: L("error.fnmMissing")) }
            guard dir.resolvingSymlinksInPath().path != home else { throw CommandError(message: L("error.fnmRootUnsafe")) }
            try fm.removeItem(at: dir)
        }
    }
}
