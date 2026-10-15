import SwiftUI

// NodeJs 是一等语言模块（跟 PHP / Go 同级），自己占一个页面。
// 两个 tab：已安装（含 PATH 开关和 nvm/fnm 卸载）、版本管理（五个来源：Static /
// Homebrew / MacPorts / nvm / fnm）。无常驻进程、无配置、无日志 —— 跟 Go 页面同构。
// nvm / fnm 跟 MacPorts / Homebrew 一样是「第三方工具渠道」：只读地混进已安装列表，
// 装卸走命令代理，不接管它们的目录。版本管理页里 nvm / fnm 各自占一个来源 tab，
// 交互是本地已装在前、远程可装在后的一张混排表，带搜索框，行内装 / 卸 /
// 设默认 —— 「用哪个管理器装」是来源语义，不是 Static 行的附属按钮。
// 管理器本体（装 / 更新 / 卸）不在这页 —— 在环境工具页，跟 GVM 同构：
// 工具本体归环境工具页，「用工具装版本」才在各模块的来源 tab（同 Go 页的 GVM）。
struct NodeManagementView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var vm: NodeViewModel
    @State private var tab = 0
    @State private var source = "Static"
    @State private var customPathEditor = false
    @State private var refreshing = false
    // 卸载必须记住点的是哪一行（哪个管理器、哪个版本），不能在闭包里写死 —— PHP 页面栽过这个跟头。
    @State private var pendingUninstall: NodeVersion?

    var body: some View {
        ModulePage {
            SegmentedTabs(titles: [L("tab.installed"), L("tab.versions")], selection: $tab)
        } content: {
            page
        }
        .task {
            await vm.loadStatic()
            vm.checkManagers()
        }
        // nvm / fnm 装没装要现问文件系统和命令（用户可能在别处刚装好），切来源就再问一次。
        .onChange(of: source) { _ in vm.checkManagers() }
        .sheet(isPresented: $customPathEditor) { CustomPathEditor(title: "Node", paths: $vm.customDirectories) }
        .alert(L("alert.uninstallNodeTitle"), isPresented: Binding(
            get: { pendingUninstall != nil },
            set: { if !$0 { pendingUninstall = nil } })) {
            Button(L("action.cancel"), role: .cancel) { pendingUninstall = nil }
            Button(L("action.uninstall"), role: .destructive) {
                if let version = pendingUninstall {
                    vm.managerAction(version.source, "uninstall", version.version)
                }
                pendingUninstall = nil
            }
        } message: {
            // ⚠️ message 闭包在 body 每次求值时立即执行（不是弹出 alert 才跑），
            // String(format:) 的 %@ 数量必须跟参数严格对上 —— 少一个是运行时 SIGSEGV，
            // 编译和单测都抓不到（Node 页面曾经就这么崩过）。
            Text(String(format: L("alert.uninstallNodeMessage"), pendingUninstall?.source ?? "", pendingUninstall?.version ?? ""))
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

    // 五个来源：Static（我们自己从 nodejs.org 下的官方包）、Homebrew、MacPorts、nvm、fnm。
    // 后四个交给第三方工具，我们只负责显示和调它。MacPorts 的 port 名是
    // nodejs / nodejs18 / nodejs22 这一族。nvm / fnm 没装时指路环境工具页（本体在那管）。
    private var versionManager: some View {
        VStack(alignment: .leading, spacing: 0) {
            VersionManagerHeader(sources: ["Static", "Homebrew", "MacPorts", "nvm", "fnm"], source: $source,
                                 linkURL: URL(string: "https://nodejs.org/")!,
                                 busy: app.state.installBusy, refreshing: refreshing, onRefresh: {
                refreshing = true
                Task { await vm.refreshVersionManager(source, force: true); refreshing = false }
            }, width: 460, actions: {})
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
            } else if source == "nvm" || source == "fnm" {
                managerTab
            } else {
                StaticVersionListView(versions: vm.staticVersions, loading: vm.staticLoading, busy: app.state.installBusy,
                                      install: { vm.installStatic($0) }, uninstall: { vm.uninstallStatic($0) },
                                      badge: { $0.lts.map { "LTS \($0)" } })
            }
            Spacer()
        }
    }

    // nvm / fnm 的来源 tab：检测中给个 spinner，装了给版本表，没装指路环境工具页
    // （本体装卸在那，跟 Go 页对 GVM 的处理一样 —— 只给一句指路，不丢空表）。
    private var managerTab: some View {
        let installed = source == "nvm" ? vm.nvmInstalled : vm.fnmInstalled
        return Group {
            if installed == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("node.checkingManager")).foregroundStyle(.secondary)
                }
                .padding(24)
            } else if installed == true {
                ManagerVersionListView(vm: vm, manager: source, busy: app.state.installBusy,
                                       onUninstall: { version in pendingUninstall = version })
            } else {
                Text(String(format: L("node.missingManager"), source)).foregroundStyle(.secondary).padding(24)
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
                SelectableTitle(text: "NodeJs")
                AssetIcon(name: "NodeIcon").frame(width: 22, height: 22)
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
            DataTable(columns: tableColumns, rows: vm.versions, empty: L("message.noNodeInstalled")) { version in
                HStack(spacing: 6) {
                    Text(version.version)
                    // 管理器自己的 default 只显示徽章 —— PATH 归属走 MacEnv 自己的软链，跟它正交。
                    if version.isNvmDefault || version.isFnmDefault {
                        Text(version.isNvmDefault ? L("node.nvmDefault") : L("node.fnmDefault"))
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
                    // nvm / fnm 管的版本走它们自己的卸载命令（要过确认弹窗）；
                    // 其余来源（静态包 / brew / 自定义）的卸载在版本管理页或 brew 列表里。
                    if version.source == "nvm" || version.source == "fnm" {
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

// MARK: - nvm / fnm 版本表

// 两种口径，跟 GvmVersionTable 一模一样：
//   Node 页的 nvm / fnm 来源（用本体）→ 全量可装清单：本地已装（管理器目录里扫到的）
//   在前，远程可装（nodejs.org 全量、剔掉已装的）在后，带搜索框，行内装 / 卸 / 设默认；
//   环境工具页的 nvm / fnm 面板（管本体）→ installedOnly，只列装了的，卸载走确认弹窗。
// 两处读同一份数据，做成一个 view 别抄两遍 —— 抄两遍的下场是改一处忘一处。
//
// 远程清单跟 Static tab 是同一份（NodeService.parseDist 的 nodejs.org/dist/index.json），
// 管理器自己的远程源也是这个 —— 只是安装路由给管理器命令。两边 version 都是 probe 出来
// 的纯版本号（不带 v），能直接配对。
struct ManagerVersionListView: View {
    @ObservedObject var vm: NodeViewModel
    let manager: String  // "nvm" / "fnm"
    var busy = false
    var installedOnly = false
    // 卸载走父视图的确认弹窗（弹窗文案要带版本号和目录信息，所以把 NodeVersion 解构上去）。
    var onUninstall: (NodeVersion) -> Void = { _ in }
    @State private var search = ""

    private struct Row {
        let name: String
        let version: String
        let lts: String?
        let installed: Bool
        let isDefault: Bool
    }

    // 全量口径：已装的在前（保持扫描顺序），远程在后（parseDist 已按版本降序）。
    // 已装行的 LTS 代号从远程清单里按版本号回查 —— 已装但远程列表没有的很老版本就没有徽章。
    // installedOnly 口径：只留已装行。
    private var rows: [Row] {
        let installed = vm.versions.filter { $0.source == manager }.map { version -> Row in
            Row(name: "Node-\(version.version)",
                version: version.version,
                lts: vm.staticVersions.first { $0.version == version.version }?.lts,
                installed: true,
                isDefault: version.isNvmDefault || version.isFnmDefault)
        }
        guard !installedOnly else { return installed }
        let taken = Set(installed.map(\.version))
        let remote = vm.staticVersions
            .filter { !taken.contains($0.version) }
            .map { Row(name: $0.name, version: $0.version, lts: $0.lts, installed: false, isDefault: false) }
        let list = installed + remote
        let key = search.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return list }
        return list.filter { $0.version.contains(key) || $0.name.lowercased().contains(key.lowercased()) }
    }

    // 库 / 版本 / 是否安装 / 默认 / 操作。口径跟 brew / macports 那张表一致。
    // installedOnly 口径没有「是否安装」列（列出来全是勾，废话）和「版本」列（名字里就有）。
    // nvm / fnm 都有默认列（fnm 的默认读 aliases/default 文件，见 NodeService.fnmDefaultVersion）。
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
        HStack(spacing: 6) {
            Text(row.name)
            if let lts = row.lts {
                Text("LTS \(lts)")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AppTheme.cardBackground, in: Capsule())
            }
        }
    }

    // 默认列：管理器自己的默认版本打勾；其余已装的给「设为默认」一键切换
    // （nvm 跑 alias default，fnm 跑 default）；没装的一杠。
    @ViewBuilder
    private func defaultCell(_ row: Row) -> some View {
        if row.isDefault {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
        } else if row.installed {
            Button(L("node.setDefault")) { vm.managerAction(manager, "alias", row.version) }
                .buttonStyle(.borderless)
                .disabled(busy)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    // 操作列：全量口径里没装给「安装」；两种口径里已装都给「卸载」，走父视图的确认弹窗
    // （NodeVersion 从扫描结果里回找 —— 行就是从它构造的，找不到（扫描延迟）就一杠兜底）。
    @ViewBuilder
    private func operationCell(_ row: Row) -> some View {
        if !installedOnly, !row.installed {
            Button(L("action.install")) { vm.managerAction(manager, "install", row.version) }
                .buttonStyle(.borderless)
                .disabled(busy)
        } else if let version = vm.versions.first(where: { $0.source == manager && $0.version == row.version }) {
            Button(L("action.uninstall")) { onUninstall(version) }
                .buttonStyle(.borderless)
                .disabled(busy)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }
}
