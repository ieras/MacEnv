import SwiftUI

@MainActor
final class KafkaViewModel: ObservableObject {
    let state: AppState
    let services: Services

    @Published var versions: [KafkaVersion] = []
    @Published var staticVersions: [StaticVersion] = []
    @Published var staticLoading = false
    @Published var pathMembership: [String: PathMembership] = [:]
    @Published var selectedID = ""
    @Published var configText = ""
    @Published var logText = ""
    @Published private var javaRevision = 0
    @Published var customDirectories = UserDefaults.standard.stringArray(forKey: "macenv.kafka.directories") ?? [] {
        didSet { UserDefaults.standard.set(customDirectories, forKey: "macenv.kafka.directories") }
    }

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    func selectedVersion() -> KafkaVersion? { versions.first { $0.id == selectedID } ?? versions.first }

    func configURL(_ version: KafkaVersion) -> URL { services.kafka.configURL(for: version) }
    func dataURL(_ version: KafkaVersion) -> URL { services.kafka.dataURL(for: version) }
    func logURL() -> URL? { selectedVersion().map { services.kafka.logFile(for: $0) } }
    func port(_ version: KafkaVersion) -> String {
        let ports = services.kafka.ports(for: version)
        return "\(ports.broker) / \(ports.controller)"
    }
    func running(_ version: KafkaVersion) -> Bool { services.kafka.running(version) }

    func refresh() async {
        do {
            try await services.paths.refresh()
            let service = services.kafka
            service.installedJava = await services.java.installedVersions()
            let found = try await service.installedVersions(customDirectories: customDirectories + services.paths.allPath)
            for version in found { try service.prepare(version) }
            service.reconcileBindings(found)
            versions = found
            await service.adopt(found)
            pathMembership = Dictionary(uniqueKeysWithValues: found.map { ($0.id, services.paths.membership(kind: "kafka", directory: $0.directory)) })
            if !found.contains(where: { $0.id == selectedID }) { selectedID = found.first?.id ?? "" }
            javaRevision += 1
        } catch {
            state.message = error.localizedDescription
        }
        objectWillChange.send()
    }

    // MARK: - Java 绑定

    func javaCandidates() -> [JavaVersion] { services.kafka.javaCandidates() }
    func selectedJava(_ version: KafkaVersion) -> String { services.kafka.binding(for: version) ?? "" }

    func setJava(_ version: KafkaVersion, _ javaHome: String) {
        guard !running(version) else { state.message = L("message.kafkaJavaWhileRunning"); return }
        services.kafka.setBinding(version, javaHome)
        javaRevision += 1
    }

    // MARK: - 服务操作

    func operate(_ operation: String, _ version: KafkaVersion) async {
        guard !state.busy else { return }
        guard !state.isChanging(version.directory) else { state.message = L("message.taskInProgress"); return }
        selectedID = version.id
        let service = services.kafka
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
            state.message = "Kafka " + (operation == "start" ? L("message.started") : L("message.stopped"))
            await refresh()
        } catch {
            state.message = error.localizedDescription
        }
    }

    func togglePath(_ version: KafkaVersion) {
        state.run { [self] in
            try services.paths.toggle(kind: "kafka", directory: version.directory)
            try await services.paths.refresh(force: true)
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "kafka", directory: $0.directory)) })
            let enabled = pathMembership[version.id] == .app
            state.message = String(format: L(enabled ? "message.pathEnabledFor" : "message.pathDisabledFor"), "Kafka " + version.version)
        }
    }

    // MARK: - 静态包

    func loadStatic(force: Bool = false) async {
        guard !staticLoading else { return }
        staticLoading = true
        defer { staticLoading = false }
        staticVersions = services.catalog("kafka").cached()
        do {
            staticVersions = try await services.catalog("kafka").fetch(customEndpoint: state.catalogURL, force: force)
        } catch {
            if !error.isCancelled { state.message = error.localizedDescription }
        }
    }

    func installStatic(_ version: StaticVersion) {
        let target = services.kafka.versionsDirectory.appendingPathComponent("kafka-\(version.version)")
        guard !(versions.contains { $0.directory.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() && running($0) }) else { state.message = L("message.stopFirst"); return }
        state.runStreaming(String(format: L("message.installingFor"), "Kafka \(version.version)"), packageDirectory: target) { report, attach in
            try await self.services.catalog("kafka").install(version, report: report, onStart: attach)
            self.staticVersions = try await self.services.catalog("kafka").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func uninstallStatic(_ version: StaticVersion) {
        let target = services.kafka.versionsDirectory.appendingPathComponent("kafka-\(version.version)")
        guard !(versions.contains { $0.directory.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() && running($0) }) else { state.message = L("message.stopFirst"); return }
        state.runStreaming(String(format: L("message.uninstallingFor"), "Kafka \(version.version)"), packageDirectory: target) { _, _ in
            try self.services.catalog("kafka").uninstall(version)
            self.staticVersions = try await self.services.catalog("kafka").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    // MARK: - 配置与日志

    func loadConfig() {
        guard let version = selectedVersion() else { return }
        do {
            try services.kafka.prepare(version)
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

    func loadLog() { logText = selectedVersion().map { services.kafka.log($0) } ?? "" }

    func setCustomDirectories(_ paths: [String]) {
        customDirectories = paths
        Task { await refresh() }
    }
}

extension KafkaViewModel: ServiceManageable {
    var kind: String { "kafka" }
    var targets: [LaunchTarget] { versions.map { LaunchTarget(key: $0.id, kind: "kafka", versionID: $0.id, title: "Kafka " + $0.version) } }
    func isRunning(_ versionID: String) -> Bool { versions.first { $0.id == versionID }.map { running($0) } ?? false }
    func port(_ versionID: String) -> String? { versions.first { $0.id == versionID }.map { port($0) } }
    func operate(_ action: String, _ versionID: String) async {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        await operate(action, version)
    }
    func perform(_ action: String, _ versionID: String) async throws {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        guard !state.isChanging(version.directory) else { throw CommandError(message: L("message.taskInProgress")) }
        if action == "stop" { try await services.kafka.stop() } else { try await services.kafka.start(version) }
    }
    func stopAll() async { try? await services.kafka.stop() }
    func membership(_ versionID: String) -> PathMembership { pathMembership[versionID] ?? .none }
    func togglePath(_ versionID: String) {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        togglePath(version)
    }
}
