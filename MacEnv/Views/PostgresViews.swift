import SwiftUI

struct PostgresManagementView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var vm: PostgresViewModel
    @State private var tab = 0
    @State private var source = "Homebrew"
    @State private var customPathEditor = false
    @State private var refreshing = false

    // 版本 / 路径 / 数据目录 / 端口 / 环境变量 / 服务 / 快捷启动 / 操作，与 Redis 页完全一致。
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
            SegmentedTabs(titles: [L("tab.service"), L("tab.versions"), L("tab.config"), L("tab.logs")], selection: $tab)
        } content: {
            page
        }
        .sheet(isPresented: $customPathEditor) {
            CustomPathEditor(title: "PostgreSQL", paths: Binding(get: { vm.customDirectories }, set: { vm.setCustomDirectories($0) }))
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
                SelectableTitle(text: "PostgreSQL")
                AssetIcon(name: "PostgresIcon").frame(width: 22, height: 22)
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
                      empty: L("message.noDatabaseInstalled") + "PostgreSQL" + L("message.installOrAddPath")) { version in
                Button(version.version) { vm.selected = version.id }.buttonStyle(.borderless)
                Button { NSWorkspace.shared.open(version.directory) } label: {
                    Text(tilde(version.directory.path)).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.borderless).help(tilde(version.directory.path))
                Button { NSWorkspace.shared.open(vm.dataURL(version)) } label: {
                    Text(vm.dataURL(version).lastPathComponent).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless).lineLimit(1).help(tilde(vm.dataURL(version).path))
                Text(String(vm.port(version)))
                EnvironmentVariableButton(membership: vm.pathMembership[version.id] ?? .none) { vm.togglePath(version) }
                    .disabled(app.state.busy)
                ServiceActionButtons(
                    running: vm.running(version),
                    name: "PostgreSQL",
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
                    Button(L("config.openFile")) { tab = 2; vm.selected = version.id }
                    Button(L("tab.logs")) { vm.selected = version.id; tab = 3 }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
            }
        }
    }

    private var versionManager: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 没有 Static：one-env 的静态包接口对 postgresql 不提供 macOS 二进制，
            // 可装清单走 Homebrew 公式 + MacPorts port。
            VersionManagerHeader(sources: ["Homebrew", "MacPorts"], source: $source,
                                 linkURL: URL(string: "https://www.postgresql.org/download/macos/")!,
                                 busy: app.state.installBusy, refreshing: refreshing, onRefresh: {
                refreshing = true
                Task {
                    if source == "MacPorts" { await vm.loadPortItems(force: true) }
                    await vm.refresh()
                    refreshing = false
                }
            }, actions: {})
            Divider()
            if source == "Homebrew" {
                if vm.formulae.isEmpty {
                    Text(L("brew.noFormulaList")).foregroundStyle(.secondary).padding(24)
                } else {
                    BrewListView(formulae: vm.formulae, busy: app.state.installBusy) { vm.brewAction($0, $1) }
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
            }
            Spacer()
        }
    }

    // PG 的配置就是数据目录里的 postgresql.conf（initdb 生成），这里直接编辑它。
    private var configPanel: some View {
        VStack(spacing: 0) {
            if !vm.versions.isEmpty {
                HStack {
                    Picker(L("column.version"), selection: $vm.selected) {
                        ForEach(vm.versions) { version in Text(version.version).tag(version.id) }
                    }
                    .pickerStyle(.menu)
                    Spacer()
                }
                .padding(.horizontal, 20).frame(height: 52)
                Divider()
            }
            if let version = vm.selectedVersion() {
                CodeEditor(text: $vm.configText, editable: true)
                Divider()
                HStack {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([app.services.postgres.configURL(for: version)]) } label: { Image(systemName: "folder") }.help(L("config.openFolder"))
                    Button { vm.saveConfig() } label: { Image(systemName: "square.and.arrow.down") }.help(L("action.save"))
                    Button { vm.loadConfig() } label: { Image(systemName: "arrow.clockwise") }.help(L("action.reload"))
                    Spacer()
                    Button(L("action.save")) { vm.saveConfig() }.disabled(app.state.busy)
                }.padding(18)
                Text(tilde(app.services.postgres.configURL(for: version).path)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.bottom, 12)
            } else {
                Text(L("message.selectDatabaseVersion") + "PostgreSQL" + L("message.version")).foregroundStyle(.secondary).padding(30)
            }
        }
        .onAppear { vm.loadConfig() }
        .onChange(of: vm.selected) { _ in vm.loadConfig() }
    }

    private var logPanel: some View {
        VStack(spacing: 0) {
            if !vm.versions.isEmpty {
                HStack {
                    Picker(L("column.version"), selection: $vm.selected) {
                        ForEach(vm.versions) { version in Text(version.version).tag(version.id) }
                    }
                    .pickerStyle(.menu)
                    Spacer()
                }
                .padding(.horizontal, 20).frame(height: 52)
                Divider()
            }
            CodeEditor(text: $vm.logText, editable: false)
            Divider()
            HStack {
                Button {
                    if let url = vm.logURL() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                } label: { Image(systemName: "folder") }.help(L("log.openFolder"))
                Button { vm.loadLog() } label: { Image(systemName: "arrow.clockwise") }.help(L("action.refreshLog"))
                Spacer()
                Text(L("tab.logs")).foregroundStyle(.secondary)
            }.padding(18)
            if let url = vm.logURL() {
                Text(tilde(url.path)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.horizontal, 18).padding(.bottom, 12)
            }
        }
        .onAppear { vm.loadLog() }
        .onChange(of: vm.selected) { _ in vm.loadLog() }
    }
}
