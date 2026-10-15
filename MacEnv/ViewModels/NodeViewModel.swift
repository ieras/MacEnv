import SwiftUI

@MainActor
final class NodeViewModel: ObservableObject, PortListHost {
    let state: AppState
    let services: Services

    @Published var versions: [NodeVersion] = []
    @Published var staticVersions: [StaticVersion] = []
    @Published var staticLoading = false
    // 版本管理里的 Homebrew 一栏：node 和 node@20 / node@22 这一族公式。
    @Published var formulae: [BrewFormulaItem] = []
    @Published var pathMembership: [String: PathMembership] = [:]
    @Published var selectedID: String?
    @Published var customDirectories = UserDefaults.standard.stringArray(forKey: "macenv.node.directories") ?? [] {
        didSet { UserDefaults.standard.set(customDirectories, forKey: "macenv.node.directories") }
    }

    // nvm / fnm 装没装（nil = 还没检测出来，界面不显示它们的安装入口）。版本管理页现问。
    @Published var nvmInstalled: Bool?
    @Published var fnmInstalled: Bool?
    // 安装路径（环境工具页的面板要显示，点开就是 Finder）。跟装没装一起检测时顺手缓存 ——
    // 不能每次渲染都去问一遍登录 shell。
    @Published var nvmRootPath = ""
    @Published var fnmDirectoryPath = ""

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    var selectedVersion: NodeVersion? { versions.first { $0.id == selectedID } ?? versions.first }

    func refresh() async {
        do {
            // 先问一次登录 shell 拿真实 PATH，再把 PATH 里的目录也当扫描目标 ——
            // 用户可能用 nvm / fnm / 官方 pkg 装了 node 装在非默认位置。
            try await services.paths.refresh()
            versions = await services.node.installedVersions(customDirectories: customDirectories + services.paths.allPath)
            if !versions.contains(where: { $0.id == selectedID }) { selectedID = versions.first?.id }
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "node", directory: $0.directory)) })
            pruneEnvLink()
        } catch {
            state.message = error.localizedDescription
        }
        // brew 查不到（没装、或公式被 tap 挡了）不该把上面的扫描结果一起判成失败。
        // 丢后台慢慢填，别拖住 refresh 返回（同 GoViewModel）。
        Task {
            do { formulae = try await Brew.formulae("node") }
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
    var portApp: String { "node" }

    // MARK: - PATH

    // 五路来源同一个 kind —— env/node 软链全局只有一个，启用新版本自动顶掉旧的，
    // 这就是「当前 node 版本」的语义。directory 传 Node 根，
    // PathService.managedPaths 自动补它下面的 bin（node/npm/npx 都齐）。
    func togglePath(_ version: NodeVersion) {
        state.run {
            try self.services.paths.toggle(kind: "node", directory: version.directory)
            try await self.services.paths.refresh(force: true)
            self.pathMembership = Dictionary(uniqueKeysWithValues: self.versions.map { ($0.id, self.services.paths.membership(kind: "node", directory: $0.directory)) })
            self.state.message = String(format: L(self.services.paths.membership(kind: "node", directory: version.directory) == .app ? "message.pathEnabledFor" : "message.pathDisabledFor"), "Node \(version.version)")
        }
    }

    // 版本被删掉（brew uninstall node / nvm uninstall，都是我们不知道的时刻发生的）之后，
    // env/node 软链变死链 —— PATH 里那条路径还在，但 node 已经不在了，敲什么都 not found。
    // 刷新时清掉。死链的目标目录已经没了，removeLinks 只做路径字符串比较，照样删得掉。
    private func pruneEnvLink() {
        let fm = FileManager.default
        let link = services.paths.envDirectory.appendingPathComponent("node")
        guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) else { return }
        let target = URL(fileURLWithPath: destination, relativeTo: link).standardizedFileURL
        guard !fm.isExecutableFile(atPath: target.appendingPathComponent("bin/node").path) else { return }
        try? services.paths.removeLinks(pointingInside: target)
    }

    // MARK: - Static

    func loadStatic(force: Bool = false) async {
        guard !staticLoading else { return }
        staticLoading = true
        defer { staticLoading = false }
        staticVersions = services.catalog("node").cached()
        do {
            staticVersions = try await services.catalog("node").fetch(customEndpoint: state.catalogURL, force: force)
        } catch {
            if !error.isCancelled { state.message = error.localizedDescription }
        }
    }

    func installStatic(_ version: StaticVersion) {
        state.runStreaming(String(format: L("message.installingFor"), "Node \(version.version)")) { report, attach in
            try await self.services.catalog("node").install(version, report: report, onStart: attach)
            await self.services.node.clearQuarantine(version)
            self.staticVersions = try await self.services.catalog("node").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func uninstallStatic(_ version: StaticVersion) {
        state.runStreaming(String(format: L("message.uninstallingFor"), "Node \(version.version)")) { _, _ in
            try self.services.catalog("node").uninstall(version)
            self.staticVersions = try await self.services.catalog("node").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func brewAction(_ action: String, formula: String) {
        state.runStreaming(taskTitle(action, formula)) { report, attach in
            try await Brew.run(action, formula: formula, report: report, onStart: attach)
            await self.refresh()
        }
    }

    // MARK: - nvm / fnm

    // 进版本管理页时现问文件系统 / 命令 —— 用户可能在别处刚装好，装没装要现查。
    // 顺手把安装路径也缓存下来：环境工具页的面板（ToolHeader）要显示路径，
    // 而 nvmRoot() 要跑登录 shell 问 NVM_DIR，不能让界面每次渲染都跑一遍。
    func checkManagers() {
        Task {
            let nvmRoot = await services.node.nvmRoot()
            nvmInstalled = FileManager.default.fileExists(atPath: nvmRoot.appendingPathComponent("nvm.sh").path)
            nvmRootPath = (nvmInstalled == true) ? nvmRoot.path : ""
            let fnmDir = await services.node.fnmDirectory()
            fnmInstalled = await services.node.fnmInstalled()
            fnmDirectoryPath = fnmDir?.path ?? ""
        }
    }

    // nvm / fnm 的装卸与设默认：命令代理（zsh 流式输出进任务日志浮层），跑完刷新。
    // 它们的版本目录变了，已安装列表要跟着变 —— 同 gvm() 在 GoViewModel 里的做法。
    // action: install / uninstall / alias（设默认：nvm 跑 alias default，fnm 跑 default）。
    func managerAction(_ manager: String, _ action: String, _ version: String) {
        guard !version.isEmpty else { return }
        let title: String
        let verb: String
        switch action {
        case "alias":
            title = String(format: L("node.setDefaultTitle"), manager, version)
            verb = manager == "nvm" ? "alias default" : "default"
        case "install":
            title = String(format: L("message.installingFor"), "\(manager) \(version)")
            verb = action
        default:
            title = String(format: L("message.uninstallingFor"), "\(manager) \(version)")
            verb = action
        }
        state.runStreaming(title) { report, attach in
            if manager == "nvm" {
                try await self.services.node.nvm(verb, version: version, onStart: attach, onOutput: report)
            } else {
                try await self.services.node.fnm(verb, version: version, onStart: attach, onOutput: report)
            }
            await self.refresh()
        }
    }

    // MARK: - 本体装卸（安装 / 更新 / 卸载 nvm / fnm 自己）

    // 装和更新跑同一条命令（官方脚本幂等，重跑即升级），只是任务标题不同；
    // 卸载是秒级的本地操作（删目录 + 清 rc），走同步短任务不需要流式日志。
    // 卸载顺序不能反：先摘 env 软链（否则 PATH 里留一条指向已删目录的路径），
    // 再删目录，最后清 shell 配置里的初始化行 —— 那行 source 指向不存在的文件，
    // 留着只会报错（同 GoViewModel.uninstallGvm）。
    func managerSelfAction(_ manager: String, _ action: String) {
        if action == "uninstall" {
            state.run {
                let directory: URL? = manager == "nvm" ? await self.services.node.nvmRoot() : await self.services.node.fnmDirectory()
                if let directory { try? self.services.paths.removeLinks(pointingInside: directory) }
                try await self.services.node.uninstallManager(manager)
                _ = try self.services.paths.removeLines(containing: manager, from: self.services.node.profileFiles)
                await self.checkManagers()
                await self.refresh()
            }
        } else {
            let title = String(format: L(action == "install" ? "node.installingManager" : "node.updatingManager"), manager)
            state.runStreaming(title) { report, attach in
                try await self.services.node.installManager(manager, onStart: attach, onOutput: report)
                await self.checkManagers()
                await self.refresh()
            }
        }
    }
}
