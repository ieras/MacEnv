import SwiftUI

@MainActor
final class Neo4jViewModel: ObservableObject {
    let state: AppState
    let services: Services

    @Published var versions: [Neo4jVersion] = []
    @Published var staticVersions: [StaticVersion] = []
    @Published var staticLoading = false
    @Published var pathMembership: [String: PathMembership] = [:]
    @Published var selected = ""
    @Published var configText = ""
    @Published var logText = ""
    // JDK 装卸、换绑定时让 Java 列重算（绑定存在 UserDefaults 里，不是 @Published）。
    @Published private var javaRevision = 0
    @Published var customDirectories: [String] = {
        guard let data = UserDefaults.standard.data(forKey: "macenv.neo4j.directories"),
              let value = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return value
    }() {
        didSet { if let data = try? JSONEncoder().encode(customDirectories) { UserDefaults.standard.set(data, forKey: "macenv.neo4j.directories") } }
    }

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    func selectedVersion() -> Neo4jVersion? { versions.first { $0.id == selected } ?? versions.first }

    func configURL(_ version: Neo4jVersion) -> URL { services.neo4j.configURL(for: version) }
    func dataURL(_ version: Neo4jVersion) -> URL { services.neo4j.dataURL(for: version) }
    func logURL() -> URL? { selectedVersion().map { services.neo4j.logFile(for: $0) } }
    // 三端口（http/https/bolt）里表格只显示用户在意的两个：浏览器走 http、
    // 客户端驱动走 bolt，https 默认关闭、列出来只是噪音（同 ClickHouse 双端口写法）。
    func port(_ version: Neo4jVersion) -> String {
        let ports = services.neo4j.ports(for: version)
        return "\(ports.http) / \(ports.bolt)"
    }
    func httpPort(_ version: Neo4jVersion) -> Int { services.neo4j.ports(for: version).http }
    func running(_ version: Neo4jVersion) -> Bool { services.neo4j.running(version) }

    func refresh() async {
        do {
            try await services.paths.refresh()
            let service = services.neo4j
            // JDK 列表必须先就位：扫 Neo4j 版本要借一个 JAVA_HOME 跑 bin/neo4j version，
            // 自动绑定也要从这份列表里挑。Java 模块刷新同一批目录，这里单独刷一份。
            service.installedJava = await services.java.installedVersions()
            let found = try await service.installedVersions(customDirectories: customDirectories + services.paths.allPath)
            for version in found { try service.prepare(version) }
            service.reconcileBindings(found)
            versions = found
            await service.adopt(found)
            pathMembership = Dictionary(uniqueKeysWithValues: found.map { ($0.id, services.paths.membership(kind: "neo4j", directory: $0.directory)) })
            if !found.contains(where: { $0.id == selected }) { selected = found.first?.id ?? "" }
            javaRevision += 1
        } catch {
            state.message = error.localizedDescription
        }
        objectWillChange.send()
    }

    // MARK: - Java 绑定

    func javaCandidates(_ version: Neo4jVersion) -> [JavaVersion] {
        return services.neo4j.javaCandidates(version.version)
    }

    func selectedJava(_ version: Neo4jVersion) -> String { services.neo4j.binding(for: version) ?? "" }

    func setJava(_ version: Neo4jVersion, _ javaHome: String) {
        guard !running(version) else { state.message = L("message.neo4jJavaWhileRunning"); return }
        services.neo4j.setBinding(version, javaHome)
        javaRevision += 1
    }

    // MARK: - 服务操作

    func operate(_ operation: String, _ version: Neo4jVersion) async {
        guard !state.busy else { return }
        guard !state.isChanging(version.directory) else { state.message = L("message.taskInProgress"); return }
        selected = version.id
        let service = services.neo4j
        if operation == "start", service.runningVersion != nil, !service.running(version) {
            state.message = L("message.databaseAlreadyRunning") + version.version
            return
        }
        state.busy = true
        defer {
            state.busy = false
            objectWillChange.send()
        }
        do {
            if operation != "stop" { try await service.start(version) }
            else { try await service.stop() }
            state.message = "Neo4j " + (operation == "start" ? L("message.started") : L("message.stopped"))
            await refresh()
        } catch {
            state.message = error.localizedDescription
        }
    }

    func togglePath(_ version: Neo4jVersion) {
        state.run { [self] in
            try services.paths.toggle(kind: "neo4j", directory: version.directory)
            try await services.paths.refresh(force: true)
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "neo4j", directory: $0.directory)) })
            let enabled = pathMembership[version.id] == .app
            state.message = String(format: L(enabled ? "message.pathEnabledFor" : "message.pathDisabledFor"), "Neo4j " + version.version)
        }
    }

    // MARK: - 静态包（唯一来源：官方只发社区 tar.gz，brew 只有启动服务的 cask）

    func loadStatic(force: Bool = false) async {
        guard !staticLoading else { return }
        staticLoading = true
        defer { staticLoading = false }
        staticVersions = services.catalog("neo4j").cached()
        do {
            staticVersions = try await services.catalog("neo4j").fetch(customEndpoint: state.catalogURL, force: force)
        } catch {
            if !error.isCancelled { state.message = error.localizedDescription }
        }
    }

    func installStatic(_ version: StaticVersion) {
        let target = services.neo4j.versionsDirectory.appendingPathComponent("neo4j-\(version.version)")
        guard !(versions.contains { $0.directory.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() && running($0) }) else { state.message = L("message.stopFirst"); return }
        state.runStreaming(String(format: L("message.installingFor"), "Neo4j \(version.version)"), packageDirectory: target) { report, attach in
            try await self.services.catalog("neo4j").install(version, report: report, onStart: attach)
            self.staticVersions = try await self.services.catalog("neo4j").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func uninstallStatic(_ version: StaticVersion) {
        let target = services.neo4j.versionsDirectory.appendingPathComponent("neo4j-\(version.version)")
        guard !(versions.contains { $0.directory.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() && running($0) }) else { state.message = L("message.stopFirst"); return }
        state.runStreaming(String(format: L("message.uninstallingFor"), "Neo4j \(version.version)"), packageDirectory: target) { _, _ in
            try self.services.catalog("neo4j").uninstall(version)
            self.staticVersions = try await self.services.catalog("neo4j").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func loadConfig() {
        guard let version = selectedVersion() else { return }
        do {
            try services.neo4j.prepare(version)
            configText = try String(contentsOf: configURL(version), encoding: .utf8)
        } catch { state.message = error.localizedDescription }
    }

    func saveConfig() {
        guard let version = selectedVersion() else { return }
        do {
            try configText.write(to: configURL(version), atomically: true, encoding: .utf8)
            state.message = L("message.configSaved")
        } catch { state.message = error.localizedDescription }
    }

    func loadLog() {
        guard let version = selectedVersion() else { logText = ""; return }
        logText = services.neo4j.log(version)
    }

    func setCustomDirectories(_ paths: [String]) {
        customDirectories = paths
        Task { await refresh() }
    }
}

extension Neo4jViewModel: ServiceManageable {
    var kind: String { "neo4j" }
    var targets: [LaunchTarget] { versions.map { LaunchTarget(key: $0.id, kind: "neo4j", versionID: $0.id, title: "Neo4j " + $0.version) } }
    func isRunning(_ versionID: String) -> Bool { versions.first { $0.id == versionID }.map { running($0) } ?? false }
    func port(_ versionID: String) -> String? { versions.first { $0.id == versionID }.map { port($0) } }
    func operate(_ action: String, _ versionID: String) async {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        await operate(action, version)
    }
    func perform(_ action: String, _ versionID: String) async throws {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        guard !state.isChanging(version.directory) else { throw CommandError(message: L("message.taskInProgress")) }
        if action == "stop" { try await services.neo4j.stop() } else { try await services.neo4j.start(version) }
    }
    func stopAll() async { try? await services.neo4j.stop() }
    func membership(_ versionID: String) -> PathMembership { pathMembership[versionID] ?? .none }
    func togglePath(_ versionID: String) {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        togglePath(version)
    }
}
