import SwiftUI

// Gradle 跟 Maven 同构：没有常驻进程，两个 tab —— 已安装（含 PATH 开关）、版本管理（Static / Homebrew / MacPorts / SDKMAN）。
struct GradleManagementView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var vm: GradleViewModel
    @State private var tab = 0
    @State private var source = "Static"
    @State private var customPathEditor = false
    @State private var refreshing = false
    @State private var confirmUninstall = false
    @State private var confirmSdkmanUninstall = false
    @State private var uninstallFormula: String?
    @State private var uninstallSdkman: SdkmanVersion?

    // 本体不包 ModulePage 外壳——它作为 Java 模块页里的一个 tab 被嵌入，外壳由 Java 页统一给。
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SegmentedTabs(titles: [L("tab.installed"), L("tab.versions")], selection: $tab)
                .padding(.bottom, 12)
            page
        }
        .task { await vm.loadStatic() }
        .onChange(of: source) { value in if value == "SDKMAN" { Task { await vm.loadSdkman() } } }
        .sheet(isPresented: $customPathEditor) { CustomPathEditor(title: "Gradle", paths: $vm.customDirectories) }
        .alert(L("alert.uninstallGradleTitle"), isPresented: $confirmUninstall) {
            Button(L("action.cancel"), role: .cancel) { uninstallFormula = nil }
            Button(L("action.uninstall"), role: .destructive) {
                if let formula = uninstallFormula { vm.brewAction("uninstall", formula: formula) }
                uninstallFormula = nil
            }
        } message: { Text(String(format: L("alert.uninstallGradleMessage"), uninstallFormula ?? "")) }
        .alert(L("alert.uninstallSdkmanGradleTitle"), isPresented: $confirmSdkmanUninstall) {
            Button(L("action.cancel"), role: .cancel) { uninstallSdkman = nil }
            Button(L("action.uninstall"), role: .destructive) {
                if let version = uninstallSdkman { vm.sdkman("uninstall", version: version) }
                uninstallSdkman = nil
            }
        } message: { Text(String(format: L("alert.uninstallSdkmanGradleMessage"), uninstallSdkman?.identifier ?? "")) }
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
            VersionManagerHeader(sources: ["Static", "Homebrew", "MacPorts", "SDKMAN"], source: $source,
                                 linkURL: URL(string: "https://gradle.org/")!,
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

    private var sdkmanColumns: [TableColumn] {
        [TableColumn(title: L("column.library"), minWidth: 90, weight: 1),
         TableColumn(title: L("column.version"), minWidth: 100, weight: 1),
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

    private var tableColumns: [TableColumn] {
        [TableColumn(title: L("column.version"), minWidth: 80),
         TableColumn(title: L("column.directory"), minWidth: 140, weight: 1),
         TableColumn(title: L("column.source"), minWidth: 80),
         TableColumn(title: L("column.env"), minWidth: 56)]
    }

    private var installedTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SelectableTitle(text: "Gradle")
                AssetIcon(name: "GradleIcon").frame(width: 22, height: 22)
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
            DataTable(columns: tableColumns, rows: vm.versions, empty: L("message.noGradleInstalled")) { version in
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
