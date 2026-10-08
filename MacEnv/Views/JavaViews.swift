import SwiftUI

// Java 跟 Go 同构（FlyEnv 里也是一等语言模块）：没有常驻进程，所以两个 tab ——
// 已安装（含环境变量开关）、版本管理（Static / Homebrew / MacPorts / SDKMAN）。
// SDKMAN 的**本体**在环境工具页，这里只把「用 SDKMAN 装的 JDK」当一个来源。
struct JavaManagementView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var vm: JavaViewModel
    @State private var tab = 0
    @State private var source = "Static"
    @State private var customPathEditor = false
    @State private var refreshing = false
    @State private var confirmUninstall = false
    @State private var confirmSdkmanUninstall = false
    // 卸载必须记住点的是哪一行，不能在 alert 里写死名字 —— PHP 页面就栽过这个跟头。
    @State private var uninstallFormula: String?
    @State private var uninstallSdkman: SdkmanVersion?

    var body: some View {
        ModulePage {
            SegmentedTabs(titles: [L("tab.installed"), L("tab.versions"), L("module.maven"), L("module.gradle")], selection: $tab)
        } content: {
            page
        }
        .task { await vm.loadStatic() }
        // SDKMAN 的列表要打网络，切到那一栏再拉，别在进页面时就等它。
        .onChange(of: source) { value in if value == "SDKMAN" { Task { await vm.loadSdkman() } } }
        .sheet(isPresented: $customPathEditor) { CustomPathEditor(title: "Java", paths: $vm.customDirectories) }
        .alert(L("alert.uninstallJavaTitle"), isPresented: $confirmUninstall) {
            Button(L("action.cancel"), role: .cancel) { uninstallFormula = nil }
            Button(L("action.uninstall"), role: .destructive) {
                if let formula = uninstallFormula { vm.brewAction("uninstall", formula: formula) }
                uninstallFormula = nil
            }
        } message: { Text(String(format: L("alert.uninstallJavaMessage"), uninstallFormula ?? "")) }
        .alert(L("alert.uninstallSdkmanJavaTitle"), isPresented: $confirmSdkmanUninstall) {
            Button(L("action.cancel"), role: .cancel) { uninstallSdkman = nil }
            Button(L("action.uninstall"), role: .destructive) {
                if let version = uninstallSdkman { vm.sdkman("uninstall", version: version) }
                uninstallSdkman = nil
            }
        } message: { Text(String(format: L("alert.uninstallSdkmanJavaMessage"), uninstallSdkman?.identifier ?? "")) }
    }

    @ViewBuilder
    private var page: some View {
        switch tab {
        case 1: versionManager
        case 2: MavenManagementView(app: app, vm: app.mavenVM)
        case 3: GradleManagementView(app: app, vm: app.gradleVM)
        default: installedTable
        }
    }

    // MARK: - 版本管理

    // 四个来源：Static（我们自己下的官方包）、Homebrew、MacPorts、SDKMAN。
    // 后三个交给第三方工具，我们只负责显示和调它。没装对应工具时给一句指路，不丢一张空表过来。
    private var versionManager: some View {
        VStack(alignment: .leading, spacing: 0) {
            VersionManagerHeader(sources: ["Static", "Homebrew", "MacPorts", "SDKMAN"], source: $source,
                                 linkURL: URL(string: "https://jdk.java.net/")!,
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
            } else if source == "SDKMAN" {
                if vm.sdkmanInstalled {
                    sdkmanTable
                } else {
                    VStack(alignment: .leading, spacing: 12) { Text(L("tools.missingSDKMAN")) }.padding(24)
                }
            } else {
                StaticVersionListView(versions: vm.staticVersions, loading: vm.staticLoading, busy: app.state.installBusy) { vm.installStatic($0) } uninstall: { vm.uninstallStatic($0) }
            }
            Spacer()
        }
    }

    // `sdk list java` 是「可下载」列表，已装 / 默认由本地目录和 current 软链判定，所以这里
    // 既能装也能卸。Use 列的 > 和 * 我们不看 —— 输出格式变了它就废了。
    private var sdkmanColumns: [TableColumn] {
        [TableColumn(title: L("column.library"), minWidth: 90, weight: 1),
         TableColumn(title: L("column.vendor"), minWidth: 90, weight: 1),
         TableColumn(title: L("column.version"), minWidth: 80),
         TableColumn(title: "Identifier", minWidth: 120, weight: 1),
         TableColumn(title: L("column.status"), minWidth: 70),
         TableColumn(title: L("column.operation"), minWidth: 170, weight: 2)]
    }

    private var sdkmanTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField(L("action.search"), text: $vm.sdkmanSearch).textFieldStyle(.roundedBorder).frame(width: 200)
                if vm.sdkmanLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button { Task { await vm.loadSdkman() } } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("action.refreshVersions"))
                    .disabled(vm.sdkmanLoading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 20).padding(.vertical, 10)
            DataTable(columns: sdkmanColumns, rows: vm.filteredSdkman(), empty: L("message.noSdkmanVersions")) { version in
                Text(version.library)
                Text(version.vendor)
                Text(version.version)
                Text(version.identifier)
                Group {
                    if version.isDefault { Text(L("sdkman.default")).foregroundStyle(AppTheme.green) }
                    else if version.installed { Text(L("tools.installed")).foregroundStyle(.secondary) }
                    else { Text("—").foregroundStyle(.secondary) }
                }
                HStack(spacing: 12) {
                    if version.installed {
                        if !version.isDefault {
                            Button(L("java.setDefault")) { vm.sdkman("default", version: version) }.buttonStyle(.borderless)
                        }
                        Button(L("action.uninstall")) { uninstallSdkman = version; confirmSdkmanUninstall = true }
                            .buttonStyle(.borderless)
                    } else {
                        Button(L("action.install")) { vm.sdkman("install", version: version) }.buttonStyle(.borderless)
                    }
                }
                .disabled(app.state.task != nil)
            }
        }
    }

    // MARK: - 已安装

    // 版本 / 发行商 / JDK Home / 来源 / 环境变量。宽度交给 DataTable 按容器反推。
    private var tableColumns: [TableColumn] {
        [TableColumn(title: L("column.version"), minWidth: 70),
         TableColumn(title: L("column.vendor"), minWidth: 110, weight: 1),
         TableColumn(title: "JAVA_HOME", minWidth: 140, weight: 1),
         TableColumn(title: L("column.source"), minWidth: 80),
         TableColumn(title: L("column.env"), minWidth: 56)]
    }

    private var installedTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SelectableTitle(text: "Java")
                AssetIcon(name: "JavaIcon").frame(width: 22, height: 22)
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
            DataTable(columns: tableColumns, rows: vm.versions, empty: L("message.noJavaInstalled")) { version in
                Text(version.version)
                Text(version.vendor)
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
