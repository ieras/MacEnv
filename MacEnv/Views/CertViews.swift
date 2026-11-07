import SwiftUI
import AppKit

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

    private var installedPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                SelectableTitle(text: "MkCert")
                SSLIcon().frame(width: 22, height: 22)
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
                                 busy: app.state.installBusy, refreshing: refreshing, onRefresh: {
                refreshing = true
                Task { await vm.refreshVersionManager(source, force: true); refreshing = false }
            }, actions: {})
            Divider()
            if source == "Homebrew" {
                if vm.formulae.isEmpty {
                    Text(L("brew.noFormulaList")).foregroundStyle(.secondary).padding(24)
                } else {
                    BrewListView(formulae: vm.formulae, busy: app.state.installBusy) { vm.brewAction($0, $1) }
                }
            } else if source == "Static" {
                StaticVersionListView(versions: vm.staticVersions, loading: vm.staticLoading, busy: app.state.installBusy) { vm.installStatic($0) } uninstall: { vm.uninstallStatic($0) }
            } else if source == "MacPorts" {
                if app.toolsVM.macPortsInstalled {
                    PortListView(items: vm.portItems, loading: vm.portLoading, busy: app.state.installBusy,
                                 load: { await vm.loadPortItems() },
                                 install: { vm.portAction("install", $0) },
                                 uninstall: { vm.portAction("uninstall", $0) })
                } else {
                    Text(L("tools.missingMacPorts")).padding(24)
                }
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
                if vm.selectedVersion != nil {
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
