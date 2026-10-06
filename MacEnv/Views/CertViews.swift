import SwiftUI
import AppKit

// 站点证书：服务 / 版本管理 / 证书 三个子 tab。
// 对应 FlyEnv 的 MkCert 模块，但并进「站点」而不单列一个侧边栏条目 ——
// FlyEnv 自己也是把它归到 site 类（MkCert/Module.ts 里 moduleType: 'site'）。
struct CertificatePanelView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var vm: MkCertViewModel
    @ObservedObject var hostVM: HostViewModel
    @State private var tab = 0
    @State private var source = "Static"
    @State private var refreshing = false
    @State private var customPathEditor = false
    @State private var confirmUninstallCA = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 二级 tab 固定宽度，不撑满整行 —— 跟一级 tab 一样宽就分不出哪层是哪层了。
            SegmentedTabs(titles: [L("tab.installed"), L("tab.versions"), L("mkcert.certificates")], selection: $tab)
                .frame(width: 330)
                .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            page
        }
        .sheet(isPresented: $customPathEditor) {
            CustomPathEditor(title: "MkCert", paths: Binding(get: { vm.customDirectories }, set: { vm.setCustomDirectories($0) }))
        }
        .alert(L("alert.uninstallCATitle"), isPresented: $confirmUninstallCA) {
            Button(L("action.cancel"), role: .cancel) {}
            Button(L("action.uninstall"), role: .destructive) { vm.uninstallCA() }
        } message: { Text(L("alert.uninstallCAMessage")) }
        .task {
            await vm.refresh()
            await vm.loadStatic()
            await hostVM.loadCertificates()
        }
        .onChange(of: vm.selected) { _ in Task { await vm.loadCaroot() } }
    }

    @ViewBuilder
    private var page: some View {
        switch tab {
        case 1: versionManager
        case 2: certificateList
        default: installedPanel
        }
    }

    // MARK: - 已安装

    // 跟 Composer / Swoole CLI 的「已安装」页同一套：顶栏是标题 + 图标 + 自定义目录 + 刷新，
    // 下面一张 DataTable。根 CA 的装 / 卸 / 检测不在这里，都在「证书」页顶栏。
    private var installedPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("MkCert").font(.title3)
                SSLIcon().frame(width: 22, height: 22)
                // 多版本时给个下拉 —— 「证书」页签发用的就是这里选中的那个。
                if vm.versions.count > 1 {
                    Picker("", selection: $vm.selected) {
                        ForEach(vm.versions) { version in Text(version.version).tag(version.id) }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
                Button { customPathEditor = true } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.borderless)
                    .help(L("action.customPathHint"))
                Spacer()
                Button { Task { await vm.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("action.reload"))
            }
            .panelHeader()
            Divider()
            installedTable
            Spacer()
        }
    }

    // 列跟 Composer 对齐，中间插一列「来源」（Homebrew / Static / MacPorts）。
    private var installedColumns: [TableColumn] {
        [TableColumn(title: L("column.version"), minWidth: 60),
         TableColumn(title: L("column.path"), minWidth: 140, weight: 1),
         TableColumn(title: L("column.source"), minWidth: 70),
         TableColumn(title: L("column.env"), minWidth: 56)]
    }

    private var installedTable: some View {
        DataTable(columns: installedColumns, rows: vm.versions, empty: L("mkcert.installHint")) { version in
            Text(version.version)
            Button { NSWorkspace.shared.open(version.directory) } label: {
                Text(tilde(version.directory.path)).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.borderless).help(tilde(version.directory.path))
            Text(version.source).foregroundStyle(.secondary)
            EnvironmentVariableButton(membership: vm.pathMembership[version.id, default: .none]) { vm.togglePath(version) }
                .disabled(app.state.busy)
        }
    }

    // MARK: - 版本管理

    private var versionManager: some View {
        VStack(alignment: .leading, spacing: 0) {
            VersionManagerHeader(sources: ["Static", "Homebrew", "MacPorts"], source: $source,
                                 linkURL: URL(string: "https://github.com/FiloSottile/mkcert/releases")!,
                                 busy: app.state.busy, refreshing: refreshing, onRefresh: {
                refreshing = true
                Task { await vm.refreshVersionManager(source, force: true); refreshing = false }
            }, actions: {
                if source == "Homebrew" { Button(L("action.updateBrew")) { vm.brewAction("update", "mkcert") }.disabled(app.state.busy) }
            })
            Divider()
            if source == "Homebrew" {
                if vm.formulae.isEmpty {
                    Text(L("brew.noFormulaList")).foregroundStyle(.secondary).padding(24)
                } else {
                    BrewListView(formulae: vm.formulae, busy: app.state.busy) { vm.brewAction($0, $1) }
                }
            } else if source == "Static" {
                StaticVersionListView(versions: vm.staticVersions, loading: vm.staticLoading) { vm.installStatic($0) } uninstall: { vm.uninstallStatic($0) }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(FileManager.default.isExecutableFile(atPath: "/opt/local/bin/port")
                         ? L("macports.detectedDatabase") + "MkCert" + L("macports.detectedSuffix")
                         : L("macports.missing"))
                    Link(L("macports.install"), destination: URL(string: "https://www.macports.org/install.php")!)
                }.padding(24)
            }
            Spacer()
        }
    }

    // MARK: - 证书

    private var certificateList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(L("mkcert.certificates")).font(.title3)
                if let version = vm.selectedVersion {
                    Text("MkCert \(version.version)").foregroundStyle(.secondary)
                    if !vm.caroot.isEmpty {
                        Text("·").foregroundStyle(.secondary)
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: vm.caroot)) } label: {
                            Text(tilde(vm.caroot)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .buttonStyle(.borderless)
                        .help(L("mkcert.caroot") + " " + tilde(vm.caroot))
                    }
                    // 装完亮出来，不然用户看不出这一步到底成没成。
                    if vm.caTrusted {
                        Label(L("mkcert.caTrusted"), systemImage: "checkmark.seal.fill")
                            .font(.callout).foregroundStyle(AppTheme.green)
                    }
                } else {
                    Text(L("mkcert.notInstalled")).foregroundStyle(.orange)
                }
                Spacer()
                Button { Task { await hostVM.loadCertificates() } } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("action.reload"))
                // 根 CA 的装 / 卸 / 检测。放这一排是为了跟证书列表挨着 ——
                // 换过 CA 之后这些站点的证书就得重签，两件事本来就分不开。
                if vm.selectedVersion != nil {
                    // 重复装是幂等的（钥匙串按证书去重，实测装三次仍只有一条），但 GUI 里
                    // 每次都会弹一次系统授权框 —— 已经信任了就别让用户白点、白弹。
                    if !vm.caTrusted {
                        Button { vm.installCA() } label: { Image(systemName: "arrow.down.circle") }
                            .help(L("mkcert.installCA")).disabled(app.state.busy)
                    }
                    if vm.caExists {
                        Button { confirmUninstallCA = true } label: { Image(systemName: "trash") }
                            .help(L("mkcert.uninstallCA")).disabled(app.state.busy)
                    }
                    Button { Task { await vm.loadCaroot() } } label: { Image(systemName: "checkmark.shield") }
                        .help(L("mkcert.recheck")).disabled(app.state.busy)
                }
            }
            .panelHeader()
            Divider()
            if hostVM.hosts.isEmpty {
                Text(L("mkcert.empty")).foregroundStyle(.secondary).padding(30)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(hostVM.hosts) { certificateCard($0) }
                    }
                    .padding(20)
                }
            }
        }
    }

    // 一站一卡，不用 DataTable：每个站点要摆 cert + key 两条长路径加到期时间、指纹，
    // 表格列塞不下，而且 DataTable 全局 .lineLimit(1) 会把多行内容压成一行。
    private func certificateCard(_ host: Host) -> some View {
        let paths = hostVM.service.certificatePaths(host)
        let info = hostVM.certificates[host.id]
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(host.name).font(.callout.weight(.semibold))
                    if host.useSSL { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(AppTheme.green) }
                    Text(info == nil ? L("mkcert.unsigned") : L("mkcert.signed"))
                        .font(.caption2).foregroundStyle(info == nil ? Color.secondary : AppTheme.green)
                }
                pathLine("cert", paths.cert)
                pathLine("key", paths.key)
                if let info {
                    Text(L("mkcert.expiry") + info.expiry).font(.caption2).foregroundStyle(.secondary)
                    Text(L("mkcert.fingerprint") + info.fingerprint)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(info.fingerprint)
                }
            }
            Spacer(minLength: 8)
            Button(L("mkcert.generate")) { hostVM.sign(host, using: vm.selectedVersion) }
                .disabled(app.state.busy || vm.selectedVersion == nil)
        }
        .padding(14)
        .background(AppTheme.cardBackground, in: RoundedRectangle(cornerRadius: AppTheme.radiusCard))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusCard).stroke(AppTheme.stroke))
    }

    // 卡片里的 cert / key 路径。窄列放不下按钮，靠选中复制 —— 反正这两个路径是给人看的。
    private func pathLine(_ label: String, _ path: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            Text(tilde(path)).font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .help(tilde(path))
    }
}
