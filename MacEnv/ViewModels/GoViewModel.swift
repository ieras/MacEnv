import SwiftUI

@MainActor
final class GoViewModel: ObservableObject {
    private let state: AppState
    private let services: Services

    @Published var versions: [GoVersion] = []
    @Published var staticVersions: [StaticVersion] = []
    @Published var staticLoading = false
    // 版本管理里的 Homebrew 一栏：go 和 go@大版本 这一族公式。
    @Published var formulae: [BrewFormulaItem] = []
    @Published var pathMembership: [String: PathMembership] = [:]
    @Published var selectedID: String?
    @Published var customDirectories = UserDefaults.standard.stringArray(forKey: "macenv.go.directories") ?? [] {
        didSet { UserDefaults.standard.set(customDirectories, forKey: "macenv.go.directories") }
    }

    // GVM 三态：nil = 还没检测出来，false = 没装，true = 装了。
    // 界面要靠 nil 显示「检测中」，所以用可选值而不是 Bool。
    @Published var gvmInstalled: Bool?
    @Published var gvmVersions: [GvmVersion] = []
    @Published var gvmLoading = false
    @Published var gvmBusy = false
    @Published var gvmLog = ""
    @Published var gvmSearch = ""

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    var selectedVersion: GoVersion? { versions.first { $0.id == selectedID } ?? versions.first }

    var gvmRootPath: String { services.go.gvmRoot.path }
    // 卸载确认框要报个数：GVM 装了几个 Go 版本，删了就没了。
    var gvmInstalledCount: Int { gvmVersions.filter(\.installed).count }

    func refresh() async {
        do {
            // 先问一次登录 shell 拿真实 PATH，再把 PATH 里的目录也当扫描目标 ——
            // 用户可能用别的工具装了 Go（比如官方 .pkg 装到 /usr/local/go 之外的地方），
            // shell 里 `go version` 有输出、MacEnv 里却一个都看不到就说不通了。
            try await services.paths.refresh()
            versions = try await services.go.installedVersions(customDirectories: customDirectories + services.paths.allPath)
            if !versions.contains(where: { $0.id == selectedID }) { selectedID = versions.first?.id }
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "go", directory: $0.directory)) })
        } catch {
            state.message = error.localizedDescription
        }
        // brew 查不到（没装、或公式被 tap 挡了）不该把上面的扫描结果一起判成失败。
        // 丢后台慢慢填，别拖住 refresh 返回（同 PhpViewModel）。
        Task { if let items = try? await Brew.formulae("go") { formulae = items } }
        objectWillChange.send()
    }

    func refreshVersionManager(_ source: String, force: Bool = false) async {
        if source == "Static" { await loadStatic(force: force) } else { await refresh() }
    }

    func brewAction(_ action: String, formula: String) {
        state.run {
            _ = try await Brew.run(action, formula: formula)
            await self.refresh()
        }
    }

    // Go 的 PATH 入口是 GOROOT 那一级，PATH 上加的是它下面的 bin —— PathService 两种都写。
    func togglePath(_ version: GoVersion) {
        state.run {
            try self.services.paths.toggle(kind: "go", directory: version.directory)
            try await self.services.paths.refresh(force: true)
            self.pathMembership = Dictionary(uniqueKeysWithValues: self.versions.map { ($0.id, self.services.paths.membership(kind: "go", directory: $0.directory)) })
            self.state.message = String(format: L(self.services.paths.membership(kind: "go", directory: version.directory) == .app ? "message.pathEnabledFor" : "message.pathDisabledFor"), "Go \(version.version)")
        }
    }

    func loadStatic(force: Bool = false) async {
        guard !staticLoading else { return }
        staticLoading = true
        defer { staticLoading = false }
        staticVersions = services.catalog("golang").cached()
        do {
            staticVersions = try await services.catalog("golang").fetch(customEndpoint: state.catalogURL, force: force)
        } catch {
            if !error.isCancelled { state.message = error.localizedDescription }
        }
    }

    func installStatic(_ version: StaticVersion) {
        state.run {
            try await self.services.catalog("golang").install(version)
            try await self.services.go.clearQuarantine(version)
            self.staticVersions = try await self.services.catalog("golang").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
            self.state.message = "Go \(version.version) " + L("message.installed")
        }
    }

    func uninstallStatic(_ version: StaticVersion) {
        state.run {
            try self.services.catalog("golang").uninstall(version)
            self.staticVersions = try await self.services.catalog("golang").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
            self.state.message = "Go \(version.version) " + L("message.uninstalled")
        }
    }

    // MARK: - GVM

    func checkGvm() {
        gvmInstalled = services.go.gvmInstalled
        if gvmInstalled == true { Task { await loadGvmVersions() } }
    }

    func loadGvmVersions() async {
        guard !gvmLoading else { return }
        gvmLoading = true
        defer { gvmLoading = false }
        do {
            gvmVersions = try await services.go.gvmVersions()
            gvmInstalled = true
        } catch {
            // 装在但命令跑挂了（比如 gvm 版本太老没有 listall），别把整个面板判成没装。
            gvmInstalled = services.go.gvmInstalled
            state.message = error.localizedDescription
        }
    }

    func installGvm() {
        runGvm {
            try await self.services.go.installGvm { self.appendLog($0) }
            self.gvmInstalled = self.services.go.gvmInstalled
            self.state.message = L("message.gvmInstalled")
            await self.loadGvmVersions()
            await self.refresh()
        }
    }

    // 卸载 GVM 本体。顺序不能反：先摘软链（否则 PATH 里留一条指向已删目录的路径），
    // 再删目录，最后清 shell 配置里的 gvm 行 —— 那行 source 指向一个不存在的文件，留着只会报错。
    func uninstallGvm() {
        state.run {
            try self.services.paths.removeLinks(pointingInside: self.services.go.gvmRoot)
            try self.services.go.uninstallGvm()
            try self.services.paths.removeLines(containing: "gvm", from: self.services.go.profileFiles)
            self.gvmInstalled = self.services.go.gvmInstalled
            self.gvmVersions = []
            self.gvmSearch = ""
            await self.refresh()
            self.state.message = L("message.gvmUninstalled")
        }
    }

    func gvm(_ action: GvmAction, version: GvmVersion) {
        runGvm {
            try await self.services.go.gvm(action, version: version) { self.appendLog($0) }
            await self.loadGvmVersions()
            // gvm 装/卸的是真版本目录，已安装列表要跟着变。
            await self.refresh()
            switch action {
            case .install: self.state.message = version.name + " " + L("message.installed")
            case .uninstall: self.state.message = version.name + " " + L("message.uninstalled")
            case .useDefault: self.state.message = String(format: L("message.gvmDefaultSet"), version.version)
            }
        }
    }

    func cancelGvm() {
        services.go.cancelGvm()
        gvmBusy = false
        appendLog("\n" + L("message.gvmCancelled") + "\n")
    }

    private func appendLog(_ text: String) {
        gvmLog += text
        // 只留最后 20000 字：gvm install -B 的输出能刷出几百行，全存着没意义还拖慢界面。
        if gvmLog.count > 20000 { gvmLog = String(gvmLog.suffix(20000)) }
    }

    // GVM 的任务不能走 state.busy：它一跑就是好几分钟，
    // 把全局 busy 点亮会让侧栏所有开关全灰，那是误导 —— 起停服务跟装 Go 没关系。
    private func runGvm(_ work: @escaping () async throws -> Void) {
        guard !gvmBusy else { return }
        gvmBusy = true
        gvmLog = ""
        Task {
            defer { gvmBusy = false }
            do { try await work() }
            catch { state.message = error.localizedDescription }
        }
    }
}
