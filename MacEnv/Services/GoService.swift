import Foundation

// 对应 FlyEnv 的 GoLang 模块（src/fork/module/GoLang/index.ts + gvm.ts）。
// Go 没有常驻进程，这个模块只管两件事：机器上有哪些版本、把哪个放进 PATH。
//
// 版本来源有三处，跟 FlyEnv 的分法一致：
//   1. 我们自己装的静态包（server/golang/versions/golang-<版本>/bin/go）
//   2. 用户自己加的目录
//   3. GVM 装的（~/.gvm/gos/goX.Y.Z）—— GVM 是第三方 Go 版本管理器，
//      它装好的版本我们只读地扫进来，不接管它的目录结构。
@MainActor
final class GoService {
    let root: URL

    init(root: URL) { self.root = root }

    // 目录必须跟 StaticCatalogService（app = "golang"）算出来的完全一致，
    // 否则版本管理刚装完的包，已安装列表扫不到 —— 两边指的不是同一个地方。
    var versionsDirectory: URL { root.appendingPathComponent("server/golang/versions", isDirectory: true) }

    // MARK: - 已安装

    func installedVersions(customDirectories: [String] = []) async throws -> [GoVersion] {
        let fm = FileManager.default
        var candidates: [(URL, String)] = []
        for item in (try? fm.contentsOfDirectory(at: versionsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
            if let found = Self.findGo(in: item) { candidates.append((found, "Static")) }
        }
        // 常见的落点先自己扫一遍：brew / macports 的 go、golang.org/dl 的 ~/sdk/go*、
        // 以及手工多版本常用的 ~/go/go*。不然用户明明装了 Go，已安装列表却是空的。
        for item in defaultDirectories {
            if let found = Self.findGo(in: item) { candidates.append((found, L("source.system"))) }
        }
        for item in customDirectories.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            if let found = Self.findGo(in: item) { candidates.append((found, L("source.custom"))) }
        }
        for item in gvmGoDirectories() {
            if let found = Self.findGo(in: item) { candidates.append((found, "GVM")) }
        }
        var seen = Set<String>()
        var result: [GoVersion] = []
        for (file, source) in candidates {
            // 用户加的目录可能是软链（brew 的 go 就是），解析到真身再判重，否则同一个版本出现两行。
            let executable = file.resolvingSymlinksInPath()
            guard fm.isExecutableFile(atPath: executable.path), seen.insert(executable.path).inserted else { continue }
            guard let version = try? await probe(executable) else { continue }
            result.append(GoVersion(version: version,
                                    directory: Self.goRoot(of: executable),
                                    executable: executable,
                                    source: source))
        }
        return result.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    // 不写进用户的「自定义路径」列表：这些是约定俗成的落点，不是用户自己加的，
    // 免得他们想删一条自己没加过的目录。
    private var defaultDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var result = ["/usr/local/go", "/opt/homebrew/opt/go", "/opt/local/lib/go"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        for (parent, prefix) in [(home.appendingPathComponent("sdk", isDirectory: true), "go"),
                                (home.appendingPathComponent("go", isDirectory: true), "go")] {
            let entries = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            result += entries.filter { Self.isDirectory($0) && $0.lastPathComponent.hasPrefix(prefix) }
        }
        return result
    }

    // 官方包的二进制在 bin 下；也有人直接把目录给到只有 go 的那一层，两种都认。
    private static func findGo(in directory: URL) -> URL? {
        for path in ["bin/go", "go"] {
            let file = directory.appendingPathComponent(path)
            if FileManager.default.isExecutableFile(atPath: file.path), !isDirectory(file) { return file }
        }
        return nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    // GOROOT = 装着 bin/ 和 pkg/ 的那一层。gvm 装出来的 go 不显式给 GOROOT 就吐不出版本号，
    // 官方包给了也无害（本来就是这个值），所以统一带上。
    static func goRoot(of executable: URL) -> URL {
        let bin = executable.deletingLastPathComponent()
        return bin.lastPathComponent == "bin" ? bin.deletingLastPathComponent() : bin
    }

    private func probe(_ executable: URL) async throws -> String {
        let output = try await Command.run(executable.path, ["version"], environment: ["GOROOT": Self.goRoot(of: executable).path])
        guard output.status == 0, let version = firstCapture(#"go version go([0-9][^\s]*)"#, in: output.stdout) else {
            throw CommandError(message: output.text)
        }
        return version
    }

    // 静态包装完要清 Gatekeeper 的隔离标记：从网络下来的二进制一律带 com.apple.quarantine，
    // 不清的话第一次跑 go 系统直接弹「无法打开」。
    func clearQuarantine(_ version: StaticVersion) async throws {
        let target = versionsDirectory.appendingPathComponent("golang-\(version.version)")
        _ = try? await Command.run("/usr/bin/xattr", ["-cr", target.path])
    }

    // MARK: - GVM

    // GVM 自己认 GVM_ROOT，没设就按它的默认值 ~/.gvm。
    var gvmRoot: URL {
        let configured = (ProcessInfo.processInfo.environment["GVM_ROOT"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gvm", isDirectory: true)
            : URL(fileURLWithPath: configured, isDirectory: true)
    }

    var gvmInitScript: URL { gvmRoot.appendingPathComponent("scripts/gvm") }

    // gvm 装没装，就看它那个初始化脚本在不在 —— FlyEnv 判得一模一样。
    var gvmInstalled: Bool { FileManager.default.fileExists(atPath: gvmInitScript.path) }

    func gvmGoDirectories() -> [URL] {
        let gos = gvmRoot.appendingPathComponent("gos", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: gos, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return entries.filter { Self.isDirectory($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // listall 给可装列表，list 给已装列表（=> 打头的是 default），两边合起来才是完整视图：
    // 有些版本装过之后官方下架了，listall 里没有，但仍得在列表里显示成已安装。
    func gvmVersions() async throws -> [GvmVersion] {
        guard gvmInstalled else { throw CommandError(message: L("error.gvmMissing")) }
        let setup = "source \(singleQuoted(gvmInitScript.path))"
        // GVM 是 zsh 脚本（scripts/functions 用了 zsh 的 -regex-match），必须用 /bin/zsh 跑。
        // 用 /bin/bash 的话 bash 不认 zsh 语法，gvm 函数根本定义不出来，所有子命令全挂。
        async let available = Command.run("/bin/zsh", ["-c", "\(setup) && gvm listall"])
        async let installed = Command.run("/bin/zsh", ["-c", "\(setup) && gvm list"])
        let (all, have) = try await (available, installed)
        return Self.mergeGvm(available: all.stdout, installed: have.stdout)
    }

    static func mergeGvm(available: String, installed: String) -> [GvmVersion] {
        var names: [String] = []
        var seen = Set<String>()
        for line in available.split(separator: "\n") {
            guard let name = gvmName(String(line)), seen.insert(name).inserted else { continue }
            names.append(name)
        }
        var defaults: [String: Bool] = [:]
        for line in installed.split(separator: "\n") {
            guard let (name, isDefault) = gvmInstalledLine(String(line)) else { continue }
            defaults[name] = isDefault
            if seen.insert(name).inserted { names.append(name) }
        }
        return names.map {
            GvmVersion(name: $0,
                       version: $0.hasPrefix("go") ? String($0.dropFirst(2)) : $0,
                       installed: defaults[$0] != nil,
                       isDefault: defaults[$0] ?? false)
        }
    }

    private static func gvmName(_ line: String) -> String? {
        let name = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return isGvmIdentifier(name) ? name : nil
    }

    private static func gvmInstalledLine(_ line: String) -> (String, Bool)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let isDefault = trimmed.hasPrefix("=>")
        guard let name = gvmName(isDefault ? String(trimmed.dropFirst(2)) : trimmed) else { return nil }
        return (name, isDefault)
    }

    // gvm 的标识符形如 go1.24.4。rc / beta 这种它自己也不认，跟着一起滤掉。
    private static func isGvmIdentifier(_ value: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"^go\d+\.\d+\.\d+$"#) else { return false }
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    private static let gvmInstaller = "https://raw.githubusercontent.com/moovweb/gvm/master/binscripts/gvm-installer"

    // GOROOT 指向一个已经不存在的目录时（上一个默认版本被删了），gvm 每条命令都会带着坏 GOROOT 跑。
    // 先把悬空的 default 清掉再干活，FlyEnv 的 sanitize 也是这一步。
    private static let gvmSanitize = #"if [ -n "$GOROOT" ] && [ ! -d "$GOROOT" ]; then rm -f "$GVM_ROOT/environments/default"; unset GOROOT GOPATH GOBIN gvm_go_name gvm_pkgset_name; fi"#

    // GVM installer 往这些文件里挑**已存在的**追加 source 行（它的 update_profile），没有标记注释，
    // 所以卸载时只能挨个扫一遍、按内容删行。fish 的配置不可能是 bash 语法那行，不用管。
    var profileFiles: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".zshrc", ".zprofile", ".bashrc", ".bash_profile", ".profile"].map { home.appendingPathComponent($0) }
    }

    // 卸载 GVM 本体：整个 GVM_ROOT 连锅端 —— gos（装的 Go 版本）、pkgsets（GOPATH 工作区）、
    // archive（下载缓存）、environments 全在它底下，一起删才算干净。
    //
    // 官方的 `gvm implode` 用不了：它 read -p 要确认，GUI 进程没 TTY；而且它只删 GVM_ROOT，
    // 不管 shell 配置里那行 source，比这更不干净。
    func uninstallGvm() throws {
        guard gvmInstalled else { throw CommandError(message: L("error.gvmMissing")) }
        // 「装没装」的判据只有 scripts/gvm 存在，理论上 GVM_ROOT 指到家目录也能满足 —— 那个绝不能删。
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        guard gvmRoot.resolvingSymlinksInPath().path != home else { throw CommandError(message: L("error.gvmRootUnsafe")) }
        try FileManager.default.removeItem(at: gvmRoot)
    }

    func installGvm(onStart: @escaping (Process) -> Void, onOutput: @escaping (String) -> Void) async throws {
        // 这时候还没有 gvm 的初始化脚本可 source，所以单独跑官方 installer。
        try await run("bash < <(curl -sSL \(Self.gvmInstaller))", onStart: onStart, onOutput: onOutput)
    }
    // install 加 -B：装预编译的二进制包，而不是把源码拉下来现场编译（那要几十分钟）。
    func gvm(_ action: GvmAction, version: GvmVersion, onStart: @escaping (Process) -> Void, onOutput: @escaping (String) -> Void) async throws {
        var script = ""
        switch action {
        case .install: script = "gvm install \(version.name) -B"
        case .uninstall:
            script = "gvm uninstall \(version.name)"
            // 删的正好是默认版本时，default 那条软链会指到一个不存在的目录，得跟着删。
            if version.isDefault { script += #" && rm -f "$GVM_ROOT/environments/default""# }
        case .useDefault: script = "gvm use \(version.name) --default"
        }
        try await run("source \(singleQuoted(gvmInitScript.path)) && \(Self.gvmSanitize) && \(script)", onStart: onStart, onOutput: onOutput)
    }

    private func run(_ command: String, onStart: @escaping (Process) -> Void, onOutput: @escaping (String) -> Void) async throws {
        // 同上：gvm 的 install/uninstall/use 都是 zsh 子命令，必须 /bin/zsh。
        // onStart 把 Process 交回调用方（AppState 的任务日志靠它做取消），服务本身不持有进程。
        let status = try await Command.stream("/bin/zsh", ["-c", command], onStart: onStart, onOutput: onOutput)
        guard status == 0 else { throw CommandError(message: L("error.gvmFailed") + "（\(status)）") }
    }

}
