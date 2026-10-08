import SwiftUI
import AppKit
import Combine
import ServiceManagement

// 模块分组与顺序的唯一来源：设置页的模块开关、侧边栏的条目都按它渲染。
// 要调顺序、换分组，只改这一个数组。
//
// 没有 "sidebar.console" 这一组：控制台只剩快捷启动和环境工具，而它在侧边栏里是硬编码画的
// （设置页不把它当模块开关）。留一个空组会在设置页画出「标题 + 点了没反应的开关 + 空白网格」。
let moduleGroups: [(String, [String])] = [
    ("sidebar.web", ["hosts", "nginx"]),
    ("sidebar.database", ["mysql", "mariadb", "postgresql", "clickhouse", "qdrant"]),
    ("sidebar.cache", ["redis"]),
    // 服务治理：服务发现 / 配置中心这一类组件，不是数据库也不是缓存。
    // 顺序跟 FlyEnv 的 serviceGovernance 组一致（consul 在 etcd 前面）。
    ("sidebar.governance", ["consul", "etcd"]),
    ("sidebar.language", ["php", "go", "java", "python"]),
]

// 控制台组的内容。它跟 moduleGroups 一样要同时喂给侧栏和设置页，
// 只是因为它那组的标题是手画的，不能塞进上面那个数组，所以单列一份。
let consoleModules = ["tools"]

func moduleName(_ id: String) -> String { L("module." + id) }

// 长任务（装 / 卸 / 下载 / 解包）的进度。日志浮层显示它；跑完留在原地等用户关 ——
// 失败原因就在最后几行，自动关掉等于让用户没法看。
struct TaskProgress {
    let id = UUID()
    let title: String
    let packageDirectory: String?
    var log = ""
    var running = true
    // 普通命令持有 Process；提权命令由 Command 按独立进程组清理。
    var process: Process?
}

// 全局共享状态：忙碌、提示、外观、语言、快捷启动。
@MainActor
final class AppState: ObservableObject {
    @Published var busy = false
    @Published var task: TaskProgress?
    private var streamingTask: Task<Void, Never>?

    // 服务启停看 busy；装 / 卸 / 下载是长任务（task），两码事。安装按钮、版本页刷新按钮
    // 要看 installBusy —— 不然安装跑着按钮还能再点，第二次点击被 runStreaming 静默丢掉。
    var taskRunning: Bool { task?.running == true }
    var installBusy: Bool { busy || taskRunning }
    var runningTaskTitle: String? { task?.running == true ? task?.title : nil }
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

    // 快捷启动僵尸 key 的清洗钩子：任何写操作（run / runStreaming）跑完调一次。
    // 实现由 AppViewModel 注入 —— launchTargets 在它那儿，state 不该知道服务。
    var pruneQuickStart: (() -> Void)?

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
            catch { if !error.isCancelled { message = error.localizedDescription } }
            pruneQuickStart?()
        }
    }

    // 长任务（装 / 卸 / 下载 / 解包）：**不走全局 busy** —— 装一个 PHP 要几分钟，点亮 busy
    // 会让侧栏所有服务开关全灰，那是误导（起停服务和装软件没关系）。单独开一条任务日志，
    // 右下角浮层实时刷。
    //
    // report 追加日志；attach 把子进程交上来，取消按钮才能真杀掉它。
    func runStreaming(_ title: String, packageDirectory: URL? = nil,
                      _ work: @escaping (_ report: @escaping (String) -> Void, _ attach: @escaping (Process) -> Void) async throws -> Void) {
        guard !busy, task == nil else {
            // 同一时间只跑一个长任务。 silently 丢掉点击用户会以为「点了没反应」，明说。
            message = L("message.taskInProgress")
            return
        }
        task = TaskProgress(title: title, packageDirectory: packageDirectory?.resolvingSymlinksInPath().path)
        let id = task?.id
        streamingTask = Task {
            do {
                try await work({
                    guard self.task?.id == id, !Task.isCancelled else { return }
                    self.appendTaskLog($0)
                }, {
                    guard self.task?.id == id else { return }
                    self.task?.process = $0
                })
            } catch {
                if !error.isCancelled, self.task?.id == id { self.appendTaskLog("\n" + error.localizedDescription + "\n") }
            }
            guard self.task?.id == id else { return }
            self.task?.running = false
            self.task?.process = nil
            self.streamingTask = nil
            self.pruneQuickStart?()
        }
    }

    // 安装只锁正在替换的包，其他版本与服务仍可使用。
    func isChanging(_ directory: URL) -> Bool {
        taskRunning && task?.packageDirectory == directory.resolvingSymlinksInPath().path
    }

    func cancelTask() {
        streamingTask?.cancel()
        appendTaskLog("\n" + L("message.taskCancelled") + "\n")
    }

    func dismissTask() { if !taskRunning { task = nil } }

    // brew / curl 的进度条用 \r 原地刷新同一行，直接拼进日志会糊成一长条，
    // 所以 \r 处理成「丢掉当前行重写」，\n 才是真的换行。只留最后 20000 字。
    private func appendTaskLog(_ text: String) {
        guard var progress = task else { return }
        var lines = progress.log.components(separatedBy: "\n")
        var line = lines.removeLast()
        for character in text {
            switch character {
            case "\n": lines.append(line); line = ""
            case "\r": line = ""
            default: line.append(character)
            }
        }
        lines.append(line)
        progress.log = lines.joined(separator: "\n")
        if progress.log.count > 20000 { progress.log = String(progress.log.suffix(20000)) }
        task = progress
    }
}

// 统一服务入口：Nginx / MySQL / MariaDB / PHP-FPM 各出一个条目，跨服务调度全部走它，
// 加新服务不用再改 AppViewModel 的任何 if-else。
// operate 给 UI 用（自管 busy + 提示消息）；perform 给批量启动用（launch 已管 busy，错误由它汇总）。
@MainActor
protocol ServiceManageable {
    var kind: String { get }
    var targets: [LaunchTarget] { get }
    // 端口固定、一次只能跑一个版本的服务为 true；nginx / php 每版本独立端口（进程），允许多个。
    // 快捷启动的互斥和侧栏开关都按它走 —— 加新服务默认就有，不用再记着接线。
    var singleInstance: Bool { get }
    func isRunning(_ versionID: String) -> Bool
    func port(_ versionID: String) -> String?
    func operate(_ action: String, _ versionID: String) async
    func perform(_ action: String, _ versionID: String) async throws
    func stopAll() async
    func membership(_ versionID: String) -> PathMembership
    func togglePath(_ versionID: String)
}

@MainActor
extension ServiceManageable {
    // 数据库 / redis / postgresql / clickhouse / qdrant / consul / etcd 全是端口固定一实例。
    var singleInstance: Bool { true }

    // 侧栏开关用：优先起勾了快捷启动的版本，没配就用列表第一个（各服务扫描结果已按版本从大到小排）。
    func preferredTarget(quickStart: [String]) -> LaunchTarget? {
        targets.first { quickStart.contains($0.key) } ?? targets.first
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    var state = AppState()
    let services = Services()
    // 注册表顺序即首页/侧栏的展示与启动顺序。
    let serviceEntries: [any ServiceManageable]
    let nginxVM: NginxViewModel
    let databaseVM: DatabaseViewModel
    let redisVM: RedisViewModel
    let postgresVM: PostgresViewModel
    let clickhouseVM: ClickHouseViewModel
    let qdrantVM: QdrantViewModel
    let consulVM: ConsulViewModel
    let etcdVM: EtcdViewModel
    let certVM: MkCertViewModel
    let phpVM: PhpViewModel
    let swooleVM: SwooleViewModel
    let composerVM: ComposerViewModel
    let goVM: GoViewModel
    let javaVM: JavaViewModel
    let pythonVM: PythonViewModel
    let mavenVM: MavenViewModel
    let gradleVM: GradleViewModel
    let hostVM: HostViewModel
    let toolsVM: ToolsViewModel
    private var cancellables = Set<AnyCancellable>()

    init() {
        nginxVM = NginxViewModel(state: state, services: services)
        databaseVM = DatabaseViewModel(state: state, services: services)
        redisVM = RedisViewModel(state: state, services: services)
        postgresVM = PostgresViewModel(state: state, services: services)
        clickhouseVM = ClickHouseViewModel(state: state, services: services)
        qdrantVM = QdrantViewModel(state: state, services: services)
        consulVM = ConsulViewModel(state: state, services: services)
        etcdVM = EtcdViewModel(state: state, services: services)
        certVM = MkCertViewModel(state: state, services: services)
        phpVM = PhpViewModel(state: state, services: services)
        swooleVM = SwooleViewModel(state: state, services: services)
        composerVM = ComposerViewModel(state: state, services: services)
        goVM = GoViewModel(state: state, services: services)
        javaVM = JavaViewModel(state: state, services: services)
        pythonVM = PythonViewModel(state: state, services: services)
        mavenVM = MavenViewModel(state: state, services: services)
        gradleVM = GradleViewModel(state: state, services: services)
        hostVM = HostViewModel(state: state, services: services)
        toolsVM = ToolsViewModel(state: state, services: services)
        serviceEntries = [nginxVM, DatabaseManageable(dbKind: .mysql, vm: databaseVM), DatabaseManageable(dbKind: .mariadb, vm: databaseVM), phpVM, redisVM, postgresVM, clickhouseVM, qdrantVM, consulVM, etcdVM]
        // 卸掉 Homebrew 会把 nginx / php / mysql / redis / go 一起带走，工具页看不到那些 VM，
        // 所以由这里注入一个「刷全部」的回调 —— 反过来让工具页依赖 AppViewModel 是转圈依赖。
        toolsVM.onRefreshAll = { [weak self] in await self?.refreshAll() }
        services.nginx.onExit = { [weak self] in self?.nginxVM.syncRunning() }
        services.phpFpm.onExit = { [weak self] in self?.phpVM.objectWillChange.send() }
        services.mysql.onExit = { [weak self] in self?.databaseVM.objectWillChange.send() }
        services.mariadb.onExit = { [weak self] in self?.databaseVM.objectWillChange.send() }
        services.redis.onExit = { [weak self] in self?.redisVM.objectWillChange.send() }
        services.postgres.onExit = { [weak self] in self?.postgresVM.objectWillChange.send() }
        services.qdrant.onExit = { [weak self] in self?.qdrantVM.objectWillChange.send() }
        services.clickhouse.onExit = { [weak self] in self?.clickhouseVM.objectWillChange.send() }
        services.consul.onExit = { [weak self] in self?.consulVM.objectWillChange.send() }
        services.etcd.onExit = { [weak self] in self?.etcdVM.objectWillChange.send() }
        // state 是独立的 ObservableObject，转发后观察本类的视图才会随它重绘。
        state.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        // 任何装/卸跑完都清洗一遍快捷启动：指向已不存在版本的 key 当场删掉，
        // 不然 quick-start.json 里会攒僵尸 key（计数对不上列表就是它闹的）。
        // 启动时 refreshAll 已把全部版本扫完，不必担心「还没扫到就误删」。
        state.pruneQuickStart = { [weak self] in
            guard let self else { return }
            let valid = Set(self.launchTargets.map(\.key))
            self.state.quickStartTargets.removeAll { !valid.contains($0) }
        }
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
        // 端口固定的服务一次只能跑一个版本，快捷启动也只认一个；
        // nginx / php 每版本独立端口（进程），允许勾多个。
        if let entry = entry(target.kind), entry.singleInstance {
            state.quickStartTargets.removeAll { entry.targets.map(\.key).contains($0) }
        }
        state.quickStartTargets.append(key)
    }

    // 一个 kind 的聚合运行态：nginx / php / 数据库各有自己的判定，其余按「任一版本在跑」。
    // 侧栏开关的 get 与托盘开关共用这里，保证两边显示一致。
    func kindRunning(_ kind: String) -> Bool {
        if kind == "nginx" { return nginxVM.isRunning }
        if kind == "php" { return phpVM.fpmRunningAny }
        if let dbKind = DatabaseKind(rawValue: kind) { return databaseVM.running(dbKind) }
        return launchTargets.contains { $0.kind == kind && targetRunning($0.key) }
    }

    // 一个 kind 的整档启停，逻辑与侧栏 ServiceSwitch 的各 case 完全一致（托盘复用同一份）。
    // 关 = 停掉该 kind 全部版本；开 = 优先起勾了快捷启动的版本，没配就起版本号最大的（redis 家族用首版，versions 已按版本号降序）。
    func toggleKind(_ kind: String) {
        guard !state.busy else { return }
        if kind == "php" {
            state.run { if self.phpVM.fpmRunningAny { await self.phpVM.stopAll() } else { await self.phpVM.startAll() } }
            return
        }
        if kindRunning(kind) {
            launch(launchTargets.filter { $0.kind == kind }.map(\.key), stop: true)
            return
        }
        if kind == "nginx" {
            let version = nginxVM.versions.first { state.quickStartTargets.contains("nginx:" + $0.id) }
                ?? nginxVM.versions.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
            if let version { nginxVM.selectedID = version.id; launch(["nginx:" + version.id]) }
        } else if let dbKind = DatabaseKind(rawValue: kind) {
            let all = databaseVM.versions[dbKind] ?? []
            let version = all.first { state.quickStartTargets.contains($0.id) }
                ?? all.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
            if let version { databaseVM.selected[dbKind] = version.id; launch([version.id]) }
        } else {
            let target = launchTargets.first { $0.kind == kind && state.quickStartTargets.contains($0.key) }
                ?? launchTargets.first { $0.kind == kind }
            if let target { launch([target.key]) }
        }
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
        async let java: Void = javaVM.refresh()
        async let python: Void = pythonVM.refresh()
        async let maven: Void = mavenVM.refresh()
        async let gradle: Void = gradleVM.refresh()
        async let nginx: Void = nginxVM.refresh()
        async let mysql: Void = databaseVM.refresh(.mysql)
        async let mariadb: Void = databaseVM.refresh(.mariadb)
        async let redis: Void = redisVM.refresh()
        async let postgres: Void = postgresVM.refresh()
        async let clickhouse: Void = clickhouseVM.refresh()
        async let qdrant: Void = qdrantVM.refresh()
        async let consul: Void = consulVM.refresh()
        async let etcd: Void = etcdVM.refresh()
        async let cert: Void = certVM.refresh()
        async let hosts: Void = hostVM.refresh()
        _ = await (swoole, composer, go, java, python, maven, gradle, nginx, mysql, mariadb, redis, postgres, clickhouse, qdrant, consul, etcd, cert, hosts)
    }
}
