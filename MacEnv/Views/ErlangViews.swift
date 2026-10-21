import SwiftUI

// Erlang 页面：两个 tab —— 已安装（含环境变量开关）、版本管理（Homebrew / MacPorts）。
// 没有静态包栏：官方 macOS 没有预编译发行版，装 Erlang 只有 brew / MacPorts / kerl 三条路，
// 前两个交给第三方工具，我们只负责显示和调它；kerl 是用户自己的目录，扫进来即可。
struct ErlangManagementView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var vm: ErlangViewModel
    @State private var tab = 0
    @State private var source = "Homebrew"
    @State private var customPathEditor = false
    @State private var refreshing = false
    @State private var confirmUninstall = false
    // 卸载必须记住点的是哪一行，不能在 alert 里写死公式名（同 Go 页面）。
    @State private var uninstallFormula: String?

    var body: some View {
        ModulePage {
            SegmentedTabs(titles: [L("tab.installed"), L("tab.versions")], selection: $tab)
        } content: {
            page
        }
        .sheet(isPresented: $customPathEditor) { CustomPathEditor(title: "Erlang", paths: $vm.customDirectories) }
        .alert(L("alert.uninstallErlangTitle"), isPresented: $confirmUninstall) {
            Button(L("action.cancel"), role: .cancel) { uninstallFormula = nil }
            Button(L("action.uninstall"), role: .destructive) {
                if let formula = uninstallFormula { vm.brewAction("uninstall", formula: formula) }
                uninstallFormula = nil
            }
        } message: { Text(String(format: L("alert.uninstallErlangMessage"), uninstallFormula ?? "")) }
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
            VersionManagerHeader(sources: ["Homebrew", "MacPorts"], source: $source,
                                 linkURL: URL(string: "https://www.erlang.org/downloads")!,
                                 busy: app.state.installBusy, refreshing: refreshing, onRefresh: {
                refreshing = true
                Task { await vm.refreshVersionManager(source, force: true); refreshing = false }
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
                if vm.formulae.isEmpty {
                    Text(L("brew.missing")).padding(24)
                    Link(L("brew.install"), destination: URL(string: "https://brew.sh")!).padding(.horizontal, 24)
                } else {
                    BrewListView(formulae: vm.formulae, busy: app.state.installBusy) { action, formula in
                        // 卸载要过确认弹窗，记住点的是哪一行 —— alert 里不能写死公式名。
                        if action == "uninstall" {
                            uninstallFormula = formula
                            confirmUninstall = true
                        } else {
                            vm.brewAction(action, formula: formula)
                        }
                    }
                }
            }
            Spacer()
        }
    }

    // MARK: - 已安装

    // 版本 / ERL_ROOT / 来源 / 环境变量。宽度交给 DataTable 按容器反推。
    private var tableColumns: [TableColumn] {
        [TableColumn(title: L("column.version"), minWidth: 60),
         TableColumn(title: "ERL_ROOT", minWidth: 140, weight: 1),
         TableColumn(title: L("column.source"), minWidth: 90),
         TableColumn(title: L("column.env"), minWidth: 56)]
    }

    private var installedTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SelectableTitle(text: "Erlang")
                ErlangIcon().frame(width: 22, height: 22)
                Button { customPathEditor = true } label: { Image(systemName: "folder.badge.plus") }
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
            DataTable(columns: tableColumns, rows: vm.versions, empty: L("message.noErlangInstalled")) { version in
                Text(version.version)
                Button { NSWorkspace.shared.open(version.directory) } label: {
                    Text(tilde(version.directory.path)).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.borderless).help(tilde(version.directory.path))
                Text(version.source)
                EnvironmentVariableButton(membership: vm.pathMembership[version.id, default: .none]) { vm.togglePath(version) }
                    .disabled(app.state.busy)
            }
        }
    }
}
