import SwiftUI

// etcd 页：跟 Consul 同一个骨架 —— 服务 / 版本管理 / 配置 / 日志 四个 tab。
// 少两样东西：没有顶栏的「打开 Web UI」（etcd 官方不带控制台，etcdkeeper 那类是第三方），
// 版本管理页也没有 MacPorts 一栏（`port search '^etcd$'` 是 No match）。
struct EtcdManagementView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var vm: EtcdViewModel
    @State private var tab = 0
    @State private var source = "Homebrew"
    @State private var customPathEditor = false
    @State private var refreshing = false

    // 端口列要放下两个端口：客户端 2379 和 peer 2380。宽度取 80，跟 Consul / ClickHouse 一致
    // （「2379 / 2380」跟「8500 / 8600」同宽，实测 76.1pt，68 会截成「2379 / 23…」）。
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
            CustomPathEditor(title: "etcd", paths: Binding(get: { vm.customDirectories }, set: { vm.setCustomDirectories($0) }))
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
                SelectableTitle(text: "etcd")
                AssetIcon(name: "EtcdIcon").frame(width: 22, height: 22)
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
                      empty: L("message.noDatabaseInstalled") + "etcd" + L("message.installOrAddPath")) { version in
                Button(version.version) { vm.selected = version.id }.buttonStyle(.borderless)
                Button { NSWorkspace.shared.open(version.directory) } label: {
                    Text(tilde(version.directory.path)).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.borderless).help(tilde(version.directory.path))
                Button { NSWorkspace.shared.open(vm.dataURL(version)) } label: {
                    Text(vm.dataURL(version).lastPathComponent).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless).lineLimit(1).help(tilde(vm.dataURL(version).path))
                Text(vm.port(version))
                EnvironmentVariableButton(membership: vm.pathMembership[version.id] ?? .none) { vm.togglePath(version) }
                    .disabled(app.state.busy)
                ServiceActionButtons(
                    running: vm.running(version),
                    name: "etcd",
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
                    Button(L("config.openFile")) { vm.selected = version.id; tab = 2 }
                    Button(L("tab.logs")) { vm.selected = version.id; tab = 3 }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
            }
        }
    }

    private var versionManager: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 两个来源：Homebrew 的 etcd 公式（homebrew/core 有正式公式，bottled）和
            // one-env 给的官方 GitHub release zip（Static）。没有 MacPorts。
            VersionManagerHeader(sources: ["Homebrew", "Static"], source: $source,
                                 linkURL: URL(string: "https://etcd.io")!,
                                 busy: app.state.installBusy, refreshing: refreshing, onRefresh: {
                refreshing = true
                Task {
                    if source == "Static" { await vm.loadStatic(force: true) }
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
            } else {
                StaticVersionListView(versions: vm.staticVersions, loading: vm.staticLoading, busy: app.state.installBusy) { vm.installStatic($0) } uninstall: { vm.uninstallStatic($0) }
            }
            Spacer()
        }
        .task { await vm.loadStatic() }
    }

    // 配置是 YAML（每主版本一份），MacEnv 生成：节点名 / 数据目录 / 监听地址 / initial-cluster /
    // 日志级别与落点，全在里面，命令行上只传 --config-file。
    @ViewBuilder
    private var configPanel: some View {
        if let url = vm.configURL() {
            VStack(spacing: 0) {
                CodeEditor(text: $vm.configText, editable: true)
                Divider()
                HStack {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }.help(L("config.openFolder"))
                    Button { vm.saveConfig() } label: { Image(systemName: "square.and.arrow.down") }.help(L("action.save"))
                    Button { vm.loadConfig() } label: { Image(systemName: "arrow.clockwise") }.help(L("action.reload"))
                    Spacer()
                    Button(L("action.save")) { vm.saveConfig() }.disabled(app.state.busy)
                }.padding(18)
                Text(tilde(url.path)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.bottom, 12)
            }
            .onAppear { vm.loadConfig() }
        } else {
            // 没有装任何版本时配置还没有落点（配置按主版本命名，装完才写）。
            Text(L("message.noDatabaseInstalled") + "etcd" + L("message.installOrAddPath"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
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
