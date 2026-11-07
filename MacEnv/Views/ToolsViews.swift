import SwiftUI

struct ToolsView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var vm: ToolsViewModel
    @State private var tab = 0

    var body: some View {
        ModulePage {
            SegmentedTabs(titles: ["Homebrew", "MacPorts", "SDKMAN", "GVM", "nvm", "fnm", "rustup"], selection: $tab)
        } content: {
            switch tab {
            case 1: macPortsPanel
            case 2: sdkmanPanel
            case 3: GvmPanel(vm: app.goVM)
            case 4: ManagerPanel(vm: app.nodeVM, manager: "nvm")
            case 5: ManagerPanel(vm: app.nodeVM, manager: "fnm")
            case 6: RustupPanel(vm: app.rustVM)
            default: brewPanel
            }
        }
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
            GvmVersionTable(vm: vm, installedOnly: true)
        }
    }
}

// MARK: - nvm / fnm

struct ManagerPanel: View {
    @ObservedObject var vm: NodeViewModel
    let manager: String  // "nvm" / "fnm"
    @State private var confirmManagerUninstall = false
    @State private var pendingUninstall: NodeVersion?

    private var installed: Bool? { manager == "nvm" ? vm.nvmInstalled : vm.fnmInstalled }
    private var rootPath: String { manager == "nvm" ? vm.nvmRootPath : vm.fnmDirectoryPath }

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(name: manager,
                       status: installed == true ? L("tools.installed") : L("tools.notInstalled"),
                       path: installed == true ? rootPath : "") {
                if manager == "nvm" { NvmIcon() } else { FnmIcon() }
            } actions: {
                if installed == true {
                    Button(L("action.update")) { vm.managerSelfAction(manager, "update") }
                    Button { confirmManagerUninstall = true } label: { Image(systemName: "trash") }
                        .help(String(format: L("tools.uninstallManager"), manager))
                } else if installed == false {
                    Button(L("action.install")) { vm.managerSelfAction(manager, "install") }
                }
                Link(destination: URL(string: manager == "nvm" ? "https://github.com/nvm-sh/nvm" : "https://github.com/Schniz/fnm")!) { Image(systemName: "globe") }
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task { vm.checkManagers() }
        .alert(L("alert.uninstallManagerTitle"), isPresented: $confirmManagerUninstall) {
            Button(L("action.cancel"), role: .cancel) {}
            Button(L("action.uninstall"), role: .destructive) { vm.managerSelfAction(manager, "uninstall") }
        } message: {
            Text(String(format: L("alert.uninstallManagerMessage"), manager, tilde(rootPath),
                        vm.versions.filter { $0.source == manager }.count))
        }
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
            Text(String(format: L("alert.uninstallNodeMessage"), pendingUninstall?.source ?? "", pendingUninstall?.version ?? ""))
        }
    }

    @ViewBuilder
    private var content: some View {
        if installed == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("node.checkingManager")).foregroundStyle(.secondary)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if installed == false {
            VStack(alignment: .leading, spacing: 14) {
                Text(String(format: L("node.managerIntro"), manager))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("action.install")) { vm.managerSelfAction(manager, "install") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(30)
        } else {
            ManagerVersionListView(vm: vm, manager: manager, installedOnly: true) { version in
                pendingUninstall = version
            }
        }
    }
}

// MARK: - rustup

struct RustupPanel: View {
    @ObservedObject var vm: RustViewModel
    @State private var confirmManagerUninstall = false
    @State private var pendingUninstall: RustVersion?

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(name: "rustup",
                       status: vm.rustupInstalled == true ? L("tools.installed") : L("tools.notInstalled"),
                       path: vm.rustupInstalled == true ? vm.rustupPath : "") {
                AssetIcon(name: "RustIcon")
            } actions: {
                if vm.rustupInstalled == true {
                    Button(L("action.update")) { vm.rustupSelfAction("update") }
                    Button { confirmManagerUninstall = true } label: { Image(systemName: "trash") }
                        .help(String(format: L("tools.uninstallManager"), "rustup"))
                } else if vm.rustupInstalled == false {
                    Button(L("action.install")) { vm.rustupSelfAction("install") }
                }
                Link(destination: URL(string: "https://rust-lang.github.io/rustup/")!) { Image(systemName: "globe") }
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task { vm.checkRustup() }
        .alert(L("alert.uninstallRustupTitle"), isPresented: $confirmManagerUninstall) {
            Button(L("action.cancel"), role: .cancel) {}
            Button(L("action.uninstall"), role: .destructive) { vm.rustupSelfAction("uninstall") }
        } message: {
            Text(String(format: L("alert.uninstallRustupMessage"), "rustup", tilde(vm.rustupPath),
                        vm.versions.filter { $0.source == "rustup" }.count))
        }
        .alert(L("alert.uninstallRustTitle"), isPresented: Binding(
            get: { pendingUninstall != nil },
            set: { if !$0 { pendingUninstall = nil } })) {
            Button(L("action.cancel"), role: .cancel) { pendingUninstall = nil }
            Button(L("action.uninstall"), role: .destructive) {
                if let version = pendingUninstall { vm.rustupAction("uninstall", version.version) }
                pendingUninstall = nil
            }
        } message: {
            Text(String(format: L("alert.uninstallRustMessage"), pendingUninstall?.version ?? ""))
        }
    }

    @ViewBuilder
    private var content: some View {
        if vm.rustupInstalled == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("rust.checkingManager")).foregroundStyle(.secondary)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if vm.rustupInstalled == false {
            VStack(alignment: .leading, spacing: 14) {
                Text(String(format: L("rust.managerIntro"), "rustup"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("action.install")) { vm.rustupSelfAction("install") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(30)
        } else {
            RustupVersionListView(vm: vm, installedOnly: true) { version in
                pendingUninstall = version
            }
        }
    }
}

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
