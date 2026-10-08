import SwiftUI

@MainActor
final class QdrantViewModel: ObservableObject {
    let state: AppState
    let services: Services

    @Published var versions: [QdrantVersion] = []
    @Published var staticVersions: [StaticVersion] = []
    @Published var staticLoading = false
    @Published var pathMembership: [String: PathMembership] = [:]
    @Published var selected = ""
    @Published var configText = ""
    @Published var logText = ""
    @Published var customDirectories: [String] = {
        guard let data = UserDefaults.standard.data(forKey: "macenv.qdrant.directories"),
              let value = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return value
    }() {
        didSet { if let data = try? JSONEncoder().encode(customDirectories) { UserDefaults.standard.set(data, forKey: "macenv.qdrant.directories") } }
    }

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    func selectedVersion() -> QdrantVersion? { versions.first { $0.id == selected } ?? versions.first }

    func configURL(_ version: QdrantVersion) -> URL { services.qdrant.configURL(for: version) }
    func dataURL(_ version: QdrantVersion) -> URL { services.qdrant.storageURL(for: version) }
    func logURL() -> URL? { selectedVersion().map { services.qdrant.logFile(for: $0) } }
    func port(_ version: QdrantVersion) -> Int { services.qdrant.port(for: version) }
    func running(_ version: QdrantVersion) -> Bool { services.qdrant.running(version) }

    func refresh() async {
        do {
            try await services.paths.refresh()
            let service = services.qdrant
            let found = try await service.installedVersions(customDirectories: customDirectories + services.paths.allPath)
            for version in found { try service.prepare(version) }
            versions = found
            await service.adopt(found)
            pathMembership = Dictionary(uniqueKeysWithValues: found.map { ($0.id, services.paths.membership(kind: "qdrant", directory: $0.directory)) })
            if !found.contains(where: { $0.id == selected }) { selected = found.first?.id ?? "" }
        } catch {
            state.message = error.localizedDescription
        }
        objectWillChange.send()
    }

    func operate(_ operation: String, _ version: QdrantVersion) async {
        guard !state.busy else { return }
        guard !state.isChanging(version.directory) else { state.message = L("message.taskInProgress"); return }
        selected = version.id
        let service = services.qdrant
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
            state.message = "Qdrant " + (operation == "start" ? L("message.started") : L("message.stopped"))
            await refresh()
        } catch {
            state.message = error.localizedDescription
        }
    }

    func togglePath(_ version: QdrantVersion) {
        state.run { [self] in
            try services.paths.toggle(kind: "qdrant", directory: version.directory)
            try await services.paths.refresh(force: true)
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "qdrant", directory: $0.directory)) })
            let enabled = pathMembership[version.id] == .app
            state.message = String(format: L(enabled ? "message.pathEnabledFor" : "message.pathDisabledFor"), "Qdrant " + version.version)
        }
    }

    // MARK: - 静态包（唯一来源：官方没发 brew 公式、MacPorts 也没有 port）

    func loadStatic(force: Bool = false) async {
        guard !staticLoading else { return }
        staticLoading = true
        defer { staticLoading = false }
        staticVersions = services.catalog("qdrant").cached()
        do {
            staticVersions = try await services.catalog("qdrant").fetch(customEndpoint: state.catalogURL, force: force)
        } catch {
            if !error.isCancelled { state.message = error.localizedDescription }
        }
    }

    func installStatic(_ version: StaticVersion) {
        let target = services.qdrant.versionsDirectory.appendingPathComponent("qdrant-\(version.version)")
        guard !(versions.contains { $0.directory.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() && running($0) }) else { state.message = L("message.stopFirst"); return }
        state.runStreaming(String(format: L("message.installingFor"), "Qdrant \(version.version)"), packageDirectory: target) { report, attach in
            try await self.services.catalog("qdrant").install(version, report: report, onStart: attach)
            self.staticVersions = try await self.services.catalog("qdrant").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func uninstallStatic(_ version: StaticVersion) {
        let target = services.qdrant.versionsDirectory.appendingPathComponent("qdrant-\(version.version)")
        guard !(versions.contains { $0.directory.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() && running($0) }) else { state.message = L("message.stopFirst"); return }
        state.runStreaming(String(format: L("message.uninstallingFor"), "Qdrant \(version.version)"), packageDirectory: target) { _, _ in
            try self.services.catalog("qdrant").uninstall(version)
            self.staticVersions = try await self.services.catalog("qdrant").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func loadConfig() {
        guard let version = selectedVersion() else { return }
        do {
            try services.qdrant.prepare(version)
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
        logText = services.qdrant.log(version)
    }

    func setCustomDirectories(_ paths: [String]) {
        customDirectories = paths
        Task { await refresh() }
    }
}

extension QdrantViewModel: ServiceManageable {
    var kind: String { "qdrant" }
    var targets: [LaunchTarget] { versions.map { LaunchTarget(key: $0.id, kind: "qdrant", versionID: $0.id, title: "Qdrant " + $0.version) } }
    func isRunning(_ versionID: String) -> Bool { versions.first { $0.id == versionID }.map { running($0) } ?? false }
    func port(_ versionID: String) -> String? { versions.first { $0.id == versionID }.map { String(port($0)) } }
    func operate(_ action: String, _ versionID: String) async {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        await operate(action, version)
    }
    func perform(_ action: String, _ versionID: String) async throws {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        guard !state.isChanging(version.directory) else { throw CommandError(message: L("message.taskInProgress")) }
        if action == "stop" { try await services.qdrant.stop() } else { try await services.qdrant.start(version) }
    }
    func stopAll() async { try? await services.qdrant.stop() }
    func membership(_ versionID: String) -> PathMembership { pathMembership[versionID] ?? .none }
    func togglePath(_ versionID: String) {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        togglePath(version)
    }
}
