import SwiftUI

struct RustFSManagementView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var vm: RustFSViewModel
    @State private var tab = 0
    @State private var source = "Static"
    @State private var customPathEditor = false
    @State private var refreshing = false

    private var tableColumns: [TableColumn] {
        [TableColumn(title: L("column.version"), minWidth: 50),
         TableColumn(title: L("column.path"), minWidth: 120, weight: 6),
         TableColumn(title: L("column.dataDir"), minWidth: 70, weight: 2),
         TableColumn(title: L("column.port"), minWidth: 40),
         TableColumn(title: L("column.env"), minWidth: 56),
         TableColumn(title: L("column.service"), minWidth: 56),
         TableColumn(title: L("column.quickStart"), minWidth: 56),
         operationColumn]
    }

    var body: some View {
        ModulePage {
            SegmentedTabs(titles: [L("tab.service"), L("tab.versions"), L("tab.config"), L("tab.logs"), L("rustfs.errorLog")], selection: $tab)
        } content: {
            page
        }
        .sheet(isPresented: $customPathEditor) {
            CustomPathEditor(title: "RustFS", paths: Binding(get: { vm.customDirectories }, set: { vm.setCustomDirectories($0) }))
        }
        .onChange(of: tab) { value in
            if value == 2 { vm.loadConfig() }
            else if value == 3 || value == 4 { vm.loadLog(error: value == 4) }
        }
        .task { await vm.refresh() }
    }

    @ViewBuilder
    private var page: some View {
        switch tab {
        case 1: versionManager
        case 2: configPanel
        case 3, 4: logPanel(error: tab == 4)
        default: serviceTable
        }
    }

    private var serviceTable: some View {
        VStack(spacing: 0) {
            HStack {
                SelectableTitle(text: "RustFS")
                RustFSIcon().frame(width: 22, height: 22)
                Button { customPathEditor = true } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.borderless).help(L("action.customPathHint"))
                Spacer()
                RefreshButton(refreshing: $refreshing, busy: app.state.busy) { await vm.refresh() }
            }
            .panelHeader()
            Divider()
            DataTable(columns: tableColumns, rows: vm.versions,
                      empty: L("message.noDatabaseInstalled") + "RustFS" + L("message.installOrAddPath")) { version in
                Button(version.version) { vm.selected = version.id }.buttonStyle(.borderless)
                Button { NSWorkspace.shared.open(version.directory) } label: {
                    Text(tilde(version.directory.path)).lineLimit(1).truncationMode(.middle)
                }.buttonStyle(.borderless).help(tilde(version.directory.path))
                Button { NSWorkspace.shared.open(vm.dataURL(version)) } label: {
                    Text(vm.dataURL(version).lastPathComponent).foregroundStyle(.secondary)
                }.buttonStyle(.borderless).lineLimit(1).help(tilde(vm.dataURL(version).path))
                Text(vm.port(version))
                EnvironmentVariableButton(membership: vm.pathMembership[version.id] ?? .none) { vm.togglePath(version) }
                    .disabled(app.state.busy)
                ServiceActionButtons(
                    running: vm.running(version),
                    name: "RustFS",
                    toggle: { Task { await vm.operate(vm.running(version) ? "stop" : "start", version) } },
                    restart: { Task { await vm.operate("restart", version) } }
                )
                .disabled(app.state.busy)
                .frame(maxWidth: .infinity, alignment: .leading)
                QuickStartCheckButton(app: app, key: version.id)
                Menu {
                    Button(L("rustfs.openConsole")) { openConsole() }
                    Button(L("rustfs.chooseDataDir")) { chooseDataDir(version) }
                    Button(L("config.openFile")) { tab = 2 }
                    Button(L("tab.logs")) { vm.selected = version.id; tab = 3 }
                    Button(L("rustfs.errorLog")) { vm.selected = version.id; tab = 4 }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
            }
        }
    }

    private func openConsole() {
        NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(vm.consolePort())/")!)
    }

    private func chooseDataDir(_ version: RustFSVersion) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = vm.dataURL(version)
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        vm.setDataURL(url, for: version)
    }

    private var versionManager: some View {
        VStack(alignment: .leading, spacing: 0) {
            VersionManagerHeader(sources: ["Static"], source: $source,
                                 linkURL: URL(string: "https://github.com/rustfs/rustfs")!,
                                 busy: app.state.installBusy, refreshing: refreshing, onRefresh: {
                refreshing = true
                Task {
                    await vm.loadStatic(force: true)
                    await vm.refresh()
                    refreshing = false
                }
            }, actions: {})
            Divider()
            StaticVersionListView(versions: vm.staticVersions, loading: vm.staticLoading, busy: app.state.installBusy) { vm.installStatic($0) } uninstall: { vm.uninstallStatic($0) }
            Spacer()
        }
        .task { await vm.loadStatic() }
    }

    private var configPanel: some View {
        VStack(spacing: 0) {
            CodeEditor(text: $vm.configText, editable: true)
            Divider()
            HStack {
                Button { NSWorkspace.shared.activateFileViewerSelecting([vm.configURL()]) } label: { Image(systemName: "folder") }.help(L("config.openFolder"))
                Button { vm.saveConfig() } label: { Image(systemName: "square.and.arrow.down") }.help(L("action.save"))
                Button { vm.loadConfig() } label: { Image(systemName: "arrow.clockwise") }.help(L("action.reload"))
                Spacer()
                Button(L("action.save")) { vm.saveConfig() }.disabled(app.state.busy)
            }.padding(18)
            Text(L("rustfs.configHint")).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18)
            Text(tilde(vm.configURL().path)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.horizontal, 18).padding(.bottom, 12)
        }
        .onAppear { vm.loadConfig() }
    }

    private func logPanel(error: Bool) -> some View {
        VStack(spacing: 0) {
            CodeEditor(text: $vm.logText, editable: false)
            Divider()
            HStack {
                Button { if let url = vm.logURL(error: error) { NSWorkspace.shared.activateFileViewerSelecting([url]) } } label: { Image(systemName: "folder") }.help(L("log.openFolder"))
                Button { vm.loadLog(error: error) } label: { Image(systemName: "arrow.clockwise") }.help(L("action.refreshLog"))
                Spacer()
                Text(error ? L("rustfs.errorLog") : L("tab.logs")).foregroundStyle(.secondary)
            }.padding(18)
            if let url = vm.logURL(error: error) {
                Text(tilde(url.path)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.horizontal, 18).padding(.bottom, 12)
            }
        }
        .onAppear { vm.loadLog(error: error) }
        .id(tab)
    }
}
