import SwiftUI

struct PhpManagementView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var vm: PhpViewModel
    @State private var tab = 0
    @State private var source = "Static"
    @State private var customPathEditor = false
    @State private var confirmUninstall = false
    @State private var uninstallFormula: String?
    @State private var refreshing = false
    @State private var extensionTab = 0
    @State private var functionSearch = ""
    @State private var newFunction = ""
    @State private var addingFunction = false

    var body: some View {
        ModulePage {
            SegmentedTabs(
                titles: [L("tab.service"), L("tab.versions"), L("tab.phpIni"), L("tab.disableFunctions"),
                         L("tab.extensions"), L("tab.logs"), "Swoole CLI", "Composer"],
                selection: $tab
            )
        } content: {
            page
        }
        .onChange(of: tab) { tab in
            switch tab {
            case 2: vm.loadIni()
            case 3: vm.loadDisableFunctions()
            case 4: vm.loadExtensions()
            case 5: vm.loadLog()
            default: break
            }
        }
        .task { await vm.loadStatic() }
        .sheet(isPresented: $customPathEditor) { CustomPathEditor(title: "PHP", paths: $vm.customDirectories) }
        .alert(L("alert.uninstallPhpTitle"), isPresented: $confirmUninstall) {
            Button(L("action.cancel"), role: .cancel) { uninstallFormula = nil }
            Button(L("action.uninstall"), role: .destructive) {
                if let formula = uninstallFormula { vm.brewAction("uninstall", formula: formula) }
                uninstallFormula = nil
            }
        } message: { Text(String(format: L("alert.uninstallPhpMessage"), uninstallFormula ?? "")) }
        .alert(L("action.addFunction"), isPresented: $addingFunction) {
            TextField(L("disableFunctions.placeholder"), text: $newFunction)
            Button(L("action.cancel"), role: .cancel) { newFunction = "" }
            Button(L("action.add")) { vm.addDisableFunction(newFunction); newFunction = "" }
        } message: { Text(L("disableFunctions.hint")) }
    }

    @ViewBuilder
    private var page: some View {
        switch tab {
        case 1: versionManager
        case 2: iniPanel
        case 3: disableFunctionPanel
        case 4: extensionPanel
        case 5: logPanel
        case 6: SwoolePanel(app: app, vm: app.swooleVM)
        case 7: ComposerPanel(app: app, vm: app.composerVM)
        default: serviceTable
        }
    }

    private func panelHeader<Actions: View>(_ title: String, path: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.title3)
            Picker("", selection: $vm.selectedID) {
                ForEach(vm.versions) { version in Text(version.version).tag(version.id as String?) }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()
            Text(tilde(path)).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer()
            actions()
        }
        .panelHeader()
    }

    private var tableColumns: [TableColumn] {
        [TableColumn(title: L("column.version"), minWidth: 50),
         TableColumn(title: L("column.path"), minWidth: 120, weight: 6),
         TableColumn(title: L("column.source"), minWidth: 90, weight: 2),
         TableColumn(title: L("column.env"), minWidth: 56),
         TableColumn(title: L("column.service"), minWidth: 56),
         operationColumn]
    }

    private var serviceTable: some View {
        VStack(spacing: 0) {
            HStack {
                SelectableTitle(text: "PHP-FPM")
                PhpIcon().frame(width: 22, height: 22)
                Button { customPathEditor = true } label: { Image(systemName: "folder.badge.plus") }
                    .help(L("action.customPathHint"))
                Spacer()
                RefreshButton(refreshing: $refreshing, busy: app.state.busy) { await vm.refresh() }
            }.panelHeader()
            Divider()
            DataTable(columns: tableColumns, rows: vm.versions, empty: L("message.noPhpInstalled")) { version in
                let running = vm.fpmRunning(version)
                Button(version.version) { vm.selectedID = version.id }.buttonStyle(.borderless)
                Button { NSWorkspace.shared.open(version.directory) } label: { Text(tilde(version.directory.path)).lineLimit(1).truncationMode(.middle) }
                    .buttonStyle(.borderless).help(tilde(version.directory.path))
                Text(version.source)
                EnvironmentVariableButton(membership: vm.pathMembership[version.id, default: .none]) { vm.togglePath(version) }
                    .disabled(app.state.busy)
                ServiceActionButtons(
                    running: running,
                    name: "PHP-FPM \(version.version)",
                    toggle: { Task { await vm.operate(running ? "stop" : "start", version) } },
                    restart: { Task { await vm.operate("restart", version) } }
                )
                .disabled(app.state.busy)
                .frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    Button(L("action.openFolder")) { NSWorkspace.shared.open(version.directory) }
                    Button(L("action.editPhpIni")) { vm.selectedID = version.id; tab = 2 }
                    if let formula = version.formula {
                        Divider()
                        Button(L("action.uninstall")) {
                            uninstallFormula = formula
                            confirmUninstall = true
                        }
                    }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
            }
        }
    }

    private var versionManager: some View {
        VStack(alignment: .leading, spacing: 0) {
            VersionManagerHeader(sources: ["Static", "Homebrew", "MacPorts"], source: $source,
                                 linkURL: URL(string: "https://www.php.net/downloads.php")!,
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
            } else {
                StaticVersionListView(versions: vm.staticVersions, loading: vm.staticLoading, busy: app.state.installBusy) { vm.installStatic($0) } uninstall: { vm.uninstallStatic($0) }
            }
            Spacer()
        }
    }

    private var iniPanel: some View {
        VStack(spacing: 0) {
            panelHeader(L("tab.phpIni"), path: vm.iniPath) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: vm.iniPath)]) } label: { Image(systemName: "folder") }
                    .help(L("config.openFolder")).disabled(vm.iniPath.isEmpty)
                Button { vm.saveIni() } label: { Image(systemName: "square.and.arrow.down") }
                    .help(L("action.save")).disabled(vm.iniPath.isEmpty)
                Button { vm.loadIni() } label: { Image(systemName: "arrow.clockwise") }.help(L("action.reload"))
                if !vm.iniPath.isEmpty, !vm.iniExists {
                    Button(L("action.createIni")) { vm.createIni() }.disabled(app.state.busy || vm.selectedVersion == nil)
                }
            }
            Divider()
            CodeEditor(text: $vm.iniText, editable: true)
        }
        .onAppear { vm.loadIni() }
        .onChange(of: vm.selectedID) { _ in vm.loadIni() }
    }

    // MARK: - 禁用函数

    private var filteredFunctions: [PhpDisableFunction] {
        let key = functionSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return vm.disableFunctions }
        return vm.disableFunctions.filter { $0.name.lowercased().contains(key) }
    }

    private var disableFunctionPanel: some View {
        VStack(spacing: 0) {
            panelHeader(L("tab.disableFunctions"), path: vm.iniPath) {
                Button { vm.saveDisableFunctions() } label: { Image(systemName: "square.and.arrow.down") }
                    .help(L("action.save")).disabled(app.state.busy || vm.iniPath.isEmpty)
                Button { addingFunction = true } label: { Image(systemName: "plus") }.help(L("action.addFunction"))
            }
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("action.search"), text: $functionSearch).textFieldStyle(.plain)
                Text("\(vm.disableFunctions.filter(\.disabled).count) / \(vm.disableFunctions.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).frame(height: 48)
            Divider()
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(filteredFunctions) { item in
                        HStack {
                            Text(item.name).frame(maxWidth: .infinity, alignment: .leading)
                            Toggle("", isOn: Binding(get: { item.disabled },
                                                     set: { _ in vm.toggleDisableFunction(item) }))
                                .toggleStyle(ServiceSwitch()).labelsHidden()
                                .frame(width: 60, alignment: .leading)
                            Group {
                                if item.removable {
                                    Button { vm.removeDisableFunction(item) } label: { Image(systemName: "trash") }
                                        .buttonStyle(.borderless).help(L("action.delete"))
                                }
                            }
                            .frame(width: 60, alignment: .leading)
                        }
                        .padding(.horizontal, 20).frame(minHeight: 52)
                        Divider()
                    }
                    if filteredFunctions.isEmpty {
                        Text(L("message.noFunctionMatched")).foregroundStyle(.secondary).padding(30)
                    }
                }
            }
            .scrollIndicators(.visible)
        }
        .font(.callout).lineLimit(1)
        .onAppear { vm.loadDisableFunctions() }
        .onChange(of: vm.selectedID) { _ in vm.loadDisableFunctions() }
    }

    // MARK: - 扩展

    private var extensionPanel: some View {
        VStack(spacing: 0) {
            panelHeader(L("tab.extensions"),
                        path: vm.extensionDirectory.isEmpty ? L("extensions.unsupported") : vm.extensionDirectory) {
                Button { vm.loadExtensions() } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("action.reload")).disabled(vm.extensionsLoading)
            }
            Divider()
            HStack {
                SegmentedTabs(titles: [L("extensions.loaded"), L("extensions.available")], selection: $extensionTab)
                    .frame(width: 180)
                Spacer()
                SegmentedTabs(items: [(L("extensions.sourceBrew"), "brew"), (L("extensions.sourceMacPorts"), "macports")],
                              selection: Binding(get: { vm.extensionSource }, set: { vm.extensionSource = $0 }))
                    .frame(width: 220)
            }
            .padding(.horizontal, 20).frame(height: 52)
            Divider()
            if extensionTab == 0 { loadedExtensionList } else { availableExtensionList }
        }
        .font(.callout).lineLimit(1)
        .onAppear { vm.loadExtensions() }
        .onChange(of: vm.selectedID) { _ in vm.loadExtensions() }
    }

    private var loadedExtensionList: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(vm.loadedExtensions, id: \.self) { name in
                    HStack {
                        Text(name).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "checkmark").foregroundStyle(AppTheme.green)
                    }
                    .padding(.horizontal, 20).frame(minHeight: 48)
                    Divider()
                }
                if vm.loadedExtensions.isEmpty {
                    Text(L("extensions.noneLoaded")).foregroundStyle(.secondary).padding(30)
                }
            }
        }
        .scrollIndicators(.visible)
    }

    private var availableExtensionList: some View {
        VStack(spacing: 0) {
            if vm.extensionSource == "macports" && !vm.macportsAvailable {
                Text(L("tools.missingMacPorts")).foregroundStyle(.secondary)
                    .padding(30).frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            } else if vm.extensionSource == "macports" && !vm.macportsUsable {
                Text(L("extensions.macportsMismatch")).foregroundStyle(.secondary)
                    .padding(30).frame(maxWidth: .infinity, alignment: .leading)
            } else if vm.extensionDirectory.isEmpty {
                Text(L("extensions.unsupportedHint")).foregroundStyle(.secondary)
                    .padding(30).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack {
                    Text(L("column.library")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(L("column.status")).frame(width: 100, alignment: .leading)
                    Text(L("column.operation")).frame(width: 200, alignment: .leading)
                }
                .foregroundStyle(.secondary).font(.body.weight(.semibold))
                .padding(.horizontal, 20).frame(height: 56)
                Divider()
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.availableExtensions) { item in
                            HStack {
                                Text(item.name).frame(maxWidth: .infinity, alignment: .leading)
                                Text(statusText(item))
                                    .foregroundStyle(item.enabled ? AppTheme.green : Color.secondary)
                                    .frame(width: 100, alignment: .leading)
                                HStack(spacing: 16) {
                                    if !item.installed {
                                        Button(L("action.install")) { vm.installExtension(item) }
                                    } else if item.enabled {
                                        Button(L("action.disable")) { vm.disableExtension(item) }
                                        Button(L("action.uninstall")) { vm.removeExtension(item) }
                                    } else {
                                        Button(L("action.enable")) { vm.enableExtension(item) }
                                        Button(L("action.uninstall")) { vm.removeExtension(item) }
                                    }
                                }
                                .buttonStyle(.borderless).disabled(app.state.busy)
                                .frame(width: 200, alignment: .leading)
                            }
                            .padding(.horizontal, 20).frame(minHeight: 56)
                            Divider()
                        }
                        if vm.availableExtensions.isEmpty {
                            Text(L("extensions.empty")).foregroundStyle(.secondary).padding(30)
                        }
                    }
                }
                .scrollIndicators(.visible)
            }
        }
    }

    private func statusText(_ item: PhpExtension) -> String {
        if !item.installed { return L("brew.notInstalled") }
        return item.enabled ? L("status.enabled") : L("status.installedNotEnabled")
    }

    // MARK: - 日志

    private var logPanel: some View {
        VStack(spacing: 0) {
            panelHeader(L("tab.logs"), path: vm.logPath) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: vm.logPath)]) } label: { Image(systemName: "folder") }
                    .help(L("log.openFolder")).disabled(vm.logPath.isEmpty)
                Button { vm.loadLog() } label: { Image(systemName: "arrow.clockwise") }.help(L("action.refreshLog"))
            }
            Divider()
            HStack {
                SegmentedTabs(items: [(L("log.fpm"), "fpm"), (L("log.slow"), "slow"),
                                      (L("log.start"), "start"), (L("log.iniError"), "ini")],
                              selection: Binding(get: { vm.logKind }, set: { vm.loadLog($0) }))
                    .frame(width: 360)
                Spacer()
            }
            .padding(.horizontal, 20).frame(height: 52)
            Divider()
            CodeEditor(text: $vm.logText, editable: false)
        }
        .font(.callout)
        .onAppear { vm.loadLog() }
        .onChange(of: vm.selectedID) { _ in vm.loadLog() }
    }
}
