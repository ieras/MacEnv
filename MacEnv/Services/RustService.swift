import Foundation

// Rust 没有常驻进程，这个模块只管两件事：机器上有哪些 rustc、把哪个放进 PATH。
//
// 版本来源四处：
//   1. 我们自己装的静态包（server/rust/versions/rust-<版本>/bin/rustc）
//   2. Homebrew 的 rust 公式
//   3. MacPorts 的 rust port
//   4. rustup 的工具链（~/.rustup/toolchains/<工具链>/bin/rustc）—— rustup 是官方工具链
//      管理器，它装的版本只读地扫进来，不接管它的目录结构（同 GVM 在 GoService 的处境）。
//
// 静态包跟别的模块有一处实质差别：官方 tar.xz 里二进制躺在 rustc/bin/、cargo/bin/ 下，
// 不在标准 bin/，所以不能走 StaticCatalogService 的「二进制往上退两级」定位法 —— 那个是
// 给 go / python / gradle 那种标准包用的，平铺包会一路退到 versions 目录本身（swoole-cli
// 踩过同一个坑，那边也是自己写 install）。这里解包后跑包内的 install.sh，由官方安装器
// 把各组件重排成标准 bin/ + lib/。
@MainActor
final class RustService {
    let root: URL

    init(root: URL) { self.root = root }

    // 必须跟 StaticCatalogService(app: "rust") 算出来的完全一致，
    // 否则版本管理刚装完的包，已安装列表扫不到 —— 两边指的不是同一个地方。
    var versionsDirectory: URL { root.appendingPathComponent("server/rust/versions", isDirectory: true) }
    private var archives: URL { root.appendingPathComponent("cache", isDirectory: true) }

    // MARK: - 版本源（static.rust-lang.org/dist）

    // one-env 的 rust 只给 x86_64 的包（传 arch=arm 也回 x86_64-apple-darwin，实测过），
    // 在 Apple Silicon 上装下来是跑不动的 Intel 版。所以只用它拿版本号列表，
    // 下载地址按官方模板自己拼成本机架构的 —— 官方直链格式多年没变，
    // 老版本（1.83）和新版本（1.99）实测都是 200。
    static func versions() async throws -> [StaticVersion] {
        parseVersions(try await StaticCatalogService.oneEnv(app: "rust", displayName: "Rust"), host: currentHost)
    }

    // 官方包名的平台三元组。
    static var currentHost: String {
        #if arch(arm64)
        "aarch64-apple-darwin"
        #else
        "x86_64-apple-darwin"
        #endif
    }

    // 纯函数，喂样例就能验：只换下载地址，版本号列表原样继承。
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
            // 用户加的既可能是 Rust 根，也可能是「装着若干版本的目录」，两种都认。
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
            // 解析软链再判重：brew 的 opt 链接和 Cellar 真身是同一个版本，不解析会出两行。
            // 但记下来的仍是未解析的那条路径 —— 它跨 brew upgrade 不变，env/rust 软链指向它才不会漂。
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

    // Homebrew 的 rust 公式装在 <prefix>/opt/rust，可执行文件在 <keg>/bin/rustc。
    private func brewKegs() -> [URL] {
        ["/opt/homebrew/opt", "/usr/local/opt"].flatMap { path in
            contents(of: URL(fileURLWithPath: path, isDirectory: true)).filter { $0.lastPathComponent == "rust" }
        }
    }

    // MacPorts 的 rust port 二进制在 /opt/local/bin/rustc。按二进制分不出装的是哪个 port，
    // 判据用 MacPorts 自己的 registry（/opt/local/var/macports/software/rust/），纯文件检查。
    // /opt/local/bin/rustc 也可能是 Intel 版 brew 装的：那个会被 brewKegs 那条路扫到
    // （软链解析后判重），所以这里先要求 registry 里有 rust port。
    private func macPortsRustc() -> URL? {
        let registry = URL(fileURLWithPath: "/opt/local/var/macports/software", isDirectory: true)
        let hasPort = contents(of: registry).contains { $0.lastPathComponent.hasPrefix("rust") }
        let binary = URL(fileURLWithPath: "/opt/local/bin/rustc", isDirectory: false)
        guard hasPort, FileManager.default.isExecutableFile(atPath: binary.path) else { return nil }
        return binary
    }

    // 静态包跑完 install.sh 后是标准 <根>/bin/rustc；rustup 的工具链也是 <工具链>/bin/rustc；
    // 用户也可能把目录给到只有 rustc 的那一层。两种都认。
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

    // Rust 根 = 装着 bin/ 的那一级 —— PATH 上加的其实是它下面的 bin/
    // （PathService.managedPaths 对 env 软链补 bin 和 sbin 两条）。
    static func rustRoot(of executable: URL) -> URL {
        let bin = executable.deletingLastPathComponent()
        return bin.lastPathComponent == "bin" ? bin.deletingLastPathComponent() : bin
    }

    // `rustc --version` → "rustc 1.99.0 (…) "。取三段式版本号。
    // 单拎出来为了能单测：正则写错一个字，所有版本都扫不出来，而这种错只有跑真 rustc 才暴露。
    static func parseVersion(_ output: String) -> String? {
        firstCapture(#"rustc (\d+\.\d+\.\d+)"#, in: output)
    }

    private func probe(_ executable: URL) async -> String? {
        let output = try? await Command.run(executable.path, ["--version"])
        guard output?.status == 0 else { return nil }
        return Self.parseVersion(output?.stdout ?? "")
    }

    // 静态包装完清 Gatekeeper 隔离标记，不清第一次跑 rustc 系统弹「无法打开」（同 Go / Node）。
    func clearQuarantine(_ version: StaticVersion) async {
        let target = versionsDirectory.appendingPathComponent("rust-\(version.version)")
        _ = try? await Command.run("/usr/bin/xattr", ["-cr", target.path])
    }

    // MARK: - 静态包装卸

    // 官方包形状：rust-<版本>-<平台>/{rustc,cargo,rust-std-*,install.sh,...}，二进制不在 bin/ 下。
    // 所以解包后必须跑包内的 install.sh 重排布局 —— 这是 rust-installer 官方安装器的标准用法，
    // 不是我们发明的。--prefix=/ 让包内路径原样展开，--destdir 把结果落到指定目录。
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
        // 包根是 staging 下唯一的目录，install.sh 就在它下面。
        guard let packageRoot = contents(of: staging).first(where: Self.isDirectory),
              fm.isExecutableFile(atPath: packageRoot.appendingPathComponent("install.sh").path) else {
            try? fm.removeItem(at: archive)
            throw CommandError(message: L("error.binaryMissing") + "rustc")
        }
        let out = staging.appendingPathComponent("out", isDirectory: true)
        // install.sh 靠相对路径找各组件目录，必须先 cd 到包根再跑。
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

    // CARGO_HOME / RUSTUP_HOME 在 GUI 进程里大概率没有（用户只在 shell rc 里 export），
    // 先问登录 shell，拿不到按官方默认值 ~/.cargo、~/.rustup。
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

    // rustup 装没装看它的二进制在不在 —— rustup 是二进制不是 shell 函数，判据比 GVM 简单。
    func rustupInstalled() async -> Bool {
        FileManager.default.isExecutableFile(atPath: (await rustupBinary()).path)
    }

    private func rustupBinary() async -> URL {
        await cargoHome().appendingPathComponent("bin/rustup")
    }

    // rustup 的工具链目录：$RUSTUP_HOME/toolchains/<工具链名>。
    func rustupToolchainDirectories() async -> [URL] {
        guard await rustupInstalled() else { return [] }
        return contents(of: (await rustupHome()).appendingPathComponent("toolchains", isDirectory: true))
    }

    // 默认工具链的目录：问 `rustup show active-toolchain`（输出形如
    // "stable-aarch64-apple-darwin (default)"），比解析 settings.toml 稳 ——
    // 那个文件的格式会随 rustup 版本变，命令输出不会。
    func rustupDefaultDirectory() async -> URL? {
        guard await rustupInstalled() else { return nil }
        guard let output = try? await Command.run((await rustupBinary()).path, ["show", "active-toolchain"]),
              output.status == 0 else { return nil }
        guard let name = Self.parseActiveToolchain(output.stdout) else { return nil }
        return (await rustupHome()).appendingPathComponent("toolchains/\(name)", isDirectory: true)
    }

    // 取第一段工具链名。没设默认时 rustup 打的是 "error: no active toolchain" ——
    // 那种不算工具链名，返回 nil（默认徽章不显示，但不该把扫描结果一起判成失败）。
    static func parseActiveToolchain(_ output: String) -> String? {
        let name = output.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return name.isEmpty || name.hasPrefix("error") ? nil : name
    }

    // rustup 是二进制，但 GUI 的 PATH 里不一定有（装在 ~/.cargo/bin，只有 rc 里才加进去），
    // 拿绝对路径调最稳。action 走 rustup 自己的子命令：toolchain install / toolchain uninstall /
    // default（设默认）。版本号 rustup 自己能解析成 <版本>-<平台> 的完整工具链名。
    func rustup(_ arguments: [String], onStart: @escaping (Process) -> Void, onOutput: @escaping (String) -> Void) async throws {
        guard await rustupInstalled() else { throw CommandError(message: L("error.rustupMissing")) }
        let status = try await Command.stream((await rustupBinary()).path, arguments, onStart: onStart, onOutput: onOutput)
        guard status == 0 else { throw CommandError(message: L("error.rustupFailed") + "（\(status)）") }
    }

    // MARK: - 本体装卸（版本管理页顶栏「安装 / 更新 / 卸载」操作的是 rustup 自己）

    // 官方安装脚本。--proto '=https' --tlsv1.2 是官网给的写法；-y 走非交互 ——
    // GUI 进程没 TTY，不加会卡在确认提示上。
    // rustup 没有自更新命令（`rustup self update` 只对自编译的 rustup 有效，官方脚本装的是
    // 完整版会直接报错），所以「更新」= 重跑安装脚本，官方脚本幂等。
    private static let rustupInstaller = "https://sh.rustup.rs"

    func installManager(onStart: @escaping (Process) -> Void, onOutput: @escaping (String) -> Void) async throws {
        let script = "curl --proto '=https' --tlsv1.2 -sSf \(Self.rustupInstaller) | sh -s -- -y"
        let status = try await Command.stream("/bin/sh", ["-c", script], onStart: onStart, onOutput: onOutput)
        guard status == 0 else { throw CommandError(message: L("error.rustupFailed") + "（\(status)）") }
    }

    // rustup 自带卸载（`rustup self uninstall -y`）：它会把 ~/.cargo/bin 下的代理程序、
    // ~/.rustup 和 shell 配置里那两行初始化一起清掉，比我们自己删目录干净。
    func uninstallManager(onStart: @escaping (Process) -> Void, onOutput: @escaping (String) -> Void) async throws {
        try await rustup(["self", "uninstall", "-y"], onStart: onStart, onOutput: onOutput)
    }

    // MARK: - 工具

    // 登录 shell 里问一个变量的值。GUI app 继承不到 rc 里的 export，
    // CARGO_HOME / RUSTUP_HOME 只在 shell 里有，必须这么问。只取 stdout。
    private func envValue(_ name: String) async -> String? {
        guard let output = try? await Command.run("/bin/zsh", ["-lc", "printf '%s' \"$\(name)\""]) else { return nil }
        let value = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
