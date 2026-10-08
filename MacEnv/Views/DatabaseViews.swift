import SwiftUI

struct DatabaseManagementView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var vm: DatabaseViewModel
    let kind: DatabaseKind
    @State private var tab = 1
    @State private var source = "Homebrew"
    @State private var customPathEditor = false
    @State private var refreshing = false

    // 版本 / 路径 / 数据目录 / 端口 / 环境变量 / 服务 / 快捷启动 / 操作。
    // 宽度交给 DataTable 按容器反推：路径列权重最大，四字表头（环境变量、快捷启动）靠 minWidth 兜底。
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

    private var versions: [DatabaseVersion] { vm.versions[kind] ?? [] }

    var body: some View {
        ModulePage {
            SegmentedTabs(
                titles: [L("tab.service"), L("tab.versions"), L("tab.config"), L("tab.errorLog"), L("tab.slowLog")],
                selection: $tab
            )
        } content: {
            page
        }
        .sheet(isPresented: $customPathEditor) {
            CustomPathEditor(title: kind.title, paths: Binding(get: { vm.customDirectories[kind, default: []] }, set: { vm.setCustomDirectories($0, for: kind) }))
        }
        .onChange(of: tab) { value in
            if value == 2 { vm.loadConfig(kind) }
            else if value == 3 { vm.loadLog(kind, "error") }
            else if value == 4 { vm.loadLog(kind, "slow") }
        }
        .task {
            await vm.refresh(kind)
            await vm.loadStatic(kind)
        }
    }

    @ViewBuilder
    private var page: some View {
        switch tab {
        case 1: versionManager
        case 2: configPanel
        case 3, 4: logPanel
        default: serviceTable
        }
    }

    private var serviceTable: some View {
        VStack(spacing: 0) {
            HStack {
                SelectableTitle(text: kind.title)
                DatabaseIcon(kind: kind).frame(width: 22, height: 22)
                Button { customPathEditor = true } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.borderless)
                    .help(L("action.customPathHint"))
                Spacer()
                Button {
                    refreshing = true
                    Task { await vm.refresh(kind); refreshing = false }
                } label: { Image(systemName: "arrow.clockwise") }
                .help(L("action.refreshVersions"))
                .disabled(app.state.busy || refreshing)
            }
            .panelHeader()
            Divider()
            DataTable(columns: tableColumns, rows: versions,
                      empty: L("message.noDatabaseInstalled") + kind.title + L("message.installOrAddPath")) { version in
                Button(version.version) { vm.selected[kind] = version.id }.buttonStyle(.borderless)
                Button { NSWorkspace.shared.open(version.directory) } label: {
                    Text(tilde(version.directory.path)).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.borderless).help(tilde(version.directory.path))
                Button { NSWorkspace.shared.open(vm.dataURL(kind, version)) } label: {
                    Text(vm.dataURL(kind, version).lastPathComponent).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless).lineLimit(1).help(tilde(vm.dataURL(kind, version).path))
                Text(String(vm.port(version)))
                EnvironmentVariableButton(membership: vm.pathMembership[kind]?[version.id] ?? .none) { vm.togglePath(version) }
                    .disabled(app.state.busy)
                ServiceActionButtons(
                    running: vm.running(version),
                    name: kind.title,
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
                    Button(L("config.openFile")) { tab = 2; vm.selected[kind] = version.id }
                    Button(L("tab.errorLog")) { vm.selected[kind] = version.id; tab = 3 }
                    Button(L("tab.slowLog")) { vm.selected[kind] = version.id; tab = 4 }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
            }
        }
    }

    private var versionManager: some View {
        // MariaDB 没有 Static：one-env 的静态包接口对它返回空数组。
        let sources = kind == .mysql ? ["Static", "Homebrew", "MacPorts"] : ["Homebrew", "MacPorts"]
        return VStack(alignment: .leading, spacing: 0) {
            VersionManagerHeader(sources: sources, source: $source,
                                 linkURL: URL(string: kind == .mysql ? "https://dev.mysql.com/downloads/" : "https://mariadb.org/download/")!,
                                 busy: app.state.installBusy, refreshing: refreshing, onRefresh: {
                refreshing = true
                Task { await vm.refreshVersionManager(kind, source, force: true); refreshing = false }
            }, actions: {})
            Divider()
            if source == "Homebrew" {
                if vm.formulae[kind, default: []].isEmpty {
                    Text(L("brew.noFormulaList")).foregroundStyle(.secondary).padding(24)
                } else {
                    BrewListView(formulae: vm.formulae[kind, default: []], busy: app.state.installBusy) { vm.brewAction($0, kind, $1) }
                }
            } else if source == "Static" {
                StaticVersionListView(versions: vm.staticVersions[kind, default: []], busy: app.state.installBusy) { vm.installStatic($0, kind) } uninstall: { vm.uninstallStatic($0, kind) }
            } else if source == "MacPorts" {
                if app.toolsVM.macPortsInstalled {
                    PortListView(items: vm.portItems[kind, default: []], loading: vm.portLoading, busy: app.state.installBusy,
                                 load: { await vm.loadPortItems(kind) },
                                 install: { vm.portAction("install", kind, $0) },
                                 uninstall: { vm.portAction("uninstall", kind, $0) })
                } else {
                    Text(L("tools.missingMacPorts")).padding(24)
                }
            }
            Spacer()
        }
    }

    private var configPanel: some View {
        VStack(spacing: 0) {
            if !(vm.versions[kind] ?? []).isEmpty {
                HStack {
                    Picker(L("column.version"), selection: Binding(
                        get: { vm.selected[kind] ?? (vm.versions[kind]?.first?.id ?? "") },
                        set: { vm.selected[kind] = $0 }
                    )) {
                        ForEach(vm.versions[kind] ?? []) { version in
                            Text(version.version).tag(version.id)
                        }
                    }
                    .pickerStyle(.menu)
                    Spacer()
                }
                .padding(.horizontal, 20).frame(height: 52)
                Divider()
            }
            if let version = vm.selectedVersion(kind) {
                CodeEditor(text: $vm.configText, editable: true)
                Divider()
                HStack {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([vm.configURL(kind, version)]) } label: { Image(systemName: "folder") }.help(L("config.openFolder"))
                    Button { vm.saveConfig(kind) } label: { Image(systemName: "square.and.arrow.down") }.help(L("action.save"))
                    Button { vm.loadConfig(kind) } label: { Image(systemName: "arrow.clockwise") }.help(L("action.reload"))
                    Spacer()
                    Button(L("action.save")) { vm.saveConfig(kind) }.disabled(app.state.busy)
                }.padding(18)
                Text(tilde(vm.configURL(kind, version).path)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.bottom, 12)
            } else {
                Text(L("message.selectDatabaseVersion") + kind.title + L("message.version")).foregroundStyle(.secondary).padding(30)
            }
        }
        .onAppear { vm.loadConfig(kind) }
        .onChange(of: vm.selected[kind]) { _ in vm.loadConfig(kind) }
    }

    private var logPanel: some View {
        VStack(spacing: 0) {
            if !(vm.versions[kind] ?? []).isEmpty {
                HStack {
                    Picker(L("column.version"), selection: Binding(
                        get: { vm.selected[kind] ?? (vm.versions[kind]?.first?.id ?? "") },
                        set: { vm.selected[kind] = $0 }
                    )) {
                        ForEach(vm.versions[kind] ?? []) { version in
                            Text(version.version).tag(version.id)
                        }
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
                    if let url = tab == 3 ? vm.errorLogURL(kind) : vm.slowLogURL(kind) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: { Image(systemName: "folder") }.help(L("log.openFolder"))
                Button { vm.loadLog(kind, tab == 3 ? "error" : "slow") } label: { Image(systemName: "arrow.clockwise") }.help(L("action.refreshLog"))
                Spacer()
                Text(tab == 3 ? L("tab.errorLog") : L("tab.slowLog")).foregroundStyle(.secondary)
            }.padding(18)
            if let url = tab == 3 ? vm.errorLogURL(kind) : vm.slowLogURL(kind) {
                Text(tilde(url.path)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.horizontal, 18).padding(.bottom, 12)
            }
        }
        .onAppear { vm.loadLog(kind, tab == 3 ? "error" : "slow") }
        .onChange(of: vm.selected[kind]) { _ in vm.loadLog(kind, tab == 3 ? "error" : "slow") }
    }
}
