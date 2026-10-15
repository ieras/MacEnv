import SwiftUI

// Rust 是一等语言模块（跟 PHP / Go / NodeJs 同级），自己占一个页面。
// 两个 tab：已安装（含 PATH 开关和 rustup 卸载）、版本管理（四个来源：Static /
// Homebrew / MacPorts / rustup）。无常驻进程、无配置、无日志 —— 跟 Go 页面同构。
//
// rustup 跟 nvm / fnm 一样是「第三方工具渠道」：只读地混进已安装列表，装卸走命令代理，
// 不接管它的目录。版本管理页里 rustup 占一个来源 tab，交互是本地已装在前、远程可装在后
// 的一张混排表，带搜索框，行内装 / 卸 / 设默认 —— 「用哪个工具装」是来源语义，
// 不是 Static 行的附属按钮。
// 管理器本体（装 / 更新 / 卸）不在这页 —— 在环境工具页，跟 GVM / nvm / fnm 同构：
// 工具本体归环境工具页，「用工具装版本」才在各模块的来源 tab。
struct RustManagementView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var vm: RustViewModel
    @State private var tab = 0
    @State private var source = "Static"
    @State private var customPathEditor = false
    @State private var refreshing = false
    // 卸载必须记住点的是哪一行，不能在闭包里写死 —— PHP 页面栽过这个跟头。
    @State private var pendingUninstall: RustVersion?

    var body: some View {
        ModulePage {
            SegmentedTabs(titles: [L("tab.installed"), L("tab.versions")], selection: $tab)
        } content: {
            page
        }
        .task {
            await vm.loadStatic()
            vm.checkRustup()
        }
        // rustup 装没装要现问文件系统和命令（用户可能在别处刚装好），切来源就再问一次。
        .onChange(of: source) { _ in vm.checkRustup() }
        .sheet(isPresented: $customPathEditor) { CustomPathEditor(title: "Rust", paths: $vm.customDirectories) }
        .alert(L("alert.uninstallRustTitle"), isPresented: Binding(
            get: { pendingUninstall != nil },
            set: { if !$0 { pendingUninstall = nil } })) {
            Button(L("action.cancel"), role: .cancel) { pendingUninstall = nil }
            Button(L("action.uninstall"), role: .destructive) {
                if let version = pendingUninstall {
                    vm.rustupAction("uninstall", version.version)
                }
                pendingUninstall = nil
            }
        } message: {
            // ⚠️ message 闭包在 body 每次求值时立即执行（不是弹出 alert 才跑），
            // String(format:) 的 %@ 数量必须跟参数严格对上 —— 少一个是运行时 SIGSEGV，
            // 编译和单测都抓不到（Node 页面曾经就这么崩过）。
            Text(String(format: L("alert.uninstallRustMessage"), pendingUninstall?.version ?? ""))
        }
    }

    @ViewBuilder
    private var page: some View {
        switch tab {
        case 1: versionManager
        default: installedTable
        }
    }

    // MARK: - 版本管理

    // 四个来源：Static（我们自己从 static.rust-lang.org 下的官方包）、Homebrew、MacPorts、
    // rustup。后三个交给第三方工具，我们只负责显示和调它。rustup 没装时指路环境工具页
    // （本体在那管）。
    private var versionManager: some View {
        VStack(alignment: .leading, spacing: 0) {
            VersionManagerHeader(sources: ["Static", "Homebrew", "MacPorts", "rustup"], source: $source,
                                 linkURL: URL(string: "https://www.rust-lang.org/")!,
                                 busy: app.state.installBusy, refreshing: refreshing, onRefresh: {
                refreshing = true
                Task { await vm.refreshVersionManager(source, force: true); refreshing = false }
            }, width: 400, actions: {})
            Divider()
            if source == "Homebrew" {
                if vm.formulae.isEmpty {
                    Text(L("brew.missing")).padding(24)
                    Link(L("brew.install"), destination: URL(string: "https://brew.sh")!).padding(.horizontal, 24)
                } else {
                    BrewListView(formulae: vm.formulae, busy: app.state.installBusy) { action, formula in
                        vm.brewAction(action, formula: formula)
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
            } else if source == "rustup" {
                rustupTab
            } else {
                StaticVersionListView(versions: vm.staticVersions, loading: vm.staticLoading, busy: app.state.installBusy,
                                      install: { vm.installStatic($0) }, uninstall: { vm.uninstallStatic($0) })
            }
            Spacer()
        }
    }

    // rustup 的来源 tab：检测中给个 spinner，装了给版本表，没装指路环境工具页
    // （本体装卸在那，跟 Go 页对 GVM 的处理一样 —— 只给一句指路，不丢空表）。
    private var rustupTab: some View {
        Group {
            if vm.rustupInstalled == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("rust.checkingManager")).foregroundStyle(.secondary)
                }
                .padding(24)
            } else if vm.rustupInstalled == true {
                RustupVersionListView(vm: vm, busy: app.state.installBusy,
                                      onUninstall: { version in pendingUninstall = version })
            } else {
                Text(String(format: L("rust.missingManager"), "rustup")).foregroundStyle(.secondary).padding(24)
            }
        }
    }

    // MARK: - 已安装

    // 版本 / 目录 / 来源 / 环境变量 / 操作。宽度交给 DataTable 按容器反推。
    private var tableColumns: [TableColumn] {
        [TableColumn(title: L("column.version"), minWidth: 60),
         TableColumn(title: L("column.path"), minWidth: 140, weight: 1),
         TableColumn(title: L("column.source"), minWidth: 90),
         TableColumn(title: L("column.env"), minWidth: 56),
         operationColumn]
    }

    private var installedTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SelectableTitle(text: "Rust")
                AssetIcon(name: "RustIcon").frame(width: 22, height: 22)
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
            DataTable(columns: tableColumns, rows: vm.versions, empty: L("message.noRustInstalled")) { version in
                HStack(spacing: 6) {
                    Text(version.version)
                    // rustup 自己的默认工具链只显示徽章 —— PATH 归属走 MacEnv 自己的软链，跟它正交。
                    if version.isRustupDefault {
                        Text(L("rust.rustupDefault"))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.cardBackground, in: Capsule())
                    }
                }
                Button { NSWorkspace.shared.open(version.directory) } label: {
                    Text(tilde(version.directory.path)).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.borderless).help(tilde(version.directory.path))
                Text(version.source)
                EnvironmentVariableButton(membership: vm.pathMembership[version.id, default: .none]) { vm.togglePath(version) }
                    .disabled(app.state.busy)
                Group {
                    // rustup 管的版本走它自己的卸载命令（要过确认弹窗）；
                    // 其余来源（静态包 / brew / macports / 自定义）的卸载在版本管理页或对应清单里。
                    if version.source == "rustup" {
                        Button(L("action.uninstall")) { pendingUninstall = version }
                            .buttonStyle(.borderless)
                            .disabled(app.state.installBusy)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - rustup 版本表

// 两种口径，跟 GvmVersionTable / ManagerVersionListView 一模一样：
//   Rust 页的 rustup 来源（用本体）→ 全量可装清单：本地已装（工具链目录里扫到的）
//   在前，远程可装（static.rust-lang.org 全量、剔掉已装的）在后，带搜索框，行内装 / 卸 / 设默认；
//   环境工具页的 rustup 面板（管本体）→ installedOnly，只列装了的，卸载走确认弹窗。
// 两处读同一份数据，做成一个 view 别抄两遍 —— 抄两遍的下场是改一处忘一处。
//
// 远程清单跟 Static tab 是同一份（RustService.versions 给的官方版本列表），
// 只是安装路由给 rustup 命令。两边 version 都是 probe 出来的纯版本号，能直接配对。
struct RustupVersionListView: View {
    @ObservedObject var vm: RustViewModel
    var busy = false
    var installedOnly = false
    // 卸载走父视图的确认弹窗（弹窗文案要带版本号，所以把 RustVersion 解构上去）。
    var onUninstall: (RustVersion) -> Void = { _ in }
    @State private var search = ""

    private struct Row {
        let name: String
        let version: String
        let installed: Bool
        let isDefault: Bool
    }

    // 全量口径：已装的在前（保持扫描顺序），远程在后（Static 已按版本降序）。
    // installedOnly 口径：只留已装行。
    private var rows: [Row] {
        let installed = vm.versions.filter { $0.source == "rustup" }.map { version in
            Row(name: "rust-\(version.version)", version: version.version,
                installed: true, isDefault: version.isRustupDefault)
        }
        guard !installedOnly else { return installed }
        let taken = Set(installed.map(\.version))
        let remote = vm.staticVersions
            .filter { !taken.contains($0.version) }
            .map { Row(name: $0.name, version: $0.version, installed: false, isDefault: false) }
        let list = installed + remote
        let key = search.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return list }
        return list.filter { $0.version.contains(key) || $0.name.lowercased().contains(key.lowercased()) }
    }

    // 库 / 版本 / 是否安装 / 默认 / 操作。口径跟 brew / macports 那张表一致。
    // installedOnly 口径没有「是否安装」列（列出来全是勾，废话）和「版本」列（名字里就有）。
    private var columns: [TableColumn] {
        if installedOnly {
            return [TableColumn(title: L("column.library"), minWidth: 110, weight: 2),
                    TableColumn(title: L("column.default"), minWidth: 90),
                    TableColumn(title: L("column.operation"), minWidth: 120, weight: 1)]
        }
        return [TableColumn(title: L("column.library"), minWidth: 110, weight: 2),
                TableColumn(title: L("column.version"), minWidth: 90, weight: 1),
                TableColumn(title: L("column.installed"), minWidth: 70),
                TableColumn(title: L("column.default"), minWidth: 90),
                TableColumn(title: L("column.operation"), minWidth: 170, weight: 3)]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField(L("action.search"), text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
                if vm.staticLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button { Task { await vm.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("action.refreshVersions"))
                    .disabled(busy)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 20).padding(.vertical, 10)
            if installedOnly {
                DataTable(columns: columns, rows: rows.filter(\.installed), empty: L("tools.empty")) { row in
                    libraryCell(row)
                    defaultCell(row)
                    operationCell(row)
                }
            } else {
                DataTable(columns: columns, rows: rows, empty: L("port.empty")) { row in
                    libraryCell(row)
                    Text(row.version)
                    Group {
                        if row.installed { Image(systemName: "checkmark").foregroundStyle(AppTheme.green) }
                        else { Text("—").foregroundStyle(.secondary) }
                    }
                    defaultCell(row)
                    operationCell(row)
                }
            }
        }
    }

    @ViewBuilder
    private func libraryCell(_ row: Row) -> some View {
        Text(row.name)
    }

    // 默认列：rustup 自己的默认工具链打勾；其余已装的给「设为默认」一键切换
    // （rustup 跑 default）；没装的一杠。
    @ViewBuilder
    private func defaultCell(_ row: Row) -> some View {
        if row.isDefault {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
        } else if row.installed {
            Button(L("rust.setDefault")) { vm.rustupAction("alias", row.version) }
                .buttonStyle(.borderless)
                .disabled(busy)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    // 操作列：全量口径里没装给「安装」；两种口径里已装都给「卸载」，走父视图的确认弹窗
    // （RustVersion 从扫描结果里回找 —— 行就是从它构造的，找不到（扫描延迟）就一杠兜底）。
    @ViewBuilder
    private func operationCell(_ row: Row) -> some View {
        if !installedOnly, !row.installed {
            Button(L("action.install")) { vm.rustupAction("install", row.version) }
                .buttonStyle(.borderless)
                .disabled(busy)
        } else if let version = vm.versions.first(where: { $0.source == "rustup" && $0.version == row.version }) {
            Button(L("action.uninstall")) { onUninstall(version) }
                .buttonStyle(.borderless)
                .disabled(busy)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }
}
