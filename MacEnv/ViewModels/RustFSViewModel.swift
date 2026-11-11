import SwiftUI

@MainActor
final class RustFSViewModel: ObservableObject {
    let state: AppState
    let services: Services

    @Published var versions: [RustFSVersion] = []
    @Published var staticVersions: [StaticVersion] = []
    @Published var staticLoading = false
    @Published var pathMembership: [String: PathMembership] = [:]
    @Published var selected = ""
    @Published var configText = ""
    @Published var logText = ""
    @Published var customDirectories = UserDefaults.standard.stringArray(forKey: "macenv.rustfs.directories") ?? [] {
        didSet { UserDefaults.standard.set(customDirectories, forKey: "macenv.rustfs.directories") }
    }

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    func selectedVersion() -> RustFSVersion? { versions.first { $0.id == selected } ?? versions.first }
    func running(_ version: RustFSVersion) -> Bool { services.rustfs.running(version) }
    func dataURL(_ version: RustFSVersion) -> URL { services.rustfs.dataURL(for: version) }
    func port(_ version: RustFSVersion) -> String { String(services.rustfs.ports().api) }
    func consolePort() -> Int { services.rustfs.ports().console }
    func configURL() -> URL { services.rustfs.configURL }
    func logURL(error: Bool) -> URL? { selectedVersion().map { services.rustfs.logURL($0, error: error) } }

    func refresh() async {
        do {
            try await services.paths.refresh()
            try services.rustfs.prepare()
            let found = try await services.rustfs.installedVersions(customDirectories: customDirectories + services.paths.allPath)
            versions = found
            await services.rustfs.adopt(found)
            pathMembership = Dictionary(uniqueKeysWithValues: found.map { ($0.id, services.paths.membership(kind: "rustfs", directory: $0.directory)) })
            if !found.contains(where: { $0.id == selected }) { selected = found.first?.id ?? "" }
        } catch {
            state.message = error.localizedDescription
        }
        objectWillChange.send()
    }

    func operate(_ operation: String, _ version: RustFSVersion) async {
        guard !state.busy else { return }
        guard !state.isChanging(version.directory) else { state.message = L("message.taskInProgress"); return }
        selected = version.id
        let service = services.rustfs
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
            let stopping = operation == "stop"
            if stopping { try await service.stop() } else { try await service.start(version) }
            state.message = "RustFS " + L(stopping ? "message.stopped" : "message.started")
            await refresh()
        } catch {
            state.message = error.localizedDescription
        }
    }

    func setDataURL(_ url: URL, for version: RustFSVersion) {
        services.rustfs.setDataURL(url, for: version)
        objectWillChange.send()
    }

    func togglePath(_ version: RustFSVersion) {
        state.run { [self] in
            try services.paths.toggle(kind: "rustfs", directory: version.directory)
            try await services.paths.refresh(force: true)
            pathMembership = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, services.paths.membership(kind: "rustfs", directory: $0.directory)) })
            let enabled = pathMembership[version.id] == .app
            state.message = String(format: L(enabled ? "message.pathEnabledFor" : "message.pathDisabledFor"), "RustFS " + version.version)
        }
    }

    // MARK: - 静态包

    func loadStatic(force: Bool = false) async {
        guard !staticLoading else { return }
        staticLoading = true
        defer { staticLoading = false }
        staticVersions = services.catalog("rustfs").cached()
        do {
            staticVersions = try await services.catalog("rustfs").fetch(customEndpoint: state.catalogURL, force: force)
        } catch {
            if !error.isCancelled { state.message = error.localizedDescription }
        }
    }

    func installStatic(_ version: StaticVersion) {
        let target = services.rustfs.versionsDirectory.appendingPathComponent("rustfs-\(version.version)")
        guard !(versions.contains { $0.directory.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() && running($0) }) else { state.message = L("message.stopFirst"); return }
        state.runStreaming(String(format: L("message.installingFor"), "RustFS \(version.version)"), packageDirectory: target) { report, attach in
            try await self.services.catalog("rustfs").install(version, report: report, onStart: attach)
            self.staticVersions = try await self.services.catalog("rustfs").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func uninstallStatic(_ version: StaticVersion) {
        let target = services.rustfs.versionsDirectory.appendingPathComponent("rustfs-\(version.version)")
        guard !(versions.contains { $0.directory.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() && running($0) }) else { state.message = L("message.stopFirst"); return }
        state.runStreaming(String(format: L("message.uninstallingFor"), "RustFS \(version.version)"), packageDirectory: target) { _, _ in
            try self.services.catalog("rustfs").uninstall(version)
            self.staticVersions = try await self.services.catalog("rustfs").fetch(customEndpoint: self.state.catalogURL)
            await self.refresh()
        }
    }

    func loadConfig() {
        do {
            try services.rustfs.prepare()
            configText = try String(contentsOf: configURL(), encoding: .utf8)
        } catch { state.message = error.localizedDescription }
    }

    func saveConfig() {
        do {
            try configText.write(to: configURL(), atomically: true, encoding: .utf8)
            state.message = L("message.configSaved")
        } catch { state.message = error.localizedDescription }
    }

    func loadLog(error: Bool) {
        guard let version = selectedVersion() else { logText = ""; return }
        logText = services.rustfs.log(version, error: error)
    }

    func setCustomDirectories(_ paths: [String]) {
        customDirectories = paths
        Task { await refresh() }
    }
}

extension RustFSViewModel: ServiceManageable {
    var kind: String { "rustfs" }
    var targets: [LaunchTarget] { versions.map { LaunchTarget(key: $0.id, kind: "rustfs", versionID: $0.id, title: "RustFS " + $0.version) } }
    func isRunning(_ versionID: String) -> Bool { versions.first { $0.id == versionID }.map { running($0) } ?? false }
    func port(_ versionID: String) -> String? { versions.first { $0.id == versionID }.map { port($0) } }
    func operate(_ action: String, _ versionID: String) async {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        await operate(action, version)
    }
    func perform(_ action: String, _ versionID: String) async throws {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        guard !state.isChanging(version.directory) else { throw CommandError(message: L("message.taskInProgress")) }
        if action == "stop" { try await services.rustfs.stop() } else { try await services.rustfs.start(version) }
    }
    func stopAll() async { try? await services.rustfs.stop() }
    func membership(_ versionID: String) -> PathMembership { pathMembership[versionID] ?? .none }
    func togglePath(_ versionID: String) {
        guard let version = versions.first(where: { $0.id == versionID }) else { return }
        togglePath(version)
    }
}
