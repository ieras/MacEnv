import SwiftUI

struct RabbitMQManagementView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var vm: RabbitMQViewModel
    var openErlangModule: () -> Void = {}
    @State private var tab = 0
    @State private var source = "Static"
    @State private var customPathEditor = false
    @State private var refreshing = false
    @State private var confirmUninstall = false
    @State private var uninstallFormula: String?

    private var tableColumns: [TableColumn] {
        [TableColumn(title: L("column.version"), minWidth: 50),
         TableColumn(title: L("column.path"), minWidth: 120, weight: 6),
         TableColumn(title: L("column.dataDir"), minWidth: 70, weight: 2),
         TableColumn(title: L("column.port"), minWidth: 80),
         TableColumn(title: L("column.erlang"), minWidth: 90, weight: 2),
         TableColumn(title: L("column.env"), minWidth: 56),
         TableColumn(title: L("column.service"), minWidth: 56),
         TableColumn(title: L("column.quickStart"), minWidth: 56),
         operationColumn]
    }

    var body: some View {
        ModulePage {
            SegmentedTabs(titles: [L("tab.service"), L("tab.versions"), L("tab.config"), L("tab.logs")], selection: $tab)
        } content: {
            page
        }
        .sheet(isPresented: $customPathEditor) {
            CustomPathEditor(title: "RabbitMQ", paths: Binding(get: { vm.customDirectories }, set: { vm.setCustomDirectories($0) }))
        }
        .onChange(of: tab) { value in
            if value == 2 { vm.loadConfig() }
            else if value == 3 { vm.loadLog() }
        }
        .alert(L("alert.uninstallRabbitMQTitle"), isPresented: $confirmUninstall) {
            Button(L("action.cancel"), role: .cancel) { uninstallFormula = nil }
            Button(L("action.uninstall"), role: .destructive) {
                if let formula = uninstallFormula { vm.brewAction("uninstall", formula: formula) }
                uninstallFormula = nil
            }
        } message: { Text(String(format: L("alert.uninstallRabbitMQMessage"), uninstallFormula ?? "")) }
        .task {
            await vm.refresh()
        }
    }

    @ViewBuilder
    private var page: some View {
        switch tab {
        case 1: versionManager
        case 2: configPanel
        case 3: logPanel
        default: serviceTable
        }
    }

    private var serviceTable: some View {
        VStack(spacing: 0) {
            HStack {
                SelectableTitle(text: "RabbitMQ")
                RabbitMQIcon().frame(width: 22, height: 22)
                Button { customPathEditor = true } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.borderless)
                    .help(L("action.customPathHint"))
                Spacer()
                RefreshButton(refreshing: $refreshing, busy: app.state.busy) { await vm.refresh() }
            }
            .panelHeader()
            Divider()
            DataTable(columns: tableColumns, rows: vm.versions,
                      empty: L("message.noDatabaseInstalled") + "RabbitMQ" + L("message.installOrAddPath")) { version in
                Button(version.version) { vm.selected = version.id }.buttonStyle(.borderless)
                Button { NSWorkspace.shared.open(version.directory) } label: {
                    Text(tilde(version.directory.path)).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.borderless).help(tilde(version.directory.path))
                Button { NSWorkspace.shared.open(vm.mnesiaURL(version)) } label: {
                    Text(vm.mnesiaURL(version).lastPathComponent).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless).lineLimit(1).help(tilde(vm.mnesiaURL(version).path))
                Text(vm.port(version))
                erlangCell(version)
                EnvironmentVariableButton(membership: vm.pathMembership[version.id] ?? .none) { vm.togglePath(version) }
                    .disabled(app.state.busy)
                ServiceActionButtons(
                    running: vm.running(version),
                    name: "RabbitMQ",
                    toggle: { Task { await vm.operate(vm.running(version) ? "stop" : "start", version) } },
                    restart: { Task { await vm.operate("restart", version) } }
                )
                .disabled(app.state.busy)
                .frame(maxWidth: .infinity, alignment: .leading)
                QuickStartCheckButton(app: app, key: version.id)
                Menu {
                    Button(L("rabbitmq.openManager")) { NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(vm.managementPort(version))")!) }
                    Button(L("config.openFile")) { tab = 2; vm.selected = version.id }
                    Button(L("tab.logs")) { vm.selected = version.id; tab = 3 }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
            }
        }
    }

    @ViewBuilder
    private func erlangCell(_ version: RabbitMQVersion) -> some View {
        let candidates = vm.erlangCandidates(version)
        if candidates.isEmpty {
            Button(L("rabbitmq.installErlang")) { openErlangModule() }
                .buttonStyle(.link)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Picker("", selection: Binding(get: { vm.selectedErlang(version) }, set: { vm.setErlang(version, $0) })) {
                ForEach(candidates, id: \.directory.path) { candidate in
                    Text("Erlang " + candidate.version).tag(candidate.directory.path)
                }
            }
            .disabled(vm.running(version))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var versionManager: some View {
        VStack(alignment: .leading, spacing: 0) {
            VersionManagerHeader(sources: ["Static", "Homebrew", "MacPorts"], source: $source,
                                 linkURL: URL(string: "https://www.rabbitmq.com/docs/install-generic-unix")!,
                                 busy: app.state.installBusy, refreshing: refreshing, onRefresh: {
                refreshing = true
                Task {
                    await vm.loadStatic(force: true)
                    await vm.refresh()
                    refreshing = false
                }
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
        .task { await vm.loadStatic() }
    }

    @ViewBuilder
    private var versionPicker: some View {
        if !vm.versions.isEmpty {
            HStack {
                Picker(L("column.version"), selection: $vm.selected) {
                    ForEach(vm.versions) { version in Text(version.version).tag(version.id) }
                }
                .pickerStyle(.menu)
                Spacer()
            }
            .padding(.horizontal, 20).frame(height: 52)
            Divider()
        }
    }

    private var configPanel: some View {
        VStack(spacing: 0) {
            versionPicker
            if let version = vm.selectedVersion() {
                CodeEditor(text: $vm.configText, editable: true)
                Divider()
                HStack {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([vm.configURL(version)]) } label: { Image(systemName: "folder") }.help(L("config.openFolder"))
                    Button { vm.saveConfig() } label: { Image(systemName: "square.and.arrow.down") }.help(L("action.save"))
                    Button { vm.loadConfig() } label: { Image(systemName: "arrow.clockwise") }.help(L("action.reload"))
                    Spacer()
                    Button(L("action.save")) { vm.saveConfig() }.disabled(app.state.busy)
                }.padding(18)
                Text(tilde(vm.configURL(version).path)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.bottom, 12)
            } else {
                Text(L("message.selectDatabaseVersion") + "RabbitMQ" + L("message.version")).foregroundStyle(.secondary).padding(30)
            }
        }
        .onAppear { vm.loadConfig() }
        .onChange(of: vm.selected) { _ in vm.loadConfig() }
    }

    private var logPanel: some View {
        VStack(spacing: 0) {
            versionPicker
            CodeEditor(text: $vm.logText, editable: false)
            Divider()
            HStack {
                Button {
                    if let url = vm.logURL() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                } label: { Image(systemName: "folder") }.help(L("log.openFolder"))
                Button { vm.loadLog() } label: { Image(systemName: "arrow.clockwise") }.help(L("action.refreshLog"))
                Spacer()
                Text(L("tab.logs")).foregroundStyle(.secondary)
            }.padding(18)
            if let url = vm.logURL() {
                Text(tilde(url.path)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.horizontal, 18).padding(.bottom, 12)
            }
        }
        .onAppear { vm.loadLog() }
        .onChange(of: vm.selected) { _ in vm.loadLog() }
    }
}
