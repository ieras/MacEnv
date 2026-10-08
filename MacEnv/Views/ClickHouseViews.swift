import SwiftUI

struct ClickHouseManagementView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var vm: ClickHouseViewModel
    @State private var tab = 0
    @State private var source = "Static"
    @State private var customPathEditor = false
    @State private var refreshing = false

    // 端口列比其它数据库宽：ClickHouse 同时开 HTTP 8123 和原生 9000，两个都要显示。
    // 80 的由来同 Consul：「8123 / 9000」实测 73.6pt，原来的 68pt 一直是被截断的。
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
            CustomPathEditor(title: "ClickHouse", paths: Binding(get: { vm.customDirectories }, set: { vm.setCustomDirectories($0) }))
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
                SelectableTitle(text: "ClickHouse")
                AssetIcon(name: "ClickHouseIcon").frame(width: 22, height: 22)
                Button { customPathEditor = true } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.borderless)
                    .help(L("action.customPathHint"))
                Spacer()
                Button {
                    refreshing = true
                    Task { await vm.refresh(); refreshing = false }
                } label: { Image(systemName: "arrow.clockwise") }
                .help(L("action.refreshVersions"))
                .disabled(app.state.busy || refreshing)
            }
            .panelHeader()
            Divider()
            DataTable(columns: tableColumns, rows: vm.versions,
                      empty: L("message.noDatabaseInstalled") + "ClickHouse" + L("message.installOrAddPath")) { version in
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
                    name: "ClickHouse",
                    toggle: { Task { await vm.operate(vm.running(version) ? "stop" : "start", version) } },
                    restart: { Task { await vm.operate("restart", version) } }
                )
                .disabled(app.state.busy)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    app.setQuickStart(version.id, enabled: !app.state.quickStartTargets.contains(version.id))
                } label: {
                    Image(systemName: app.state.quickStartTargets.contains(version.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(app.state.quickStartTargets.contains(version.id) ? .blue : .secondary)
                }
                .buttonStyle(.borderless).help(L("action.quickStartHint"))
                Menu {
                    Button(L("config.openFile")) { vm.selectedID = version.id; tab = 2 }
                    Button(L("tab.logs")) { vm.selectedID = version.id; tab = 3 }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
            }
        }
    }

    private var versionManager: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 只有一个来源：官方只发 cask（brew 公式接口查不到）、MacPorts 没有 port，
            // 能装的只有 one-env 的静态包。
            VersionManagerHeader(sources: ["Static"], source: $source,
                                 linkURL: URL(string: "https://clickhouse.com/docs/install")!,
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

    // config.xml 和 users.xml 都是 MacEnv 生成的，两个都可编辑 —— 前者管端口/目录，
    // 后者管用户（root / root）。
    private var configPanel: some View {
        VStack(spacing: 0) {
            HStack {
                SegmentedTabs(items: [("config.xml", "config.xml"), ("users.xml", "users.xml")], selection: $vm.configTarget)
                    .frame(width: 240)
                Spacer()
            }
            .padding(.horizontal, 20).frame(height: 52)
            Divider()
            CodeEditor(text: $vm.configText, editable: true)
            Divider()
            HStack {
                Button { NSWorkspace.shared.activateFileViewerSelecting([vm.configURL()]) } label: { Image(systemName: "folder") }.help(L("config.openFolder"))
                Button { vm.saveConfig() } label: { Image(systemName: "square.and.arrow.down") }.help(L("action.save"))
                Button { vm.loadConfig() } label: { Image(systemName: "arrow.clockwise") }.help(L("action.reload"))
                Spacer()
                Button(L("action.save")) { vm.saveConfig() }.disabled(app.state.busy)
            }.padding(18)
            Text(tilde(vm.configURL().path)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.bottom, 12)
        }
        .onAppear { vm.loadConfig() }
        .onChange(of: vm.configTarget) { _ in vm.loadConfig() }
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
}
