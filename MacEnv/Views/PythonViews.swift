import SwiftUI

// Python 是一等语言模块（FlyEnv 里跟 PHP / Go 同级），自己占一个页面。
// 两个 tab：已安装（含环境变量开关）、版本管理（静态包 / Homebrew / MacPorts）。
// 没有 pyenv 那一栏：FlyEnv 自己也没有，而 pyenv 装 Python 是从源码编译，
// GUI 里几分钟没进度、失败率高，不值得为对齐 Go 的 GVM 位置硬凑一个。
struct PythonManagementView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var vm: PythonViewModel
    @State private var tab = 0
    @State private var source = "Static"
    @State private var customPathEditor = false
    @State private var refreshing = false
    @State private var confirmUninstall = false
    // 卸载必须记住点的是哪一行，不能在 alert 里写死公式名 —— PHP 页面就栽过这个跟头。
    @State private var uninstallFormula: String?

    var body: some View {
        ModulePage {
            SegmentedTabs(titles: [L("tab.installed"), L("tab.versions")], selection: $tab)
        } content: {
            page
        }
        .task { await vm.loadStatic() }
        .sheet(isPresented: $customPathEditor) { CustomPathEditor(title: "Python", paths: $vm.customDirectories) }
        .alert(L("alert.uninstallPythonTitle"), isPresented: $confirmUninstall) {
            Button(L("action.cancel"), role: .cancel) { uninstallFormula = nil }
            Button(L("action.uninstall"), role: .destructive) {
                if let formula = uninstallFormula { vm.brewAction("uninstall", formula: formula) }
                uninstallFormula = nil
            }
        } message: { Text(String(format: L("alert.uninstallPythonMessage"), uninstallFormula ?? "")) }
    }

    @ViewBuilder
    private var page: some View {
        switch tab {
        case 1: versionManager
        default: installedTable
        }
    }

    // MARK: - 版本管理

    // 三个来源：Static 走 python-build-standalone（one-env 对 python 只给空数组），
    // 后两个交给第三方工具，我们只负责显示和调它。
    private var versionManager: some View {
        VStack(alignment: .leading, spacing: 0) {
            VersionManagerHeader(sources: ["Static", "Homebrew", "MacPorts"], source: $source,
                                 linkURL: URL(string: "https://www.python.org/downloads/")!,
                                 busy: app.state.installBusy, refreshing: refreshing, onRefresh: {
                refreshing = true
                Task { await vm.refreshVersionManager(source, force: true); refreshing = false }
            }, actions: {})
            Divider()
            if source == "Homebrew" {
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
            } else if source == "MacPorts" {
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
    }

    // MARK: - 已安装

    // 版本 / Python Home / 来源 / 环境变量。宽度交给 DataTable 按容器反推。
    private var tableColumns: [TableColumn] {
        [TableColumn(title: L("column.version"), minWidth: 60),
         TableColumn(title: "Python Home", minWidth: 140, weight: 1),
         TableColumn(title: L("column.source"), minWidth: 90),
         TableColumn(title: L("column.env"), minWidth: 56)]
    }

    private var installedTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SelectableTitle(text: "Python")
                AssetIcon(name: "PythonIcon").frame(width: 22, height: 22)
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
            DataTable(columns: tableColumns, rows: vm.versions, empty: L("message.noPythonInstalled")) { version in
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
