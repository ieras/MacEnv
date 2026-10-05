import SwiftUI
import AppKit
import Combine
import ServiceManagement

// 模块分组与顺序的唯一来源：设置页的模块开关、侧边栏的条目都按它渲染。
// 要调顺序、换分组，只改这一个数组。
let moduleGroups: [(String, [String])] = [
    ("sidebar.console", ["hosts"]),
    ("sidebar.web", ["nginx"]),
    ("sidebar.database", ["mysql", "mariadb"]),
    ("sidebar.language", ["php", "go"]),
]

func moduleName(_ id: String) -> String { L("module." + id) }

// 全局共享状态：忙碌、提示、外观、语言、快捷启动。
@MainActor
final class AppState: ObservableObject {
    @Published var busy = false
    // 提示可能跟上一条一模一样（同一个开关连点两次），光靠 message 的值没法让视图知道「又来了一条」，
    // 所以每次赋值都换一个 token，浮层靠 token 变化重新计时。
    @Published var message = "" {
        didSet { if !message.isEmpty { messageToken = UUID() } }
    }
    @Published private(set) var messageToken = UUID()
    @Published var theme = ThemeMode.initial {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "macenv.theme") }
    }
    @Published var language = L10n.language {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "macenv.language")
            L10n.language = language
        }
    }
    @Published var catalogURL = UserDefaults.standard.string(forKey: "macenv.catalog.url")
        ?? StaticCatalogService.defaultEndpoint.absoluteString {
        didSet { UserDefaults.standard.set(catalogURL, forKey: "macenv.catalog.url") }
    }
    // 开机启动走 SMAppService（macOS 13 起内置），不用登录项的旧 API。
    @Published var autoLaunch = UserDefaults.standard.bool(forKey: "macenv.autoLaunch") {
        didSet {
            do {
                if autoLaunch { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                UserDefaults.standard.set(autoLaunch, forKey: "macenv.autoLaunch")
            } catch {
                autoLaunch = UserDefaults.standard.bool(forKey: "macenv.autoLaunch")
                message = error.localizedDescription
            }
        }
    }
    @Published var autoStartService = UserDefaults.standard.bool(forKey: "macenv.autoStartService") {
        didSet { UserDefaults.standard.set(autoStartService, forKey: "macenv.autoStartService") }
    }
    @Published var hideOnClose = UserDefaults.standard.object(forKey: "macenv.hideOnClose") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hideOnClose, forKey: "macenv.hideOnClose") }
    }
    @Published var brewSource = BrewSource(rawValue: UserDefaults.standard.string(forKey: "macenv.brewSource") ?? "") ?? .official {
        didSet { UserDefaults.standard.set(brewSource.rawValue, forKey: "macenv.brewSource"); applyEnvironment() }
    }
    @Published var proxyEnabled = UserDefaults.standard.bool(forKey: "macenv.proxy.enabled") {
        didSet { UserDefaults.standard.set(proxyEnabled, forKey: "macenv.proxy.enabled"); applyEnvironment() }
    }
    @Published var proxyHost = UserDefaults.standard.string(forKey: "macenv.proxy.host") ?? "" {
        didSet { UserDefaults.standard.set(proxyHost, forKey: "macenv.proxy.host"); applyEnvironment() }
    }
    @Published var proxyPort = UserDefaults.standard.string(forKey: "macenv.proxy.port") ?? "" {
        didSet { UserDefaults.standard.set(proxyPort, forKey: "macenv.proxy.port"); applyEnvironment() }
    }
    @Published var codeFontSize = UserDefaults.standard.object(forKey: "macenv.code.fontSize") as? Double ?? 14 {
        didSet { UserDefaults.standard.set(codeFontSize, forKey: "macenv.code.fontSize") }
    }
    // 模块开关：控制在侧边栏显示哪些条目。没配过的 key 一律按开启处理。
    @Published var modules = (UserDefaults.standard.dictionary(forKey: "macenv.modules") as? [String: Bool]) ?? [:] {
        didSet { UserDefaults.standard.set(modules, forKey: "macenv.modules") }
    }
    @Published var quickStartTargets: [String] = [] {
        didSet { if let data = try? JSONEncoder().encode(quickStartTargets) { try? data.write(to: quickStartFile, options: .atomic) } }
    }

    private var quickStartFile: URL { macEnvDirectory.appendingPathComponent("quick-start.json") }

    init() {
        if let data = try? Data(contentsOf: quickStartFile), let value = try? JSONDecoder().decode([String].self, from: data) {
            // php-fpm 的启停已全绑 nginx 联动，快捷启动里不再提供勾选，历史勾选一次清掉。
            quickStartTargets = value.filter { !$0.hasPrefix("php:") }
        }
        applyEnvironment()
    }

    // brew 源 + 代理：统一注入给所有子进程（Command.run 会合并这一份）。
    private func applyEnvironment() {
        var environment = brewSource.environment
        if proxyEnabled && !proxyHost.isEmpty {
            let value = proxyPort.isEmpty ? proxyHost : proxyHost + ":" + proxyPort
            for key in ["http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"] { environment[key] = value }
        }
        Command.proxyEnvironment = environment
    }

    func applyTheme() {
        let appearance: NSAppearance? = theme == .automatic ? nil : NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        for window in NSApp.windows { window.appearance = appearance }
    }
}

// 各 ViewModel 的「跑一段异步活」都是同一套：全局 busy 挡住并发，跑完释放，出错弹提示。
// 七个 VM 里一字不差，所以放在 state 上。
extension AppState {
    func run(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await work() }
            catch { message = error.localizedDescription }
        }
    }
}

// 统一服务入口：Nginx / MySQL / MariaDB / PHP-FPM 各出一个条目，跨服务调度全部走它，
// 加新服务不用再改 AppViewModel 的任何 if-else。
// operate 给 UI 用（自管 busy + 提示消息）；perform 给批量启动用（launch 已管 busy，错误由它汇总）。
@MainActor
protocol ServiceManageable {
    var kind: String { get }
    var targets: [LaunchTarget] { get }
    func isRunning(_ versionID: String) -> Bool
    func port(_ versionID: String) -> String?
    func operate(_ action: String, _ versionID: String) async
    func perform(_ action: String, _ versionID: String) async throws
    func stopAll() async
    func membership(_ versionID: String) -> PathMembership
    func togglePath(_ versionID: String)
}

@MainActor
final class AppViewModel: ObservableObject {
    var state = AppState()
    let services = Services()
    // 注册表顺序即首页/侧栏的展示与启动顺序。
    let serviceEntries: [any ServiceManageable]
    let nginxVM: NginxViewModel
    let databaseVM: DatabaseViewModel
    let phpVM: PhpViewModel
    let swooleVM: SwooleViewModel
    let composerVM: ComposerViewModel
    let goVM: GoViewModel
    let hostVM: HostViewModel
    private var cancellables = Set<AnyCancellable>()

    init() {
        nginxVM = NginxViewModel(state: state, services: services)
        databaseVM = DatabaseViewModel(state: state, services: services)
        phpVM = PhpViewModel(state: state, services: services)
        swooleVM = SwooleViewModel(state: state, services: services)
        composerVM = ComposerViewModel(state: state, services: services)
        goVM = GoViewModel(state: state, services: services)
        hostVM = HostViewModel(state: state, services: services)
        serviceEntries = [nginxVM, DatabaseManageable(dbKind: .mysql, vm: databaseVM), DatabaseManageable(dbKind: .mariadb, vm: databaseVM), phpVM]
        services.nginx.onExit = { [weak self] in self?.nginxVM.syncRunning() }
        services.phpFpm.onExit = { [weak self] in self?.phpVM.objectWillChange.send() }
        services.mysql.onExit = { [weak self] in self?.databaseVM.objectWillChange.send() }
        services.mariadb.onExit = { [weak self] in self?.databaseVM.objectWillChange.send() }
        // state 是独立的 ObservableObject，转发后观察本类的视图才会随它重绘。
        state.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    var root: URL { services.root }

    func entry(_ kind: String) -> (any ServiceManageable)? { serviceEntries.first { $0.kind == kind } }

    var launchTargets: [LaunchTarget] { serviceEntries.flatMap { $0.targets } }

    func targetRunning(_ key: String) -> Bool {
        guard let target = launchTargets.first(where: { $0.key == key }) else { return false }
        return entry(target.kind)?.isRunning(target.versionID) ?? false
    }

    func port(_ target: LaunchTarget) -> String { entry(target.kind)?.port(target.versionID) ?? "-" }

    func setQuickStart(_ key: String, enabled: Bool) {
        state.quickStartTargets.removeAll { $0 == key }
        guard enabled, let target = launchTargets.first(where: { $0.key == key }) else { return }
        // 数据库同端口一次只能跑一个，快捷启动也只认一个；PHP-FPM 每版本独立 master，允许勾多个。
        if let kind = DatabaseKind(rawValue: target.kind) {
            state.quickStartTargets.removeAll { (databaseVM.versions[kind] ?? []).map(\.id).contains($0) }
        }
        state.quickStartTargets.append(key)
    }

    func launch(_ keys: [String], stop: Bool = false) {
        guard !state.busy, !keys.isEmpty else {
            if keys.isEmpty { state.message = L("message.quickStartEmpty") }
            return
        }
        state.busy = true
        Task {
            defer { state.busy = false }
            var failures: [String] = []
            var nginxCount = 0
            var nginxFailed = 0
            for key in keys {
                guard let target = launchTargets.first(where: { $0.key == key }), let item = entry(target.kind) else {
                    failures.append(L("message.versionRemoved") + key)
                    continue
                }
                if target.kind == "nginx" { nginxCount += 1 }
                do {
                    if stop { if item.isRunning(target.versionID) { try await item.perform("stop", target.versionID) } }
                    else if !item.isRunning(target.versionID) { try await item.perform("start", target.versionID) }
                } catch {
                    failures.append(target.title + "：" + error.localizedDescription)
                    if target.kind == "nginx" { nginxFailed += 1 }
                }
            }
            state.message = failures.isEmpty ? (stop ? L("message.environmentStopped") : L("message.environmentStarted")) : failures.joined(separator: "\n")
            // nginx 起成功就联动把所有 php-fpm 拉起来（站点离不开 fpm），起失败则不拉；
            // 停 nginx 时联动全停 fpm。侧栏 nginx 开关和电源键都走这里。
            if !stop && nginxCount > 0 && nginxFailed == 0 { await phpVM.startAll() }
            if stop && nginxCount > 0 { await phpVM.stopAll() }
        }
    }

    func stopAll() async {
        for item in serviceEntries { await item.stopAll() }
    }

    func refreshAll() async {
        // Nginx 必须排在 PHP 后面：它 prepare() 时要去 server/php-fpm 下数版本目录，
        // 才能展开出对应的 enable-php-<版本>.conf。反过来跑那一刻目录还不存在，就漏了。
        // PATH 的登录 shell 询问也在这一步完成，后面的 VM 全部命中缓存。
        await phpVM.refresh()
        // 其余互不依赖，并行跑，总时长从"所有之和"变成"最慢的那个"。
        async let swoole: Void = swooleVM.refresh()
        async let composer: Void = composerVM.refresh()
        async let go: Void = goVM.refresh()
        async let nginx: Void = nginxVM.refresh()
        async let mysql: Void = databaseVM.refresh(.mysql)
        async let mariadb: Void = databaseVM.refresh(.mariadb)
        async let hosts: Void = hostVM.refresh()
        _ = await (swoole, composer, go, nginx, mysql, mariadb, hosts)
    }
}
