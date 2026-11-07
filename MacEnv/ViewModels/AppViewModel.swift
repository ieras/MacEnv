import SwiftUI
import AppKit
import Combine
import ServiceManagement

let moduleGroups: [(String, [String])] = [
    ("sidebar.web", ["hosts", "nginx"]),
    ("sidebar.database", ["mysql", "mariadb", "postgresql", "clickhouse", "qdrant", "neo4j"]),
    ("sidebar.cache", ["redis", "rabbitmq"]),
    ("sidebar.governance", ["consul", "etcd"]),
    ("sidebar.language", ["php", "go", "java", "python", "node", "rust", "erlang"]),
]

let consoleModules = ["tools"]

func moduleName(_ id: String) -> String { L("module." + id) }

struct TaskProgress {
    let id = UUID()
    let title: String
    let packageDirectory: String?
    var log = ""
    var running = true
    var process: Process?
}

@MainActor
final class AppState: ObservableObject {
    @Published var busy = false
    @Published var task: TaskProgress?
    private var streamingTask: Task<Void, Never>?

    var taskRunning: Bool { task?.running == true }
    var installBusy: Bool { busy || taskRunning }
    var runningTaskTitle: String? { task?.running == true ? task?.title : nil }
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
    @Published var modules = (UserDefaults.standard.dictionary(forKey: "macenv.modules") as? [String: Bool]) ?? [:] {
        didSet { UserDefaults.standard.set(modules, forKey: "macenv.modules") }
    }
    @Published var quickStartTargets: [String] = [] {
        didSet { if let data = try? JSONEncoder().encode(quickStartTargets) { try? data.write(to: quickStartFile, options: .atomic) } }
    }

    private var quickStartFile: URL { macEnvDirectory.appendingPathComponent("quick-start.json") }

    var pruneQuickStart: (() -> Void)?

    init() {
        if let data = try? Data(contentsOf: quickStartFile), let value = try? JSONDecoder().decode([String].self, from: data) {
            quickStartTargets = value.filter { !$0.hasPrefix("php:") }
        }
        applyEnvironment()
    }

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

    func runStreaming(_ title: String, packageDirectory: URL? = nil,
                      _ work: @escaping (_ report: @escaping (String) -> Void, _ attach: @escaping (Process) -> Void) async throws -> Void) {
        guard !busy, task == nil else {
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

    func isChanging(_ directory: URL) -> Bool {
        taskRunning && task?.packageDirectory == directory.resolvingSymlinksInPath().path
    }

    func cancelTask() {
        streamingTask?.cancel()
        appendTaskLog("\n" + L("message.taskCancelled") + "\n")
    }

    func dismissTask() { if !taskRunning { task = nil } }

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

@MainActor
protocol ServiceManageable {
    var kind: String { get }
    var targets: [LaunchTarget] { get }
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
    var singleInstance: Bool { true }

    func preferredTarget(quickStart: [String]) -> LaunchTarget? {
        targets.first { quickStart.contains($0.key) } ?? targets.first
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    var state = AppState()
    let services = Services()
    let serviceEntries: [any ServiceManageable]
    let nginxVM: NginxViewModel
    let databaseVM: DatabaseViewModel
    let redisVM: RedisViewModel
    let postgresVM: PostgresViewModel
    let clickhouseVM: ClickHouseViewModel
    let qdrantVM: QdrantViewModel
    let neo4jVM: Neo4jViewModel
    let rabbitmqVM: RabbitMQViewModel
    let consulVM: ConsulViewModel
    let etcdVM: EtcdViewModel
    let certVM: MkCertViewModel
    let phpVM: PhpViewModel
    let swooleVM: SwooleViewModel
    let composerVM: ComposerViewModel
    let goVM: GoViewModel
    let javaVM: JavaViewModel
    let pythonVM: PythonViewModel
    let nodeVM: NodeViewModel
    let rustVM: RustViewModel
    let erlangVM: ErlangViewModel
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
        neo4jVM = Neo4jViewModel(state: state, services: services)
        rabbitmqVM = RabbitMQViewModel(state: state, services: services)
        consulVM = ConsulViewModel(state: state, services: services)
        etcdVM = EtcdViewModel(state: state, services: services)
        certVM = MkCertViewModel(state: state, services: services)
        phpVM = PhpViewModel(state: state, services: services)
        swooleVM = SwooleViewModel(state: state, services: services)
        composerVM = ComposerViewModel(state: state, services: services)
        goVM = GoViewModel(state: state, services: services)
        javaVM = JavaViewModel(state: state, services: services)
        pythonVM = PythonViewModel(state: state, services: services)
        nodeVM = NodeViewModel(state: state, services: services)
        rustVM = RustViewModel(state: state, services: services)
        erlangVM = ErlangViewModel(state: state, services: services)
        mavenVM = MavenViewModel(state: state, services: services)
        gradleVM = GradleViewModel(state: state, services: services)
        hostVM = HostViewModel(state: state, services: services)
        toolsVM = ToolsViewModel(state: state, services: services)
        serviceEntries = [nginxVM, DatabaseManageable(dbKind: .mysql, vm: databaseVM), DatabaseManageable(dbKind: .mariadb, vm: databaseVM), phpVM, redisVM, postgresVM, clickhouseVM, qdrantVM, neo4jVM, rabbitmqVM, consulVM, etcdVM]
        toolsVM.onRefreshAll = { [weak self] in await self?.refreshAll() }
        services.nginx.onExit = { [weak self] in self?.nginxVM.syncRunning() }
        services.phpFpm.onExit = { [weak self] in self?.phpVM.objectWillChange.send() }
        services.mysql.onExit = { [weak self] in self?.databaseVM.objectWillChange.send() }
        services.mariadb.onExit = { [weak self] in self?.databaseVM.objectWillChange.send() }
        services.redis.onExit = { [weak self] in self?.redisVM.objectWillChange.send() }
        services.postgres.onExit = { [weak self] in self?.postgresVM.objectWillChange.send() }
        services.qdrant.onExit = { [weak self] in self?.qdrantVM.objectWillChange.send() }
        services.neo4j.onExit = { [weak self] in self?.neo4jVM.objectWillChange.send() }
        services.rabbitmq.onExit = { [weak self] in self?.rabbitmqVM.objectWillChange.send() }
        services.clickhouse.onExit = { [weak self] in self?.clickhouseVM.objectWillChange.send() }
        services.consul.onExit = { [weak self] in self?.consulVM.objectWillChange.send() }
        services.etcd.onExit = { [weak self] in self?.etcdVM.objectWillChange.send() }
        state.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        javaVM.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        pythonVM.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        nodeVM.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        rustVM.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        state.pruneQuickStart = { [weak self] in
            guard let self else { return }
            let valid = Set(self.launchTargets.map(\.key))
            self.state.quickStartTargets.removeAll { !valid.contains($0) }
        }
    }

    var root: URL { services.root }

    func entry(_ kind: String) -> (any ServiceManageable)? { serviceEntries.first { $0.kind == kind } }

    var launchTargets: [LaunchTarget] { serviceEntries.flatMap { $0.targets } }

    var quickStartLaunchTargets: [LaunchTarget] {
        launchTargets.filter { state.quickStartTargets.contains($0.key) }
    }

    func targetRunning(_ key: String) -> Bool {
        guard let target = launchTargets.first(where: { $0.key == key }) else { return false }
        return entry(target.kind)?.isRunning(target.versionID) ?? false
    }

    func port(_ target: LaunchTarget) -> String { entry(target.kind)?.port(target.versionID) ?? "-" }

    func setQuickStart(_ key: String, enabled: Bool) {
        state.quickStartTargets.removeAll { $0 == key }
        guard enabled, let target = launchTargets.first(where: { $0.key == key }) else { return }
        if let entry = entry(target.kind), entry.singleInstance {
            state.quickStartTargets.removeAll { entry.targets.map(\.key).contains($0) }
        }
        state.quickStartTargets.append(key)
    }

    func kindRunning(_ kind: String) -> Bool {
        if kind == "nginx" { return nginxVM.isRunning }
        if kind == "php" { return phpVM.fpmRunningAny }
        if let dbKind = DatabaseKind(rawValue: kind) { return databaseVM.running(dbKind) }
        return launchTargets.contains { $0.kind == kind && targetRunning($0.key) }
    }

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
            if !stop && nginxCount > 0 && nginxFailed == 0 { await phpVM.startAll() }
            if stop && nginxCount > 0 { await phpVM.stopAll() }
        }
    }

    func stopAll() async {
        for item in serviceEntries { await item.stopAll() }
    }

    func refreshAll() async {
        await phpVM.refresh()
        async let swoole: Void = swooleVM.refresh()
        async let composer: Void = composerVM.refresh()
        async let go: Void = goVM.refresh()
        async let java: Void = javaVM.refresh()
        async let python: Void = pythonVM.refresh()
        async let node: Void = nodeVM.refresh()
        async let rust: Void = rustVM.refresh()
        async let erlang: Void = erlangVM.refresh()
        async let maven: Void = mavenVM.refresh()
        async let gradle: Void = gradleVM.refresh()
        async let nginx: Void = nginxVM.refresh()
        async let mysql: Void = databaseVM.refresh(.mysql)
        async let mariadb: Void = databaseVM.refresh(.mariadb)
        async let redis: Void = redisVM.refresh()
        async let postgres: Void = postgresVM.refresh()
        async let clickhouse: Void = clickhouseVM.refresh()
        async let qdrant: Void = qdrantVM.refresh()
        async let neo4j: Void = neo4jVM.refresh()
        async let rabbitmq: Void = rabbitmqVM.refresh()
        async let consul: Void = consulVM.refresh()
        async let etcd: Void = etcdVM.refresh()
        async let cert: Void = certVM.refresh()
        async let hosts: Void = hostVM.refresh()
        _ = await (swoole, composer, go, java, python, node, rust, erlang, maven, gradle, nginx, mysql, mariadb, redis, postgres, clickhouse, qdrant, neo4j, rabbitmq, consul, etcd, cert, hosts)
    }
}
