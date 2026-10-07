import SwiftUI

// Go 是一等语言模块（FlyEnv 里跟 PHP / Node 同级），所以自己占一个页面而不是挂在 PHP 下面。
// 两个 tab：已安装（含环境变量开关）、版本管理（静态包 / Homebrew / MacPorts / GVM）。
// GVM 的**本体**（装 / 卸 / 路径）在环境工具页，这里只把「用 GVM 装的 Go」当一个来源。
struct GoManagementView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var vm: GoViewModel
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
        // GVM 装没装要现问文件系统，切到那个来源再问 —— 上面那个「进 Go 页就 checkGvm」
        // 的 onChange 随 GVM 面板一起搬走了，不补回来的话装了 GVM 也显示「未检测到」。
        .onChange(of: source) { value in if value == "GVM" { vm.checkGvm() } }
        .sheet(isPresented: $customPathEditor) { CustomPathEditor(title: "Go", paths: $vm.customDirectories) }
        .alert(L("alert.uninstallGoTitle"), isPresented: $confirmUninstall) {
            Button(L("action.cancel"), role: .cancel) { uninstallFormula = nil }
            Button(L("action.uninstall"), role: .destructive) {
                if let formula = uninstallFormula { vm.brewAction("uninstall", formula: formula) }
                uninstallFormula = nil
            }
        } message: { Text(String(format: L("alert.uninstallGoMessage"), uninstallFormula ?? "")) }
    }

    @ViewBuilder
    private var page: some View {
        switch tab {
        case 1: versionManager
        default: installedTable
        }
    }

    // MARK: - 版本管理

    // 四个来源跟其他页面的分法一致：Static（我们自己下的官方包）、Homebrew、MacPorts、
    // GVM。后三个交给第三方工具，我们只负责显示和调它。GVM 没装时给一句指路，
    // 不丢一张空表过来。
    private var versionManager: some View {
        VStack(alignment: .leading, spacing: 0) {
            VersionManagerHeader(sources: ["Static", "Homebrew", "MacPorts", "GVM"], source: $source,
                                 linkURL: URL(string: "https://go.dev/dl/")!,
                                 busy: app.state.busy, refreshing: refreshing, onRefresh: {
                refreshing = true
                Task { await vm.refreshVersionManager(source, force: true); refreshing = false }
            }, actions: {})
            Divider()
            if source == "Homebrew" {
                if vm.formulae.isEmpty {
                    Text(L("brew.missing")).padding(24)
                    Link(L("brew.install"), destination: URL(string: "https://brew.sh")!).padding(.horizontal, 24)
                } else {
                    BrewListView(formulae: vm.formulae, busy: app.state.busy) { action, formula in
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
                    PortListView(items: vm.portItems, loading: vm.portLoading, busy: app.state.busy,
                                 load: { await vm.loadPortItems() },
                                 install: { vm.portAction("install", $0) },
                                 uninstall: { vm.portAction("uninstall", $0) })
                } else {
                    Text(L("tools.missingMacPorts")).padding(24)
                }
            } else if source == "GVM" {
                if vm.gvmInstalled == true {
                    GvmVersionTable(vm: vm)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L("tools.missingGvm"))
                    }.padding(24)
                }
            } else {
                StaticVersionListView(versions: vm.staticVersions, loading: vm.staticLoading) { vm.installStatic($0) } uninstall: { vm.uninstallStatic($0) }
            }
            Spacer()
        }
    }

    // MARK: - 已安装

    // 版本 / GOROOT / 来源 / 环境变量。宽度交给 DataTable 按容器反推。
    private var tableColumns: [TableColumn] {
        [TableColumn(title: L("column.version"), minWidth: 60),
         TableColumn(title: "GOROOT", minWidth: 140, weight: 1),
         TableColumn(title: L("column.source"), minWidth: 90),
         TableColumn(title: L("column.env"), minWidth: 56)]
    }

    private var installedTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Go").font(.title3)
                GoIcon().frame(width: 22, height: 22)
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
            DataTable(columns: tableColumns, rows: vm.versions, empty: L("message.noGoInstalled")) { version in
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
