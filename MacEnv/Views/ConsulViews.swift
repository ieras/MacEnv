import SwiftUI

// Consul 页：跟其它数据库页同一个骨架 —— 服务 / 版本管理 / 配置 / 日志 四个 tab。
// 唯一的额外东西是顶栏那个「打开 Web UI」：Consul 自带控制台（:8500/ui），
// 这是它跟 MySQL / Redis 这类纯服务最不一样的地方。
struct ConsulManagementView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var vm: ConsulViewModel
    @State private var tab = 0
    @State private var source = "Static"
    @State private var customPathEditor = false
    @State private var refreshing = false

    // 端口列跟 ClickHouse 一样要放下两个端口：HTTP/UI 8500 和 DNS 8600。
    // 80 不是拍脑袋来的：「8500 / 8600」在 13pt 系统字体下实测 76.1pt，68pt 会截成「8500 / 86…」。
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
            CustomPathEditor(title: "Consul", paths: Binding(get: { vm.customDirectories }, set: { vm.setCustomDirectories($0) }))
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
                SelectableTitle(text: "Consul")
                AssetIcon(name: "ConsulIcon").frame(width: 22, height: 22)
                Button { customPathEditor = true } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.borderless)
                    .help(L("action.customPathHint"))
                Spacer()
                // 自带控制台，只在真的有版本可跑的时候给按钮（否则点开是 404）。
                if let version = vm.selectedVersion {
                    Button { vm.openWebUI(version) } label: { Image(systemName: "safari") }
                        .buttonStyle(.borderless)
                        .help(L("action.openWebUI") + "（\(vm.port(version))）")
                        .disabled(app.state.busy)
                }
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
                      empty: L("message.noDatabaseInstalled") + "Consul" + L("message.installOrAddPath")) { version in
                Button(version.version) { vm.selectedID = version.id }.buttonStyle(.borderless)
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
                    name: "Consul",
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
                    Button(L("action.openWebUI")) { vm.openWebUI(version) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
            }
        }
    }

    private var versionManager: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 两个来源：one-env 的官方 zip（Static）、MacPorts 的 consul 端口。
            // 没有 Homebrew 一栏 —— consul 在 homebrew/core 里没有公式，官方只发 cask 和
            // hashicorp/tap，而本机那个 tap 未信任，brew 直接拒绝加载。
            VersionManagerHeader(sources: ["Static", "MacPorts"], source: $source,
                                 linkURL: URL(string: "https://developer.hashicorp.com/consul")!,
                                 busy: app.state.installBusy, refreshing: refreshing, onRefresh: {
                refreshing = true
                Task {
                    if source == "MacPorts" { await vm.loadPortItems(force: true) }
                    else { await vm.loadStatic(force: true) }
                    await vm.refresh()
                    refreshing = false
                }
            }, actions: {})
            Divider()
            if source == "MacPorts" {
                if app.toolsVM.macPortsInstalled {
                    PortListView(items: vm.portItems, loading: vm.portLoading, busy: app.state.installBusy,
                                 load: { await vm.loadPortItems() },
                                 install: { vm.portAction("install", $0) },
                                 uninstall: { vm.portAction("uninstall", $0) })
                } else {
                    Text(L("tools.missingMacPorts")).padding(24)
                }
            } else {
                StaticVersionListView(versions: vm.staticVersions, loading: vm.staticLoading, busy: app.state.installBusy) { vm.installStatic($0) } uninstall: { vm.uninstallStatic($0) }
            }
            Spacer()
        }
        .task { await vm.loadStatic() }
    }

    // 配置只有一份（按主版本分），MacEnv 生成的 JSON：server / bootstrap_expect / 节点名 /
    // 监听地址 / 数据目录 / 日志 / UI 开关 / 端口，全在里面，命令行上不再传任何配置参数。
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
            Text(L("message.noDatabaseInstalled") + "Consul" + L("message.installOrAddPath"))
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
