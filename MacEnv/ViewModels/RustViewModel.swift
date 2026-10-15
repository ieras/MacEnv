import SwiftUI

@MainActor
final class RustViewModel: ObservableObject, PortListHost {
    let state: AppState
    let services: Services

    @Published var versions: [RustVersion] = []
    @Published var staticVersions: [StaticVersion] = []
    @Published var staticLoading = false
    // 版本管理里的 Homebrew 一栏：rust 公式。
    @Published var formulae: [BrewFormulaItem] = []
    @Published var pathMembership: [String: PathMembership] = [:]
    @Published var selectedID: String?
    @Published var customDirectories = UserDefaults.standard.stringArray(forKey: "macenv.rust.directories") ?? [] {
        didSet { UserDefaults.standard.set(customDirectories, forKey: "macenv.rust.directories") }
    }

    // rustup 装没装（nil = 还没检测出来，界面不显示它的安装入口）。版本管理页现问。
    @Published var rustupInstalled: Bool?
    // 安装路径（环境工具页的面板要显示，点开就是 Finder）。跟装没装一起检测时顺手缓存 ——
    // 不能每次渲染都去问一遍登录 shell（cargoHome() 要跑 zsh -lc）。
    @Published var rustupPath = ""

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    var selectedVersion: RustVersion? { versions.first { $0.id == selectedID } ?? versions.first }

    func refresh() async {
        do {
            // 先问一次登录 shell 拿真实 PATH，再把 PATH 里的目录也当扫描目标 ——
            // 用户可能用 rustup 装在非默认位置（CARGO_HOME / RUSTUP_HOME 改过）。
            try await services.paths.refresh()
            versions = await services.rust.installedVersions(customDirectories: customDirectories + services.paths.allPath)
            if !versions.contains(where: { $0.id == selectedID }) { selectedID = versions.first?.id }
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "rust", directory: $0.directory)) })
            pruneEnvLink()
        } catch {
            state.message = error.localizedDescription
        }
        // brew 查不到（没装、或公式被 tap 挡了）不该把上面的扫描结果一起判成失败。
        // 丢后台慢慢填，别拖住 refresh 返回（同 GoViewModel / NodeViewModel）。
        Task {
            do { formulae = try await Brew.formulae("rust") }
            catch { state.message = error.localizedDescription }
        }
        objectWillChange.send()
    }

    func refreshVersionManager(_ source: String, force: Bool = false) async {
        switch source {
        case "Static": await loadStatic(force: force)
        case "MacPorts": await loadPortItems(force: force)
        default: await refresh()
        }
    }

    // MARK: - MacPorts 清单（加载与装/卸在 PortListHost 协议扩展里）

    @Published var portItems: [PortItem] = []
    @Published var portLoading = false
    var portApp: String { "rust" }

    // MARK: - PATH

    // 四路来源同一个 kind —— env/rust 软链全局只有一个，启用新版本自动顶掉旧的，
    // 这就是「当前 rustc 版本」的语义。directory 传 Rust 根，
    // PathService.managedPaths 自动补它下面的 bin（rustc / cargo 都齐）。
    func togglePath(_ version: RustVersion) {
        state.run {
            try self.services.paths.toggle(kind: "rust", directory: version.directory)
            try await self.services.paths.refresh(force: true)
            self.pathMembership = Dictionary(uniqueKeysWithValues: self.versions.map { ($0.id, self.services.paths.membership(kind: "rust", directory: $0.directory)) })
            self.state.message = String(format: L(self.services.paths.membership(kind: "rust", directory: version.directory) == .app ? "message.pathEnabledFor" : "message.pathDisabledFor"), "Rust \(version.version)")
        }
    }

    // 版本被删掉（brew uninstall rust / rustup toolchain uninstall，都是我们不知道的时刻发生的）
    // 之后，env/rust 软链变死链 —— PATH 里那条路径还在，但 rustc 已经不在了，敲什么都 not found。
    // 刷新时清掉。死链的目标目录已经没了，removeLinks 只做路径字符串比较，照样删得掉。
    private func pruneEnvLink() {
        let fm = FileManager.default
        let link = services.paths.envDirectory.appendingPathComponent("rust")
        guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) else { return }
        let target = URL(fileURLWithPath: destination, relativeTo: link).standardizedFileURL
        guard !fm.isExecutableFile(atPath: target.appendingPathComponent("bin/rustc").path) else { return }
        try? services.paths.removeLinks(pointingInside: target)
    }

    // MARK: - Static

    func loadStatic(force: Bool = false) async {
        guard !staticLoading else { return }
        staticLoading = true
        defer { staticLoading = false }
        staticVersions = services.catalog("rust").cached()
        do {
            staticVersions = try await services.catalog("rust").fetch(customEndpoint: state.catalogURL, force: force)
        } catch {
            if !error.isCancelled { state.message = error.localizedDescription }
        }
    }

    // 装 / 卸不走 catalog：官方包的二进制不在标准 bin/ 下，得跑包内的 install.sh 重排布局，
    // StaticCatalogService 那套「二进制往上退两级」的定位法在这儿不成立（见 RustService）。
    func installStatic(_ version: StaticVersion) {
        state.runStreaming(String(format: L("message.installingFor"), "Rust \(version.version)")) { report, attach in
            try await self.services.rust.install(version, report: report, onStart: attach)
            await self.services.rust.clearQuarantine(version)
            self.staticVersions = try await self.services.catalog("rust").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func uninstallStatic(_ version: StaticVersion) {
        state.runStreaming(String(format: L("message.uninstallingFor"), "Rust \(version.version)")) { _, _ in
            try self.services.rust.uninstall(version)
            self.staticVersions = try await self.services.catalog("rust").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func brewAction(_ action: String, formula: String) {
        state.runStreaming(taskTitle(action, formula)) { report, attach in
            try await Brew.run(action, formula: formula, report: report, onStart: attach)
            await self.refresh()
        }
    }

    // MARK: - rustup

    // 进版本管理页时现问文件系统 / 命令 —— 用户可能在别处刚装好，装没装要现查。
    // 顺手把安装路径也缓存下来：环境工具页的面板要显示，而 cargoHome() 要跑登录 shell
    // 问 CARGO_HOME，不能让界面每次渲染都跑一遍。
    func checkRustup() {
        Task {
            let installed = await services.rust.rustupInstalled()
            rustupInstalled = installed
            // 三元表达式里挂 await 在老编译器上不稳，拆开写。
            rustupPath = ""
            if installed { rustupPath = await services.rust.cargoHome().path }
        }
    }

    // rustup 的装卸与设默认：命令代理（流式输出进任务日志浮层），跑完刷新。
    // 它的工具链目录变了，已安装列表要跟着变 —— 同 gvm() 在 GoViewModel 里的做法。
    // action: install / uninstall / alias（设默认：rustup 跑 default）。
    func rustupAction(_ action: String, _ version: String) {
        guard !version.isEmpty else { return }
        let title: String
        let arguments: [String]
        switch action {
        case "alias":
            title = String(format: L("rust.setDefaultTitle"), version)
            arguments = ["default", version]
        case "install":
            title = String(format: L("message.installingFor"), "rustup \(version)")
            arguments = ["toolchain", "install", version]
        default:
            title = String(format: L("message.uninstallingFor"), "rustup \(version)")
            arguments = ["toolchain", "uninstall", version]
        }
        state.runStreaming(title) { report, attach in
            try await self.services.rust.rustup(arguments, onStart: attach, onOutput: report)
            await self.refresh()
        }
    }

    // MARK: - 本体装卸（安装 / 更新 / 卸载 rustup 自己）

    // 装和更新跑同一条命令（官方脚本幂等，重跑即升级），只是任务标题不同。
    // 卸载走 rustup 自带的 self uninstall：它连 ~/.cargo/bin 下的代理程序、~/.rustup 和
    // shell 配置里那两行初始化一起清。清之前先把 env/rust 软链摘掉 —— 它可能指着
    // 工具链目录，留着就是悬空的（同 GoViewModel.uninstallGvm 的顺序）。
    func rustupSelfAction(_ action: String) {
        if action == "uninstall" {
            state.runStreaming(String(format: L("tools.uninstallManager"), "rustup")) { report, attach in
                try? self.services.paths.removeLinks(pointingInside: await self.services.rust.rustupHome())
                try await self.services.rust.uninstallManager(onStart: attach, onOutput: report)
                await self.checkRustup()
                await self.refresh()
            }
        } else {
            let title = String(format: L(action == "install" ? "rust.installingManager" : "rust.updatingManager"), "rustup")
            state.runStreaming(title) { report, attach in
                try await self.services.rust.installManager(onStart: attach, onOutput: report)
                await self.checkRustup()
                await self.refresh()
            }
        }
    }
}
