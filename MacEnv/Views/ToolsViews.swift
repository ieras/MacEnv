import SwiftUI

// 环境工具页：Homebrew / MacPorts / SDKMAN / GVM 四个「工具本体」的装、卸、更新。
//
// 「用这个工具装东西」不在这里 —— 那是各模块版本管理页的来源 tab（Homebrew / MacPorts / …）。
// 两边各司其职：一个入口管本体，一个入口用本体。FlyEnv 是把这两件事都塞进每个模块的
// 版本管理页里，所以它没有这一页，也没地方卸载工具本体。
struct ToolsView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var vm: ToolsViewModel
    @State private var tab = 0

    var body: some View {
        ModulePage {
            SegmentedTabs(titles: ["Homebrew", "MacPorts", "SDKMAN", "GVM"], selection: $tab)
        } content: {
            switch tab {
            case 1: macPortsPanel
            case 2: sdkmanPanel
            case 3: GvmPanel(vm: app.goVM)
            default: brewPanel
            }
        }
        // 搜索框三个 tab 共用一个 @Published，切 tab 时清掉，免得带着上一个工具的
        // 过滤条件看到一张空表。GVM 只在那时才去检测 ~/.gvm。
        .onChange(of: tab) { value in
            vm.search = ""
            if value == 3 { app.goVM.checkGvm() }
        }
        .task { await vm.refresh() }
        .alert(L("alert.uninstallBrewTitle"), isPresented: $vm.confirmBrewUninstall) {
            Button(L("action.cancel"), role: .cancel) {}
            Button(L("action.uninstall"), role: .destructive) { vm.uninstallBrew() }
        } message: { Text(String(format: L("alert.uninstallBrewMessage"), vm.brewItems.count)) }
        .alert(L("alert.uninstallMacPortsTitle"), isPresented: $vm.confirmMacPortsUninstall) {
            Button(L("action.cancel"), role: .cancel) {}
            Button(L("action.uninstall"), role: .destructive) { vm.uninstallMacPorts() }
        } message: { Text(String(format: L("alert.uninstallMacPortsMessage"), vm.macPortsItems.count)) }
        .alert(L("alert.uninstallSDKMANTitle"), isPresented: $vm.confirmSDKMANUninstall) {
            Button(L("action.cancel"), role: .cancel) {}
            Button(L("action.uninstall"), role: .destructive) { vm.uninstallSDKMAN() }
        } message: { Text(String(format: L("alert.uninstallSDKMANMessage"), vm.sdkmanItems.count)) }
    }

    // MARK: - Homebrew

    private var brewPanel: some View {
        VStack(spacing: 0) {
            ToolHeader(name: "Homebrew",
                       status: vm.brewInstalled ? vm.brewVersion : L("tools.notInstalled"),
                       path: vm.brewInstalled ? vm.brewPath : "") {
                HomebrewIcon()
            } actions: {
                // 下载源：原来在设置页，只有 brew 用得上，所以搬到这里，跟「更新」同一行。
                Picker("", selection: $app.state.brewSource) {
                    ForEach(BrewSource.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 190)
                if vm.brewInstalled {
                    Button(L("action.update")) { vm.updateBrew() }.disabled(vm.busy)
                    Button { vm.confirmBrewUninstall = true } label: { Image(systemName: "trash") }
                        .help(L("tools.uninstallBrew"))
                        .disabled(vm.busy)
                } else {
                    Button(L("action.install")) { vm.installBrew() }.disabled(vm.busy)
                }
                Link(destination: URL(string: "https://brew.sh")!) { Image(systemName: "globe") }
            }
            Divider()
            toolTable(vm.brewItems) { vm.uninstallBrewFormula($0) }
        }
    }

    // MARK: - MacPorts

    private var macPortsPanel: some View {
        VStack(spacing: 0) {
            ToolHeader(name: "MacPorts",
                       status: vm.macPortsInstalled ? vm.macPortsVersion : L("tools.notInstalled"),
                       path: vm.macPortsInstalled ? vm.macPortsPath : "") {
                AssetIcon(name: "MacPortsIcon")
            } actions: {
                if vm.macPortsInstalled {
                    Button { vm.confirmMacPortsUninstall = true } label: { Image(systemName: "trash") }
                        .help(L("tools.uninstallMacPorts"))
                        .disabled(vm.busy)
                } else {
                    Button(L("action.install")) { vm.installMacPorts() }.disabled(vm.busy)
                }
                Link(destination: URL(string: "https://www.macports.org")!) { Image(systemName: "globe") }
            }
            Divider()
            toolTable(vm.macPortsItems) { vm.uninstallMacPortsPort($0) }
        }
    }

    // MARK: - SDKMAN

    private var sdkmanPanel: some View {
        VStack(spacing: 0) {
            ToolHeader(name: "SDKMAN",
                       status: vm.sdkmanInstalled ? L("tools.installed") : L("tools.notInstalled"),
                       path: vm.sdkmanInstalled ? vm.sdkmanPath : "") {
                // 官方那套是彩色的（红字 + 蓝爆炸底 + 半调点阵），压成单色就是一团黑，所以整张保留原色。
                AssetIcon(name: "SDKMANIcon")
            } actions: {
                if vm.sdkmanInstalled {
                    Button { vm.confirmSDKMANUninstall = true } label: { Image(systemName: "trash") }
                        .help(L("tools.uninstallSDKMAN"))
                        .disabled(vm.busy)
                } else {
                    Button(L("action.install")) { vm.installSDKMAN() }.disabled(vm.busy)
                }
                Link(destination: URL(string: "https://sdkman.io")!) { Image(systemName: "globe") }
            }
            Divider()
            toolTable(vm.sdkmanItems) { vm.uninstallSDKMANCandidate($0) }
        }
    }

    // MARK: - 共用的「这工具管了什么」表格

    private var itemColumns: [TableColumn] {
        [TableColumn(title: L("column.name"), minWidth: 140, weight: 2),
         TableColumn(title: L("column.version"), minWidth: 100, weight: 1),
         operationColumn]
    }

    private func toolTable(_ items: [ToolItem], uninstall: @escaping (ToolItem) -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField(L("action.search"), text: $vm.search).textFieldStyle(.roundedBorder).frame(width: 200)
                if vm.loading { ProgressView().controlSize(.small) }
                Spacer()
                Button { Task { await vm.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("action.refreshVersions"))
                    .disabled(vm.loading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 20).padding(.vertical, 10)
            DataTable(columns: itemColumns, rows: vm.filtered(items), empty: L("tools.empty")) { item in
                Text(item.name)
                Text(item.version)
                Button(L("action.uninstall")) { uninstall(item) }
                    .buttonStyle(.borderless)
                    .disabled(vm.busy)
            }
        }
    }
}

// 工具本体那一行：名字 + 图标 + 状态徽章 + 操作，路径单独一行、点开就是 Finder。
// 图标跟在名字后面，跟其他页面一致（设置页的模块卡片也是这么排的）。
// 图标由调用方给：GVM 是两层叠的、SDKMAN 要保留官方配色，都不是 AssetIcon 一张图能表达的。
struct ToolHeader<Icon: View, Actions: View>: View {
    let name: String
    let status: String
    let path: String
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                SelectableTitle(text: name)
                icon().frame(width: 22, height: 22)
                if !status.isEmpty {
                    Text(status)
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(AppTheme.cardBackground, in: Capsule())
                }
                Spacer()
                actions()
            }
            if !path.isEmpty {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true)) } label: {
                    Text(tilde(path)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.borderless)
                .help(L("action.openFolder"))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }
}

// MARK: - GVM

// GVM 只管 Go，本体管理却要有个地方放 —— 跟 Homebrew 完全同构：
// 本体在这一页（装 / 卸 / 路径），「用 GVM 装 Go」在 Go 页的版本管理里当来源。
// 状态和动作留在 GoViewModel（它们本来就是 Go 的东西），这里只读。
struct GvmPanel: View {
    @ObservedObject var vm: GoViewModel
    @State private var confirmUninstall = false

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(name: "GVM",
                       status: vm.gvmInstalled == true ? L("tools.installed") : L("tools.notInstalled"),
                       path: vm.gvmInstalled == true ? vm.gvmRootPath : "") {
                GvmIcon()
            } actions: {
                if vm.gvmInstalled == true {
                    Button { confirmUninstall = true } label: { Image(systemName: "trash") }
                        .help(L("gvm.uninstall"))
                } else if vm.gvmInstalled == false {
                    Button(L("action.install")) { vm.installGvm() }
                }
                Link(destination: URL(string: "https://github.com/moovweb/gvm")!) { Image(systemName: "globe") }
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .alert(L("alert.uninstallGvmTitle"), isPresented: $confirmUninstall) {
            Button(L("action.cancel"), role: .cancel) {}
            Button(L("action.uninstall"), role: .destructive) { vm.uninstallGvm() }
        } message: { Text(String(format: L("alert.uninstallGvmMessage"), tilde(vm.gvmRootPath), vm.gvmInstalledCount)) }
    }

    @ViewBuilder
    private var content: some View {
        if vm.gvmInstalled == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("gvm.checking")).foregroundStyle(.secondary)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if vm.gvmInstalled == false {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("gvm.intro")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L("gvm.install")) { vm.installGvm() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(30)
        } else {
            // 环境工具页是管本体的：只列 GVM 已装的 Go 版本，装新版本去 Go 页的 GVM 来源。
            GvmVersionTable(vm: vm, installedOnly: true)
        }
    }
}

// GVM 的版本表。两种口径：
//   环境工具页（管本体）→ installedOnly，只列装了的，跟 brew / macports / sdkman 三个 tab 对齐；
//   Go 页的 GVM 来源（用本体）→ 全量可装清单，那里是装新版本的入口，跟 Static / Brew tab 一个道理。
// 两处读同一份数据，做成一个 view 别抄两遍 —— 抄两遍的下场是改一处忘一处。
struct GvmVersionTable: View {
    @ObservedObject var vm: GoViewModel
    var installedOnly = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField(L("action.search"), text: $vm.gvmSearch).textFieldStyle(.roundedBorder).frame(width: 200)
                if vm.gvmLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button { Task { await vm.loadGvmVersions() } } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("action.refreshVersions"))
                    .disabled(vm.gvmLoading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 20).padding(.vertical, 10)
            // LazyVGrid 是顺序流布局，单元格数必须和列数严格对齐，所以两种口径各画各的表。
            // 空提示也按口径走：已装口径跟 brew / macports / sdkman 一个说法，
            // 可装清单口径跟 MacPorts 来源 tab 一个说法。
            if installedOnly {
                DataTable(columns: installedColumns, rows: filtered.filter(\.installed), empty: L("tools.empty")) { version in
                    Text(version.version)
                    defaultMark(version)
                    Button(L("action.uninstall")) { vm.gvm(.uninstall, version: version) }.buttonStyle(.borderless)
                }
            } else {
                DataTable(columns: columns, rows: filtered, empty: L("port.empty")) { version in
                    Text(version.version)
                    Group {
                        if version.installed { Image(systemName: "checkmark").foregroundStyle(AppTheme.green) }
                        else { Text("—").foregroundStyle(.secondary) }
                    }
                    defaultMark(version)
                    Button(version.installed ? L("action.uninstall") : L("action.install")) {
                        vm.gvm(version.installed ? .uninstall : .install, version: version)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    // 默认版本：当前的打勾，没设的给一键切换。
    private func defaultMark(_ version: GvmVersion) -> some View {
        Group {
            if version.isDefault { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
            else if version.installed { Button(L("gvm.setDefault")) { vm.gvm(.useDefault, version: version) }.buttonStyle(.borderless) }
            else { Text("—").foregroundStyle(.secondary) }
        }
    }

    private var installedColumns: [TableColumn] {
        [TableColumn(title: L("column.version"), minWidth: 90, weight: 1),
         TableColumn(title: L("column.default"), minWidth: 70),
         TableColumn(title: L("column.operation"), minWidth: 170, weight: 3)]
    }

    private var columns: [TableColumn] {
        [TableColumn(title: L("column.version"), minWidth: 90, weight: 1),
         TableColumn(title: L("column.installed"), minWidth: 70),
         TableColumn(title: L("column.default"), minWidth: 70),
         TableColumn(title: L("column.operation"), minWidth: 170, weight: 3)]
    }

    private var filtered: [GvmVersion] {
        let key = vm.gvmSearch.trimmingCharacters(in: .whitespaces)
        let list = key.isEmpty ? vm.gvmVersions : vm.gvmVersions.filter { $0.version.contains(key) || $0.name.contains(key) }
        return list.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }
}
