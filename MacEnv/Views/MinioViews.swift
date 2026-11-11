import SwiftUI
import AppKit

struct MinioManagementView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var vm: MinioViewModel
    @State private var tab = 0
    @State private var source = "Static"
    @State private var customPathEditor = false
    @State private var refreshing = false

    private var tableColumns: [TableColumn] {
        [TableColumn(title: L("column.version"), minWidth: 50),
         TableColumn(title: L("column.path"), minWidth: 120, weight: 6),
         TableColumn(title: L("column.dataDir"), minWidth: 70, weight: 2),
         TableColumn(title: L("column.port"), minWidth: 80),
         TableColumn(title: L("column.env"), minWidth: 56),
         TableColumn(title: L("column.service"), minWidth: 56),
         TableColumn(title: L("column.quickStart"), minWidth: 56),
         operationColumn]
    }

    var body: some View {
        ModulePage {
            SegmentedTabs(titles: [L("tab.service"), L("tab.versions"), L("tab.config"), L("tab.logs")], selection: $tab)
        } content: {
            page
        }
        .sheet(isPresented: $customPathEditor) {
            CustomPathEditor(title: "MinIO", paths: Binding(get: { vm.customDirectories }, set: { vm.setCustomDirectories($0) }))
        }
        .onChange(of: tab) { value in
            if value == 2 { vm.loadConfig() }
            else if value == 3 { vm.loadLog() }
        }
        .task {
            await vm.refresh()
        }
    }

    @ViewBuilder
    private var page: some View {
        switch tab {
        case 1: versionManager
        case 2: configPanel
        case 3: logPanel
        default: serviceTable
        }
    }

    private var serviceTable: some View {
        VStack(spacing: 0) {
            HStack {
                SelectableTitle(text: "MinIO")
                MinioIcon().frame(width: 22, height: 22)
                Button { customPathEditor = true } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.borderless)
                    .help(L("action.customPathHint"))
                Spacer()
                RefreshButton(refreshing: $refreshing, busy: app.state.busy) { await vm.refresh() }
            }
            .panelHeader()
            Divider()
            DataTable(columns: tableColumns, rows: vm.versions,
                      empty: L("message.noDatabaseInstalled") + "MinIO" + L("message.installOrAddPath")) { version in
                Button(version.version) { vm.selectedID = version.id }.buttonStyle(.borderless)
                Button { NSWorkspace.shared.open(version.directory) } label: {
                    Text(tilde(version.directory.path)).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.borderless).help(tilde(version.directory.path))
                Button { NSWorkspace.shared.open(vm.dataURL()) } label: {
                    Text(vm.dataURL().lastPathComponent).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless).lineLimit(1).help(tilde(vm.dataURL().path))
                Text(vm.port(version))
                EnvironmentVariableButton(membership: vm.pathMembership[version.id] ?? .none) { vm.togglePath(version) }
                    .disabled(app.state.busy)
                ServiceActionButtons(
                    running: vm.running(version),
                    name: "MinIO",
                    toggle: { Task { await vm.operate(vm.running(version) ? "stop" : "start", version) } },
                    restart: { Task { await vm.operate("restart", version) } }
                )
                .disabled(app.state.busy)
                .frame(maxWidth: .infinity, alignment: .leading)
                QuickStartCheckButton(app: app, key: version.id)
                Menu {
                    Button(L("minio.openConsole")) { NSWorkspace.shared.open(vm.consoleURL) }
                    Button(L("config.openFile")) { vm.selectedID = version.id; tab = 2 }
                    Button(L("tab.logs")) { vm.selectedID = version.id; tab = 3 }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
            }
        }
    }

    private var versionManager: some View {
        VStack(alignment: .leading, spacing: 0) {
            VersionManagerHeader(sources: ["Static"], source: $source,
                                 linkURL: URL(string: "https://github.com/minio/minio")!,
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
                Button(L("minio.chooseDataDir")) { chooseDataDirectory() }.disabled(app.state.busy)
                Button(L("action.save")) { vm.saveConfig() }.disabled(app.state.busy)
            }.padding(18)
            VStack(alignment: .leading, spacing: 4) {
                Text(tilde(vm.configURL().path)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(L("column.dataDir") + ": " + tilde(vm.dataURL().path))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 12)
        }
        .onAppear { vm.loadConfig() }
    }

    private var logPanel: some View {
        VStack(spacing: 0) {
            CodeEditor(text: $vm.logText, editable: false)
            Divider()
            HStack {
                Button { NSWorkspace.shared.activateFileViewerSelecting([vm.logURL()]) } label: { Image(systemName: "folder") }.help(L("log.openFolder"))
                Button { vm.loadLog() } label: { Image(systemName: "arrow.clockwise") }.help(L("action.refreshLog"))
                Spacer()
                Text(L("tab.logs")).foregroundStyle(.secondary)
            }.padding(18)
            Text(tilde(vm.logURL().path)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.horizontal, 18).padding(.bottom, 12)
        }
        .onAppear { vm.loadLog() }
    }

    private func chooseDataDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = vm.dataURL()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vm.setDataDirectory(url)
    }
}
