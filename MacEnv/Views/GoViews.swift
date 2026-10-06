import SwiftUI

// Go 是一等语言模块（FlyEnv 里跟 PHP / Node 同级），所以自己占一个页面而不是挂在 PHP 下面。
// 三个 tab：已安装（含环境变量开关）、版本管理（静态包）、GVM（第三方 Go 版本管理器）。
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
    @State private var confirmUninstallGvm = false

    var body: some View {
        ModulePage {
            SegmentedTabs(titles: [L("tab.installed"), L("tab.versions"), "GVM"], selection: $tab)
        } content: {
            page
        }
        // 单参数写法：双参数的 onChange 要 macOS 14，本工程最低 13。
        // 只在切到 GVM 时才去检测 ~/.gvm —— 每次开页面都跑一遍没必要。
        .onChange(of: tab) { value in if value == 2 { vm.checkGvm() } }
        .task { await vm.loadStatic() }
        .sheet(isPresented: $customPathEditor) { CustomPathEditor(title: "Go", paths: $vm.customDirectories) }
        .alert(L("alert.uninstallGoTitle"), isPresented: $confirmUninstall) {
            Button(L("action.cancel"), role: .cancel) { uninstallFormula = nil }
            Button(L("action.uninstall"), role: .destructive) {
                if let formula = uninstallFormula { vm.brewAction("uninstall", formula: formula) }
                uninstallFormula = nil
            }
        } message: { Text(String(format: L("alert.uninstallGoMessage"), uninstallFormula ?? "")) }
        .alert(L("alert.uninstallGvmTitle"), isPresented: $confirmUninstallGvm) {
            Button(L("action.cancel"), role: .cancel) {}
            Button(L("action.uninstall"), role: .destructive) { vm.uninstallGvm() }
        } message: { Text(String(format: L("alert.uninstallGvmMessage"), vm.gvmRootPath, vm.gvmInstalledCount)) }
    }

    @ViewBuilder
    private var page: some View {
        switch tab {
        case 1: versionManager
        case 2: gvmPanel
        default: installedTable
        }
    }

    // MARK: - 版本管理

    // 三个来源跟 Nginx / 数据库那两个页面一致：Static（我们自己下的官方包）、
    // Homebrew、MacPorts。后两个交给系统包管理器，我们只负责显示和调它。
    private var versionManager: some View {
        VStack(alignment: .leading, spacing: 0) {
            VersionManagerHeader(sources: ["Static", "Homebrew", "MacPorts"], source: $source,
                                 linkURL: URL(string: "https://go.dev/dl/")!,
                                 busy: app.state.busy, refreshing: refreshing, onRefresh: {
                refreshing = true
                Task { await vm.refreshVersionManager(source, force: true); refreshing = false }
            }, actions: {
                if source == "Homebrew" { Button(L("action.updateBrew")) { vm.brewAction("update", formula: "go") }.disabled(app.state.busy) }
            })
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
                VStack(alignment: .leading, spacing: 12) {
                    Text(FileManager.default.isExecutableFile(atPath: "/opt/local/bin/port") ? L("macports.detectedGo") : L("macports.missing"))
                    Link(L("macports.install"), destination: URL(string: "https://www.macports.org/install.php")!)
                }.padding(24)
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

    // MARK: - GVM

    private var gvmPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("GVM").font(.title3)
                Text(vm.gvmRootPath).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                if vm.gvmBusy {
                    ProgressView().controlSize(.small)
                    Button(L("action.cancel")) { vm.cancelGvm() }
                } else if vm.gvmInstalled == true {
                    // 卸载 GVM 本体。跟「卸载 CA 证书」同一排同一个图标，不用重新找。
                    Button { confirmUninstallGvm = true } label: { Image(systemName: "trash") }
                        .help(L("gvm.uninstall"))
                        .disabled(app.state.busy || vm.gvmBusy)
                    Button { Task { await vm.loadGvmVersions() } } label: { Image(systemName: "arrow.clockwise") }
                        .help(L("action.refreshVersions"))
                        .disabled(vm.gvmLoading)
                    TextField(L("action.search"), text: $vm.gvmSearch).textFieldStyle(.roundedBorder).frame(width: 160)
                }
            }
            .panelHeader()
            Divider()
            gvmContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var gvmContent: some View {
        if vm.gvmBusy {
            gvmLogView
        } else if vm.gvmInstalled == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("gvm.checking")).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .font(.callout)
        } else if vm.gvmInstalled == false {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("gvm.intro")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L("gvm.install")) { vm.installGvm() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(30)
        } else {
            gvmVersionTable
        }
    }

    private var gvmColumns: [TableColumn] {
        [TableColumn(title: L("column.version"), minWidth: 90, weight: 1),
         TableColumn(title: L("column.installed"), minWidth: 70),
         TableColumn(title: L("column.default"), minWidth: 70),
         TableColumn(title: L("column.operation"), minWidth: 170, weight: 3)]
    }

    private var gvmVersionTable: some View {
        DataTable(columns: gvmColumns, rows: filteredGvmVersions, empty: L("message.noGvmVersions")) { version in
            Text(version.version)
            Group {
                if version.installed { Image(systemName: "checkmark").foregroundStyle(AppTheme.green) }
                else { Text("—").foregroundStyle(.secondary) }
            }
            Group {
                if version.isDefault {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                } else if version.installed {
                    Button(L("gvm.setDefault")) { vm.gvm(.useDefault, version: version) }.buttonStyle(.borderless)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            Button(version.installed ? L("action.uninstall") : L("action.install")) {
                vm.gvm(version.installed ? .uninstall : .install, version: version)
            }
            .buttonStyle(.borderless)
        }
    }

    private var gvmLogView: some View {
        ScrollView(.vertical) {
            Text(vm.gvmLog.isEmpty ? L("gvm.preparing") : vm.gvmLog)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var filteredGvmVersions: [GvmVersion] {
        let key = vm.gvmSearch.trimmingCharacters(in: .whitespaces)
        let list = key.isEmpty ? vm.gvmVersions : vm.gvmVersions.filter { $0.version.contains(key) || $0.name.contains(key) }
        return list.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }
}
