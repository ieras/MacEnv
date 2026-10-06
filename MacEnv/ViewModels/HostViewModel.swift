import SwiftUI

@MainActor
final class HostViewModel: ObservableObject {
    private let state: AppState
    private let services: Services

    @Published var hosts: [Host] = []
    @Published var selectedID: String?
    // 已签发证书的到期时间和指纹，按 host.id 索引。没签发过的站点不在里面。
    @Published var certificates: [String: CertificateInfo] = [:]
    @Published var logText = ""
    @Published var logKind = "access"
    @Published var hostsSynced = false
    // 自签根 CA：文件在不在、有没有被系统信任。两个分开记 ——
    // 文件都没有时「重新安装根证书」点了也没用，那种情况按钮干脆不出现。
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

    // PHP 版本下拉只给「有 enable-php-<两位版本>.conf」的那些。NginxService.prepare 是照
    // server/php-fpm/<num> 目录铺的，下拉跟它同源，才不会选到一个 nginx 加载不了的版本。
    var phpVersions: [String] {
        let url = services.root.appendingPathComponent("server/php-fpm", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
            .map(\.lastPathComponent).filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }.sorted()
    }

    func phpLabel(_ num: String) -> String { num.count == 2 ? "\(num.prefix(1)).\(num.suffix(1))" : num }

    func refresh() async {
        do {
            try service.prepare()
            hosts = service.load()
            if !hosts.contains(where: { $0.id == selectedID }) { selectedID = hosts.first?.id }
            hostsSynced = synced()
            rootCAExists = FileManager.default.fileExists(atPath: service.rootCertificate.path)
            rootCATrusted = await service.rootCATrusted()
        } catch {
            state.message = error.localizedDescription
        }
    }

    // MARK: - 增删改

    // 保存一个站点。顺序不能乱：先补伪静态（会改 root），再签证书（要用最终的别名列表），
    // 最后才落 vhost 和 host.json。
    func apply(_ host: Host) {
        state.run {
            var item = host
            self.service.autoFillRewrite(&item)
            if item.useSSL && item.autoSSL {
                // 装了 mkcert 就走它（根 CA 由 mkcert -install 装进系统钥匙串），
                // 没装回落内置 openssl 自签。两条路的证书落地路径完全相同。
                if let mkcert = self.services.mkcert.defaultVersion {
                    try await self.service.issue(&item, withMkcert: mkcert)
                } else {
                    try await self.service.issue(&item)
                }
            }
            if !item.useSSL { item.sslCert = ""; item.sslKey = "" }
            try self.service.write(item)
            if let index = self.hosts.firstIndex(where: { $0.id == item.id }) {
                self.hosts[index] = item
            } else {
                self.hosts.insert(item, at: item.isTop ? self.hosts.filter(\.isTop).count : self.hosts.count)
            }
            self.selectedID = item.id
            try self.service.save(self.hosts)
            self.services.nginx.reloadIfRunning()
            self.state.message = L("message.hostSaved") + item.name
            if let note = await self.writeHosts() { self.state.message += " · " + note }
        }
    }

    // 用 mkcert 给一个站点签证书。对应 FlyEnv MkCertStore.generateCert + taskConfirm：
    // 签完自动开 HTTPS 并重写 vhost，不用用户再回表单勾一次。
    func sign(_ host: Host, using version: MkCertVersion?) {
        guard let version else { state.message = L("mkcert.noVersion"); return }
        state.run {
            var item = host
            try await self.service.issue(&item, withMkcert: version)
            try self.service.write(item)
            if let index = self.hosts.firstIndex(where: { $0.id == item.id }) { self.hosts[index] = item }
            try self.service.save(self.hosts)
            self.services.nginx.reloadIfRunning()
            await self.loadCertificates()
            self.state.message = L("mkcert.signedDone") + item.name
            if let note = await self.writeHosts() { self.state.message += " · " + note }
        }
    }

    // 每个站点的证书到期时间和指纹。没有证书文件的站点直接跳过，界面按「未签发」显示。
    func loadCertificates() async {
        var result: [String: CertificateInfo] = [:]
        for host in hosts {
            if let info = await service.certificateInfo(host) { result[host.id] = info }
        }
        certificates = result
    }

    func delete(_ host: Host) {
        state.run {
            self.service.delete(host)
            self.hosts.removeAll { $0.id == host.id }
            if self.selectedID == host.id { self.selectedID = self.hosts.first?.id }
            try self.service.save(self.hosts)
            self.services.nginx.reloadIfRunning()
            self.state.message = L("message.hostDeleted") + host.name
            // 强制同步一次：站点都没了，hosts 里那条 127.0.0.1 必然是死记录（访问会落到 nginx
            // 默认站点），留着就是垃圾。块内容没变时 syncHosts 直接返回 false，不会白弹授权框。
            if let note = await self.writeHosts(forced: true) { self.state.message += " · " + note }
        }
    }

    func toggleTop(_ host: Host) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        var item = hosts.remove(at: index)
        item.isTop.toggle()
        hosts.insert(item, at: item.isTop ? hosts.filter(\.isTop).count : hosts.count)
        persist()
    }

    // Park：选一个目录，它下面每个子目录自动展开成一个站点（<子目录名>.<站点名>）。
    // 名字已经存在的跳过，所以重复点不会造出一堆重复站点。
    func park(_ host: Host) {
        state.run {
            let root = URL(fileURLWithPath: host.root, isDirectory: true)
            let children = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map(\.lastPathComponent).sorted()
            var added = 0
            for name in children {
                let item = self.parked(host, name: name)
                guard !self.hosts.contains(where: { $0.name == item.name }) else { continue }
                try self.service.write(item)
                self.hosts.append(item)
                added += 1
            }
            try self.service.save(self.hosts)
            self.services.nginx.reloadIfRunning()
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

    // 写系统 hosts，返回给界面拼在提示后面的那段。用户取消授权不算失败 ——
    // 站点本身已经建好了，hosts 那一步单独说清楚就行。
    // forced：删除站点时用，绕开「自动写入」开关（见 delete）。
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

    // /etc/hosts 是只读就能看的，判断我们的标记块在不在，不用提权。
    private func synced() -> Bool {
        let block = service.hostsBlock(hosts).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !block.isEmpty else { return true }
        return ((try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)) ?? "").contains(block)
    }

    private func persist() {
        do { try service.save(hosts) } catch { state.message = error.localizedDescription }
    }

    // MARK: - 站点配置文件

    // 每个 site 一份 nginx vhost：vhost/nginx/<id>.conf，文件名用 id（FlyEnv #700）。
    func configText(_ host: Host) -> String {
        (try? String(contentsOf: service.nginxDirectory.appendingPathComponent("\(host.id).conf"), encoding: .utf8)) ?? ""
    }

    func saveConfig(_ host: Host, _ text: String) {
        do {
            try text.write(to: service.nginxDirectory.appendingPathComponent("\(host.id).conf"), atomically: true, encoding: .utf8)
            services.nginx.reloadIfRunning()
            state.message = L("message.configSavedReloaded")
        } catch {
            state.message = error.localizedDescription
        }
    }
}
