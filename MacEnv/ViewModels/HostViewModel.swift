import SwiftUI

@MainActor
final class HostViewModel: ObservableObject {
    private let state: AppState
    private let services: Services

    @Published var hosts: [Host] = []
    @Published var selectedID: String?
    @Published var certificates: [String: CertificateInfo] = [:]
    @Published var logText = ""
    @Published var logKind = "access"
    @Published var hostsSynced = false
    @Published var rootCAExists = false
    @Published var rootCATrusted = false
    @Published var autoWriteHosts = UserDefaults.standard.object(forKey: "macenv.hosts.autoWrite") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoWriteHosts, forKey: "macenv.hosts.autoWrite") }
    }

    init(state: AppState, services: Services) {
        self.state = state
        self.services = services
    }

    var service: HostService { services.hosts }
    var selected: Host? { hosts.first { $0.id == selectedID } }
    var hostsFile: URL { service.hostsFile }
    var rootCertificate: URL { service.rootCertificate }
    var templateDirectory: URL { service.templateDirectory }

    var phpVersions: [String] {
        let url = services.root.appendingPathComponent("server/php-fpm", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
            .map(\.lastPathComponent).filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }.sorted()
    }

    func phpLabel(_ num: String) -> String { num.count == 2 ? "\(num.prefix(1)).\(num.suffix(1))" : num }

    func refresh() async {
        do {
            try service.prepare()
            hosts = try service.load()
            if !hosts.contains(where: { $0.id == selectedID }) { selectedID = hosts.first?.id }
            hostsSynced = synced()
            rootCAExists = FileManager.default.fileExists(atPath: service.rootCertificate.path)
            rootCATrusted = await service.rootCATrusted()
        } catch {
            state.message = error.localizedDescription
        }
    }

    // MARK: - 增删改

    func apply(_ host: Host) {
        state.run {
            var item = host
            var next = self.hosts
            try await self.commit {
                self.service.autoFillRewrite(&item)
                if item.useSSL && item.autoSSL {
                    if let mkcert = self.services.mkcert.defaultVersion { try await self.service.issue(&item, withMkcert: mkcert) }
                    else { try await self.service.issue(&item) }
                }
                if !item.useSSL { item.sslCert = ""; item.sslKey = "" }
                try self.service.write(item)
                if let index = next.firstIndex(where: { $0.id == item.id }) { next[index] = item }
                else { next.insert(item, at: item.isTop ? next.filter(\.isTop).count : next.count) }
                try self.service.save(next)
            }
            self.hosts = next
            self.selectedID = item.id
            self.state.message = L("message.hostSaved") + item.name
            if let note = await self.writeHosts() { self.state.message += " · " + note }
        }
    }

    func sign(_ host: Host, using version: MkCertVersion?) {
        guard let version else { state.message = L("mkcert.noVersion"); return }
        state.run {
            var item = host
            var next = self.hosts
            try await self.commit {
                try await self.service.issue(&item, withMkcert: version)
                try self.service.write(item)
                if let index = next.firstIndex(where: { $0.id == item.id }) { next[index] = item }
                try self.service.save(next)
            }
            self.hosts = next
            await self.loadCertificates()
            self.state.message = L("mkcert.signedDone") + item.name
            if let note = await self.writeHosts() { self.state.message += " · " + note }
        }
    }

    private func commit(_ write: () async throws -> Void) async throws {
        _ = try service.load()
        let fm = FileManager.default
        let backup = fm.temporaryDirectory.appendingPathComponent("macenv-host-save-" + UUID().uuidString)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        var keepBackup = false
        defer { if !keepBackup { try? fm.removeItem(at: backup) } }
        let files = [service.nginxDirectory, service.rewriteDirectory, service.caDirectory, service.file]
        for (index, file) in files.enumerated() where fm.fileExists(atPath: file.path) {
            try fm.copyItem(at: file, to: backup.appendingPathComponent(String(index)))
        }
        do {
            try await write()
            try await services.nginx.reloadIfRunning()
        } catch {
            let original = error
            do {
                for (index, file) in files.enumerated() {
                    let saved = backup.appendingPathComponent(String(index))
                    if file == service.caDirectory, fm.fileExists(atPath: file.path) {
                        for entry in try fm.contentsOfDirectory(at: file, includingPropertiesForKeys: nil)
                        where !entry.lastPathComponent.hasPrefix("MacEnv-Root-CA") { try fm.removeItem(at: entry) }
                        if fm.fileExists(atPath: saved.path) {
                            for entry in try fm.contentsOfDirectory(at: saved, includingPropertiesForKeys: nil)
                            where !entry.lastPathComponent.hasPrefix("MacEnv-Root-CA") {
                                try fm.copyItem(at: entry, to: file.appendingPathComponent(entry.lastPathComponent))
                            }
                        }
                    } else {
                        if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
                        if fm.fileExists(atPath: saved.path) { try fm.copyItem(at: saved, to: file) }
                    }
                }
            } catch {
                keepBackup = true
                throw CommandError(message: original.localizedDescription + "\n" + error.localizedDescription + "\n" + backup.path)
            }
            throw original
        }
    }

    func loadCertificates() async {
        var result: [String: CertificateInfo] = [:]
        for host in hosts {
            if let info = await service.certificateInfo(host) { result[host.id] = info }
        }
        certificates = result
    }

    func delete(_ host: Host) {
        state.run {
            let next = self.hosts.filter { $0.id != host.id }
            try await self.commit {
                let file = self.service.nginxDirectory.appendingPathComponent("\(host.id).conf")
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                try self.service.save(next)
            }
            self.service.delete(host)
            self.hosts = next
            if self.selectedID == host.id { self.selectedID = next.first?.id }
            self.state.message = L("message.hostDeleted") + host.name
            if let note = await self.writeHosts(forced: true) { self.state.message += " · " + note }
        }
    }

    func toggleTop(_ host: Host) {
        state.run {
            var next = self.hosts
            guard let index = next.firstIndex(where: { $0.id == host.id }) else { return }
            var item = next.remove(at: index)
            item.isTop.toggle()
            next.insert(item, at: item.isTop ? next.filter(\.isTop).count : next.count)
            try self.service.save(next)
            self.hosts = next
        }
    }

    func park(_ host: Host) {
        state.run {
            let root = URL(fileURLWithPath: host.root, isDirectory: true)
            let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map(\.lastPathComponent).sorted()
            var added = 0
            var next = self.hosts
            try await self.commit {
                for name in children {
                    var item = self.parked(host, name: name)
                    guard !next.contains(where: { $0.name == item.name }) else { continue }
                    self.service.autoFillRewrite(&item)
                    if item.useSSL && item.autoSSL {
                        if let mkcert = self.services.mkcert.defaultVersion { try await self.service.issue(&item, withMkcert: mkcert) }
                        else { try await self.service.issue(&item) }
                    }
                    try self.service.write(item)
                    next.append(item)
                    added += 1
                }
                try self.service.save(next)
            }
            self.hosts = next
            self.state.message = added == 0 ? L("message.parkNothing") : L("message.parkDone") + "\(added)"
            if added > 0, let note = await self.writeHosts() { self.state.message += " · " + note }
        }
    }

    private func parked(_ host: Host, name: String) -> Host {
        var item = host.copy()
        item.rewrite = ""
        item.sslCert = ""
        item.sslKey = ""
        item.root = URL(fileURLWithPath: host.root, isDirectory: true).appendingPathComponent(name).path
        item.name = name + "." + host.name
        item.alias = host.alias.split(whereSeparator: \.isNewline)
            .map { name + "." + $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        return item
    }

    // MARK: - 日志与系统 hosts

    func loadLog() {
        guard let host = selected else { logText = ""; return }
        logText = service.log(host, kind: logKind)
    }

    func syncHostsNow() {
        state.run {
            let changed = try await self.service.syncHosts(self.hosts)
            self.hostsSynced = self.synced()
            self.state.message = changed ? L("message.hostsWritten") : L("message.hostsUnchanged")
        }
    }

    func trustRootCertificate() {
        state.run {
            try await self.service.trustRootCertificate()
            self.rootCAExists = FileManager.default.fileExists(atPath: self.service.rootCertificate.path)
            self.rootCATrusted = await self.service.rootCATrusted()
            self.state.message = L("message.rootTrusted")
        }
    }

    private func writeHosts(forced: Bool = false) async -> String? {
        guard forced || autoWriteHosts else { return nil }
        do {
            let changed = try await service.syncHosts(hosts)
            hostsSynced = synced()
            return changed ? L("message.hostsWritten") : nil
        } catch {
            return L("message.hostsFailed") + error.localizedDescription
        }
    }

    private func synced() -> Bool {
        let block = service.hostsBlock(hosts).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !block.isEmpty else { return true }
        return ((try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)) ?? "").contains(block)
    }

    // MARK: - 站点配置文件

    func configText(_ host: Host) -> String {
        (try? String(contentsOf: service.nginxDirectory.appendingPathComponent("\(host.id).conf"), encoding: .utf8)) ?? ""
    }

    func saveConfig(_ host: Host, _ text: String) {
        state.run {
            try await self.commit {
                try text.write(to: self.service.nginxDirectory.appendingPathComponent("\(host.id).conf"), atomically: true, encoding: .utf8)
            }
            self.state.message = L("message.configSavedReloaded")
        }
    }
}
