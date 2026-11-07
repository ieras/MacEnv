import SwiftUI

struct NodeManagementView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var vm: NodeViewModel
    @State private var tab = 0
    @State private var source = "Static"
    @State private var customPathEditor = false
    @State private var refreshing = false
    @State private var pendingUninstall: NodeVersion?

    var body: some View {
        ModulePage {
            SegmentedTabs(titles: [L("tab.installed"), L("tab.versions")], selection: $tab)
        } content: {
            page
        }
        .task {
            await vm.loadStatic()
            vm.checkManagers()
        }
        .onChange(of: source) { _ in vm.checkManagers() }
        .sheet(isPresented: $customPathEditor) { CustomPathEditor(title: "Node", paths: $vm.customDirectories) }
        .alert(L("alert.uninstallNodeTitle"), isPresented: Binding(
            get: { pendingUninstall != nil },
            set: { if !$0 { pendingUninstall = nil } })) {
            Button(L("action.cancel"), role: .cancel) { pendingUninstall = nil }
            Button(L("action.uninstall"), role: .destructive) {
                if let version = pendingUninstall {
                    vm.managerAction(version.source, "uninstall", version.version)
                }
                pendingUninstall = nil
            }
        } message: {
            Text(String(format: L("alert.uninstallNodeMessage"), pendingUninstall?.source ?? "", pendingUninstall?.version ?? ""))
        }
    }

    @ViewBuilder
    private var page: some View {
        switch tab {
        case 1: versionManager
        default: installedTable
        }
    }

    // MARK: - 版本管理

    private var versionManager: some View {
        VStack(alignment: .leading, spacing: 0) {
            VersionManagerHeader(sources: ["Static", "Homebrew", "MacPorts", "nvm", "fnm"], source: $source,
                                 linkURL: URL(string: "https://nodejs.org/")!,
                                 busy: app.state.installBusy, refreshing: refreshing, onRefresh: {
                refreshing = true
                Task { await vm.refreshVersionManager(source, force: true); refreshing = false }
            }, width: 460, actions: {})
            Divider()
            if source == "Homebrew" {
                if vm.formulae.isEmpty {
                    Text(L("brew.missing")).padding(24)
                    Link(L("brew.install"), destination: URL(string: "https://brew.sh")!).padding(.horizontal, 24)
                } else {
                    BrewListView(formulae: vm.formulae, busy: app.state.installBusy) { action, formula in
                        vm.brewAction(action, formula: formula)
                    }
                }
            } else if source == "MacPorts" {
                if app.toolsVM.macPortsInstalled {
                    PortListView(items: vm.portItems, loading: vm.portLoading, busy: app.state.installBusy,
                                 load: { await vm.loadPortItems() },
                                 install: { vm.portAction("install", $0) },
                                 uninstall: { vm.portAction("uninstall", $0) })
                } else {
                    Text(L("tools.missingMacPorts")).padding(24)
                }
            } else if source == "nvm" || source == "fnm" {
                managerTab
            } else {
                StaticVersionListView(versions: vm.staticVersions, loading: vm.staticLoading, busy: app.state.installBusy,
                                      install: { vm.installStatic($0) }, uninstall: { vm.uninstallStatic($0) },
                                      badge: { $0.lts.map { "LTS \($0)" } })
            }
            Spacer()
        }
    }

    private var managerTab: some View {
        let installed = source == "nvm" ? vm.nvmInstalled : vm.fnmInstalled
        return Group {
            if installed == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("node.checkingManager")).foregroundStyle(.secondary)
                }
                .padding(24)
            } else if installed == true {
                ManagerVersionListView(vm: vm, manager: source, busy: app.state.installBusy,
                                       onUninstall: { version in pendingUninstall = version })
            } else {
                Text(String(format: L("node.missingManager"), source)).foregroundStyle(.secondary).padding(24)
            }
        }
    }

    // MARK: - 已安装

    private var tableColumns: [TableColumn] {
        [TableColumn(title: L("column.version"), minWidth: 60),
         TableColumn(title: L("column.path"), minWidth: 140, weight: 1),
         TableColumn(title: L("column.source"), minWidth: 90),
         TableColumn(title: L("column.env"), minWidth: 56),
         operationColumn]
    }

    private var installedTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SelectableTitle(text: "NodeJs")
                AssetIcon(name: "NodeIcon").frame(width: 22, height: 22)
                Button { customPathEditor = true } label: { Image(systemName: "folder.badge.plus") }
                    .help(L("action.customPathHint"))
                Spacer()
                RefreshButton(refreshing: $refreshing, busy: app.state.busy) { await vm.refresh() }
            }
            .panelHeader()
            Divider()
            DataTable(columns: tableColumns, rows: vm.versions, empty: L("message.noNodeInstalled")) { version in
                HStack(spacing: 6) {
                    Text(version.version)
                    if version.isNvmDefault || version.isFnmDefault {
                        Text(version.isNvmDefault ? L("node.nvmDefault") : L("node.fnmDefault"))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.cardBackground, in: Capsule())
                    }
                }
                Button { NSWorkspace.shared.open(version.directory) } label: {
                    Text(tilde(version.directory.path)).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.borderless).help(tilde(version.directory.path))
                Text(version.source)
                EnvironmentVariableButton(membership: vm.pathMembership[version.id, default: .none]) { vm.togglePath(version) }
                    .disabled(app.state.busy)
                Group {
                    if version.source == "nvm" || version.source == "fnm" {
                        Button(L("action.uninstall")) { pendingUninstall = version }
                            .buttonStyle(.borderless)
                            .disabled(app.state.installBusy)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - nvm / fnm 版本表

struct ManagerVersionListView: View {
    @ObservedObject var vm: NodeViewModel
    let manager: String  // "nvm" / "fnm"
    var busy = false
    var installedOnly = false
    var onUninstall: (NodeVersion) -> Void = { _ in }
    @State private var search = ""

    private struct Row {
        let name: String
        let version: String
        let lts: String?
        let installed: Bool
        let isDefault: Bool
    }

    private var rows: [Row] {
        let installed = vm.versions.filter { $0.source == manager }.map { version -> Row in
            Row(name: "Node-\(version.version)",
                version: version.version,
                lts: vm.staticVersions.first { $0.version == version.version }?.lts,
                installed: true,
                isDefault: version.isNvmDefault || version.isFnmDefault)
        }
        guard !installedOnly else { return installed }
        let taken = Set(installed.map(\.version))
        let remote = vm.staticVersions
            .filter { !taken.contains($0.version) }
            .map { Row(name: $0.name, version: $0.version, lts: $0.lts, installed: false, isDefault: false) }
        let list = installed + remote
        let key = search.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return list }
        return list.filter { $0.version.contains(key) || $0.name.lowercased().contains(key.lowercased()) }
    }

    private var columns: [TableColumn] {
        if installedOnly {
            return [TableColumn(title: L("column.library"), minWidth: 110, weight: 2),
                    TableColumn(title: L("column.default"), minWidth: 90),
                    TableColumn(title: L("column.operation"), minWidth: 120, weight: 1)]
        }
        return [TableColumn(title: L("column.library"), minWidth: 110, weight: 2),
                TableColumn(title: L("column.version"), minWidth: 90, weight: 1),
                TableColumn(title: L("column.installed"), minWidth: 70),
                TableColumn(title: L("column.default"), minWidth: 90),
                TableColumn(title: L("column.operation"), minWidth: 170, weight: 3)]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField(L("action.search"), text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
                if vm.staticLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button { Task { await vm.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("action.refreshVersions"))
                    .disabled(busy)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 20).padding(.vertical, 10)
            if installedOnly {
                DataTable(columns: columns, rows: rows.filter(\.installed), empty: L("tools.empty")) { row in
                    libraryCell(row)
                    defaultCell(row)
                    operationCell(row)
                }
            } else {
                DataTable(columns: columns, rows: rows, empty: L("port.empty")) { row in
                    libraryCell(row)
                    Text(row.version)
                    Group {
                        if row.installed { Image(systemName: "checkmark").foregroundStyle(AppTheme.green) }
                        else { Text("—").foregroundStyle(.secondary) }
                    }
                    defaultCell(row)
                    operationCell(row)
                }
            }
        }
    }

    @ViewBuilder
    private func libraryCell(_ row: Row) -> some View {
        HStack(spacing: 6) {
            Text(row.name)
            if let lts = row.lts {
                Text("LTS \(lts)")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AppTheme.cardBackground, in: Capsule())
            }
        }
    }

    @ViewBuilder
    private func defaultCell(_ row: Row) -> some View {
        if row.isDefault {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
        } else if row.installed {
            Button(L("node.setDefault")) { vm.managerAction(manager, "alias", row.version) }
                .buttonStyle(.borderless)
                .disabled(busy)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func operationCell(_ row: Row) -> some View {
        if !installedOnly, !row.installed {
            Button(L("action.install")) { vm.managerAction(manager, "install", row.version) }
                .buttonStyle(.borderless)
                .disabled(busy)
        } else if let version = vm.versions.first(where: { $0.source == manager && $0.version == row.version }) {
            Button(L("action.uninstall")) { onUninstall(version) }
                .buttonStyle(.borderless)
                .disabled(busy)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }
}
