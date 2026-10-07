import Foundation
import Darwin

// 「这个工具管了什么」表格里的一行。brew 是公式名 + 已装版本（可能多个），
// macports 是 port 名 + @版本，sdkman 是 candidate 名 + 版本目录名。
struct ToolItem: Identifiable, Hashable {
    let name: String
    let version: String

    var id: String { name + "|" + version }
}

// MacPorts 可装清单里的一行（版本管理页的 MacPorts 来源 tab）。
struct PortItem: Identifiable, Hashable {
    let name: String
    let version: String
    let installed: Bool

    var id: String { name }
}

// 版本管理页 MacPorts 一栏的加载与装/卸。八个模块的 VM 本来是逐字重复的一份，
// 收进协议扩展：VM 只要给 app 名（portCatalogs 的键），refresh() 复用它刷已装列表的那个。
// Database 按 mysql / mariadb 分开存两个清单，不在这儿，自己实现。
@MainActor
protocol PortListHost: AnyObject {
    var state: AppState { get }
    var services: Services { get }
    var portApp: String { get }
    var portItems: [PortItem] { get set }
    var portLoading: Bool { get set }
    func refresh() async
}

extension PortListHost {
    // 缓存先上屏（installed 按落点现判），新鲜就到此为止，过期才真跑 port search。
    func loadPortItems(force: Bool = false) async {
        portItems = services.tools.portCached(app: portApp)
        if !force, services.tools.portCacheFresh(app: portApp) { return }
        guard !portLoading else { return }
        portLoading = true
        defer { portLoading = false }
        portItems = await services.tools.portItems(app: portApp, force: force)
    }

    func portAction(_ action: String, _ item: PortItem) {
        state.runStreaming(taskTitle(action, item.name)) { report, _ in
            try await self.services.tools.port(action, app: self.portApp, name: item.name, report: report)
            // 装/卸不改变可装清单（port 名还在），缓存现判 installed 就够；
            // refresh() 负责把服务列表里新装的版本扫出来。
            await self.loadPortItems()
            await self.refresh()
        }
    }
}


// 第三方工具**本体**的检测、装、卸、更新。
//
// 跟「用这个工具装东西」是两件事，别混：
//   工具本体   → 环境工具页（/opt/homebrew、/opt/local、~/.sdkman）
//   用它装包   → 各模块版本管理页的来源 tab
// GVM 不在这里 —— 它只管 Go，本体管理留在 GoService，工具页那一格直接读 GoViewModel。
@MainActor
final class ToolService {
    let root: URL

    init(root: URL) { self.root = root }

    private var downloads: URL { root.appendingPathComponent("cache", isDirectory: true) }

    private static let brewInstaller = URL(string: "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh")!
    private static let brewUninstaller = URL(string: "https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh")!
    private static let sdkmanInstaller = URL(string: "https://get.sdkman.io")!
    private static let macPortsReleases = URL(string: "https://api.github.com/repos/macports/macports-base/releases/latest")!

    // MARK: - Homebrew

    var brewInstalled: Bool { Brew.executable != nil }

    // Apple Silicon 装 /opt/homebrew，Intel 装 /usr/local。install.sh 自己按 uname 决定，
    // 我们只是提前把目录建好并 chown 给当前用户 —— 不建的话它要走 sudo 弹密码，
    // GUI 里没有 TTY，必挂。
    var brewPrefix: String {
        #if arch(arm64)
        return "/opt/homebrew"
        #else
        return "/usr/local"
        #endif
    }

    func brewVersion() async -> String {
        guard let executable = Brew.executable else { return "" }
        let output = try? await Command.run(executable, ["--version"], environment: Command.brewEnvironment)
        // brew --version 第一行是「Homebrew 4.6.3」，后面几行是 homebrew-core / cask 的 git 摘要。
        return output?.stdout.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    // brew list --formula --versions 每行「名字 版本 版本…」：同一个公式装了多个版本会列好几列。
    func brewItems() async -> [ToolItem] {
        guard let executable = Brew.executable,
              let output = try? await Command.run(executable, ["list", "--formula", "--versions"], environment: Command.brewEnvironment) else { return [] }
        return output.stdout.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2 else { return nil }
            return ToolItem(name: parts[0], version: parts.dropFirst().joined(separator: ", "))
        }.sorted { $0.name < $1.name }
    }

    // install.sh 第 435 行 check_run_command_as_root：EUID == 0 直接 abort("Don't run this as root!")。
    // 所以「提权装 Homebrew」这条路是死的（官方 Homebrew.pkg 也只支持 Apple Silicon）。
    // 正确姿势只用一次提权：把 prefix 建好、chown 给当前用户，之后 prefix 可写，
    // install.sh 自己就不 sudo 了（第 593 行 prefix_parent 可写即免 sudo）。
    func installBrew(report: @escaping (String) -> Void, onStart: @escaping (Process) -> Void) async throws {
        try await privileged("mkdir -p \(brewPrefix) && chown \(getuid()):\(getgid()) \(brewPrefix)")
        let script = try await download(Self.brewInstaller, named: "homebrew-install.sh", report: report)
        let status = try await Command.stream("/bin/bash", [script.path], environment: ["NONINTERACTIVE": "1"],
                                              onStart: onStart, onOutput: report)
        guard status == 0 else { throw CommandError(message: L("error.toolCommandFailed") + "（\(status)）") }
    }

    // ⚠️ 全 App 最危险的按钮。uninstall.sh 会删掉 Homebrew **以及它装过的全部公式**，
    // 包括 MacEnv 正在管的 nginx / php / mysql / redis / go。
    // 它自己第 421 行的确认提示要 TTY（`-t 0`），GUI 里不弹确认直接开删 ——
    // 界面上那个确认框是唯一一道闸。
    func uninstallBrew(report: @escaping (String) -> Void) async throws {
        let script = try await download(Self.brewUninstaller, named: "homebrew-uninstall.sh", report: report)
        try await Command.privilegedStream("NONINTERACTIVE=1 /bin/bash \(singleQuoted(script.path))", report: report)
    }

    // MARK: - MacPorts

    var macPortsInstalled: Bool { FileManager.default.isExecutableFile(atPath: "/opt/local/bin/port") }

    func macPortsVersion() async -> String {
        guard macPortsInstalled else { return "" }
        // 没 sudo 时 port 会往 stderr 吐一行警告，版本号本身在 stdout，所以只认 stdout。
        let output = try? await Command.run("/opt/local/bin/port", ["version"])
        return firstCapture(#"Version:\s*([0-9][^\s]*)"#, in: output?.stdout ?? "") ?? ""
    }

    // port installed 的输出形如：
    //   The following ports are currently installed:
    //     autoconf @2.72_1 (active)
    // 没激活的也算装了，所以 (active) 只是后缀，不参与筛选。
    func macPortsItems() async -> [ToolItem] {
        guard macPortsInstalled, let output = try? await Command.run("/opt/local/bin/port", ["installed"]) else { return [] }
        return output.stdout.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, parts[1].hasPrefix("@") else { return nil }
            return ToolItem(name: String(parts[0]), version: String(parts[1].dropFirst()))
        }.sorted { $0.name < $1.name }
    }

    // pkg 的资产名按 macOS 大版本分：11 起是「-15-Sequoia.pkg」这种只有大版本的写法，
    // 10.x 带小版本（「-10.15-Catalina.pkg」）。匹配不到就报错给 releases 页 ——
    // 装一个给别的系统版本的 pkg，比不装危险得多。
    static func macPortsAsset(names: [String], os: OperatingSystemVersion) -> String? {
        let key = os.majorVersion >= 11 ? "-\(os.majorVersion)-" : "-\(os.majorVersion).\(os.minorVersion)-"
        return names.first { $0.hasSuffix(".pkg") && $0.contains(key) }
    }

    func installMacPorts(report: @escaping (String) -> Void) async throws {
        let (data, _) = try await URLSession.shared.data(from: Self.macPortsReleases)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]] else {
            throw CommandError(message: L("error.macPortsReleaseFailed"))
        }
        let names = assets.compactMap { $0["name"] as? String }
        guard let name = Self.macPortsAsset(names: names, os: ProcessInfo.processInfo.operatingSystemVersion),
              let asset = assets.first(where: { $0["name"] as? String == name }),
              let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) else {
            throw CommandError(message: String(format: L("error.macPortsNoPackage"), ProcessInfo.processInfo.operatingSystemVersionString))
        }
        let pkg = try await download(url, named: name, report: report)
        // 从网络下来的 pkg 带 com.apple.quarantine，installer 会因此拒装。
        _ = try? await Command.run("/usr/bin/xattr", ["-cr", pkg.path])
        try await Command.privilegedStream("/usr/sbin/installer -pkg \(singleQuoted(pkg.path)) -target /", report: report)
        guard macPortsInstalled else { throw CommandError(message: L("error.macPortsInstallFailed")) }
    }

    // 官方四步 + 第 5 步清 rc（在 ViewModel 里做，它才拿得到 PathService）。
    // 第一步的校验绝不能省：绝不对一台没有 MacPorts 痕迹的机器跑 rm -rf /opt/local。
    func uninstallMacPorts(report: @escaping (String) -> Void) async throws {
        guard macPortsInstalled else { throw CommandError(message: L("macports.missing")) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        try await Command.privilegedStream("""
        PATH=/opt/local/bin:/usr/bin:/bin /opt/local/bin/port -fp uninstall installed
        dscl . -delete /Users/macports
        dscl . -delete /Groups/macports
        rm -rf /opt/local /Applications/DarwinPorts /Applications/MacPorts \\
          /Library/LaunchDaemons/org.macports.* /Library/Receipts/DarwinPorts*.pkg \\
          /Library/Receipts/MacPorts*.pkg /Library/StartupItems/DarwinPortsStartup \\
          /Library/Tcl/darwinports1.0 /Library/Tcl/macports1.0 \(singleQuoted(home + "/.macports"))
        """, report: report)
    }

    // 单个 port 的卸载。`-q` 压掉「已经装过了」之类的提示，只留真错误。
    func uninstallMacPortsPort(_ name: String, report: @escaping (String) -> Void) async throws {
        try await Command.privilegedStream("PATH=/opt/local/bin:/usr/bin:/bin /opt/local/bin/port -q uninstall \(singleQuoted(name))", report: report)
    }

    // MARK: - MacPorts 可装清单（FlyEnv 同款）

    // 每个模块一份清单定义。查询用 port search --name --line --regex <正则>，
    // 输出一行一个 port：「名字\t版本\t类别\t描述」；描述用来滤掉正则圈进来的同名同族
    // （比如 jdk22 描述里的 Short Term Support 行，光靠正则分不出来）。
    // installed 判装按各模块自己的落点（跟 installedVersions 扫描的路径保持一致）。
    struct PortCatalog {
        let regex: String
        let descriptions: [String]
        let installed: (String) -> Bool
        // 装/卸时一起带上的伴随 port：FlyEnv 的做法 —— php 是个多 SAPI 大包，
        // 只装 php84 没有 fpm/mysql/apache2handler；mysql/mariadb 只装本体起不了服务。
        let companions: (String) -> [String]
    }

    static let portCatalogs: [String: PortCatalog] = [
        "nginx": PortCatalog(
            regex: "^nginx\\d*$",
            descriptions: ["High-performance HTTP(S) server"],
            installed: { name in FileManager.default.isExecutableFile(atPath: "/opt/local/sbin/\(name)") },
            companions: { _ in [] }),
        "php": PortCatalog(
            regex: "^php\\d*$",
            descriptions: ["PHP: Hypertext Preprocessor"],
            installed: { name in FileManager.default.isExecutableFile(atPath: "/opt/local/bin/\(name)") },
            companions: { name in ["\(name)-fpm", "\(name)-mysql", "\(name)-apache2handler", "\(name)-iconv"] }),
        "mysql": PortCatalog(
            regex: "^mysql([\\d]+)?$",
            descriptions: ["Multithreaded SQL database server"],
            installed: { name in FileManager.default.isExecutableFile(atPath: "/opt/local/lib/\(name)/bin/mysqld") },
            companions: { name in ["\(name)-server"] }),
        // mariadb 的版本化 port 是 mariadb-10.11 这种带连字符的写法，裸 mariadb 是 5.5 的老包。
        // 只写 ^mariadb([\d]+)?$ 会漏掉全部版本化 port，只列出一个 5.5。
        "mariadb": PortCatalog(
            regex: "^mariadb(-[\\d.]*\\d)?$",
            descriptions: ["Multithreaded SQL database server"],
            installed: { name in FileManager.default.isExecutableFile(atPath: "/opt/local/lib/\(name)/bin/mariadbd") },
            companions: { name in ["\(name)-server"] }),
        "redis": PortCatalog(
            regex: "^redis\\d*$",
            descriptions: ["Redis is an open source, advanced key-value store."],
            installed: { name in FileManager.default.isExecutableFile(atPath: "/opt/local/bin/\(name)-server") },
            companions: { _ in [] }),
        // Go 的 port 名就叫 go（1.27 起才有版本化的 go1.x 老写法早废弃），落点 /opt/local/lib/go。
        "golang": PortCatalog(
            regex: "^go$",
            descriptions: ["programming language developed by Google"],
            installed: { _ in FileManager.default.isExecutableFile(atPath: "/opt/local/lib/go/bin/gofmt") },
            companions: { _ in [] }),
        "java": PortCatalog(
            regex: "^((open)?)jdk([\\d\\.]*)$",
            descriptions: ["Oracle Java SE Development Kit ", "OpenJDK "],
            installed: { name in
                ["/opt/local/Library/Java/JavaVirtualMachines", "/Library/Java/JavaVirtualMachines"].contains {
                    FileManager.default.isExecutableFile(atPath: "\($0)/\(name)/Contents/Home/bin/java")
                }
            },
            companions: { _ in [] }),
        "maven": PortCatalog(
            regex: "^maven\\d*$",
            descriptions: ["build and project management environment"],
            installed: { name in FileManager.default.isExecutableFile(atPath: "/opt/local/share/java/\(name)/bin/mvn") },
            companions: { _ in [] }),
        "gradle": PortCatalog(
            regex: "^gradle\\d*$",
            descriptions: ["build system that is based on the Groovy language"],
            installed: { name in FileManager.default.isExecutableFile(atPath: "/opt/local/bin/\(name)") },
            companions: { _ in [] }),
        // composer 没有目录定义：MacPorts 里没有这个 port（port search 查不到），
        // Composer 页也就不给 MacPorts 来源 tab，跟 Redis / Swoole 没有 Static 来源是同一个道理。
        "mkcert": PortCatalog(
            regex: "^mkcert$",
            descriptions: ["locally trusted development certificates"],
            installed: { _ in FileManager.default.isExecutableFile(atPath: "/opt/local/bin/mkcert") },
            companions: { _ in [] })
    ]

    // 解析 port search --line 的输出。版本列可能带 @（port list 的写法），统一剥掉。
    // 解析是纯函数，拆出来给单测喂样例。
    static func parsePortSearch(_ text: String, descriptions: [String]) -> [(name: String, version: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard descriptions.isEmpty || descriptions.contains(where: line.contains) else { return nil }
            let parts = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard parts.count >= 2, !parts[0].isEmpty else { return nil }
            return (name: parts[0], version: parts[1].hasPrefix("@") ? String(parts[1].dropFirst()) : parts[1])
        }
    }

    // port search 要跑一两秒，结果落盘缓存（同 Static 目录的思路）：界面任何时候先显示
    // 上一次的结果，过期（一小时）才真正查询，查完平滑覆盖。查询失败保留旧缓存不弹错。
    // 缓存只存 name+version，installed 每次读缓存时按落点现判 —— 纯文件检查，
    // 装/卸之后状态立即就对，不用重跑 search。
    struct PortCachedItem: Codable {
        let name: String
        let version: String
    }

    private func portCacheURL(_ app: String) -> URL { root.appendingPathComponent("catalog/port-\(app).json") }
    private static let portRefreshInterval: TimeInterval = 3600

    private func readPortCache(_ app: String) -> [PortCachedItem] {
        guard let data = try? Data(contentsOf: portCacheURL(app)),
              let items = try? JSONDecoder().decode([PortCachedItem].self, from: data) else { return [] }
        return items
    }

    private func decorate(_ items: [PortCachedItem], app: String) -> [PortItem] {
        guard let catalog = Self.portCatalogs[app] else { return [] }
        // 版本从大到小：挑版本的人第一眼看最新的（localizedStandardCompare 按数字段比，
        // 10.x 才不会排到 9.x 前面去）。版本相同再按名字倒排兜底。
        return items.map { PortItem(name: $0.name, version: $0.version, installed: catalog.installed($0.name)) }
            .sorted {
                if $0.version == $1.version { return $0.name.localizedStandardCompare($1.name) == .orderedDescending }
                return $0.version.localizedStandardCompare($1.version) == .orderedDescending
            }
    }

    // 磁盘缓存直接上屏（installed 现判）。port 没装返回空表，界面有指路文案兜着。
    func portCached(app: String) -> [PortItem] {
        macPortsInstalled ? decorate(readPortCache(app), app: app) : []
    }

    // 缓存还新鲜就不必真查（界面据此跳过 spinner）。
    func portCacheFresh(app: String) -> Bool {
        let modified = (try? FileManager.default.attributesOfItem(atPath: portCacheURL(app).path))?[.modificationDate] as? Date
        return modified.map { Date().timeIntervalSince($0) < Self.portRefreshInterval } ?? false
    }

    // 某个模块在 MacPorts 里的可装清单。force 供手动刷新绕过缓存；
    // 自动加载走「缓存新鲜直接回、过期才查」的快路径。
    func portItems(app: String, force: Bool = false) async -> [PortItem] {
        guard macPortsInstalled, let catalog = Self.portCatalogs[app] else { return [] }
        if !force, portCacheFresh(app: app) { return portCached(app: app) }
        guard let output = try? await Command.run("/opt/local/bin/port", ["search", "--name", "--line", "--regex", catalog.regex]) else {
            // 查询失败保留旧缓存，别把上一次的结果清成空表。
            return portCached(app: app)
        }
        let items = Self.parsePortSearch(output.stdout, descriptions: catalog.descriptions)
            .map { PortCachedItem(name: $0.name, version: $0.version) }
        if !items.isEmpty {
            try? FileManager.default.createDirectory(at: portCacheURL(app).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(items).write(to: portCacheURL(app), options: .atomic)
        }
        return decorate(items, app: app)
    }

    // 装 / 卸一组 port。clean 先清掉上次装到一半的半成品（FlyEnv 同款）；
    // 卸载带 --follow-dependents 把连带的依赖一起收走。
    // PATH 带 /opt/local/sbin：装 php-fpm / mysql 这类时 port 要调 sbin 下的工具。
    func port(_ action: String, app: String, name: String, report: @escaping (String) -> Void) async throws {
        let names = ([name] + (Self.portCatalogs[app]?.companions(name) ?? [])).map(singleQuoted).joined(separator: " ")
        let verb = action == "uninstall" ? "uninstall --follow-dependents" : "install"
        let env = "PATH=/opt/local/bin:/opt/local/sbin:/usr/bin:/bin"
        try await Command.privilegedStream("""
        \(env) /opt/local/bin/port clean \(names)
        \(env) /opt/local/bin/port \(verb) \(names)
        """, report: report)
    }

    // MARK: - SDKMAN
    var sdkmanRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sdkman", isDirectory: true) }
    var sdkmanInitScript: URL { sdkmanRoot.appendingPathComponent("bin/sdkman-init.sh") }
    var sdkmanInstalled: Bool { FileManager.default.fileExists(atPath: sdkmanInitScript.path) }

    // 直接扫 candidates 目录，不问 `sdk list` —— 它只列当前渠道能下载的版本，
    // 用户装过的老版本可能已经下架、不在列表里（跟 GVM 的 listall vs list 是同一个坑）。
    func sdkmanItems() -> [ToolItem] {
        let fm = FileManager.default
        let candidates = sdkmanRoot.appendingPathComponent("candidates", isDirectory: true)
        var result: [ToolItem] = []
        for candidate in (try? fm.contentsOfDirectory(at: candidates, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
            let name = candidate.lastPathComponent
            for version in (try? fm.contentsOfDirectory(at: candidate, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
                guard version.lastPathComponent != "current" else { continue }
                result.append(ToolItem(name: name, version: version.lastPathComponent))
            }
        }
        return result.sorted { $0.id < $1.id }
    }

    // get.sdkman.io 的 bash 4 检查包在 `if [ -n "$BASH_VERSION" ]` 里，用 zsh 跑整个跳过 ——
    // macOS 自带的 /bin/bash 是 3.2，用 bash 跑会被它自己拒掉。脚本自己也处理 $ZSH_VERSION。
    // 所以不需要先 brew install bash（FlyEnv 那一步是多余的），也不需要提权。
    func installSDKMAN(report: @escaping (String) -> Void, onStart: @escaping (Process) -> Void) async throws {
        let script = try await download(Self.sdkmanInstaller, named: "sdkman-install.sh", report: report)
        let status = try await Command.stream("/bin/zsh", [script.path], onStart: onStart, onOutput: report)
        guard status == 0 else { throw CommandError(message: L("error.toolCommandFailed") + "（\(status)）") }
    }

    // SDKMAN 没有官方卸载命令（selfupdate 有，uninstall 没有），跟 GVM 一样自己做。
    func uninstallSDKMAN() throws {
        guard sdkmanInstalled else { throw CommandError(message: L("error.sdkmanMissing")) }
        try FileManager.default.removeItem(at: sdkmanRoot)
    }

    // `sdk` 是 sdkman-init.sh 里定义的 shell 函数，不在 PATH 上，必须先 source 才调得到。
    func uninstallSDKMANCandidate(_ candidate: String, version: String,
                                  report: @escaping (String) -> Void, onStart: @escaping (Process) -> Void) async throws {
        let command = "source \(singleQuoted(sdkmanInitScript.path)) && sdk uninstall \(singleQuoted(candidate)) \(singleQuoted(version))"
        let status = try await Command.stream("/bin/zsh", ["-c", command], onStart: onStart, onOutput: report)
        guard status == 0 else { throw CommandError(message: L("error.toolCommandFailed") + "（\(status)）") }
    }

    // SDKMAN 装的时候往这三个文件里写了 source 行（脚本 :507-530），卸载时三个都要扫。
    // 跟 GoService.profileFiles 差两个：SDKMAN 只碰 bash 和 zsh 的那三个。
    var sdkmanProfileFiles: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".zshrc", ".bashrc", ".bash_profile"].map { home.appendingPathComponent($0) }
    }

    // MARK: - 下载

    // 一次性的安装脚本 / pkg 放 MacEnv 的 cache 里，不落 /tmp：下次还能复用，
    // 而且这几个文件名固定，覆盖写不会越攒越多。
    private func download(_ url: URL, named name: String, report: @escaping (String) -> Void) async throws -> URL {
        let file = downloads.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try await Command.download(url, to: file, report: report)
        return file
    }
}
