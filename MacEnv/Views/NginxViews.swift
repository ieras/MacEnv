import SwiftUI

struct NginxManagementView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var vm: NginxViewModel
    @State private var tab = 0
    @State private var editing: NginxVersion?
    @State private var fieldText = ""
    @State private var aliasEditing: NginxVersion?
    @State private var confirmReset = false
    @State private var confirmUninstall = false
    @State private var source = "Static"
    @State private var customPathEditor = false
    @State private var refreshing = false

    // 版本 / 路径 / 备注 / 环境变量 / 别名 / 服务 / 快捷启动 / 操作。
    // 宽度交给 DataTable 按容器反推：路径列权重最大，备注和别名次之。
    private var tableColumns: [TableColumn] {
        [TableColumn(title: L("column.version"), minWidth: 50),
         TableColumn(title: L("column.path"), minWidth: 120, weight: 6),
         TableColumn(title: L("column.note"), minWidth: 60, weight: 2),
         TableColumn(title: L("column.env"), minWidth: 56),
         TableColumn(title: L("column.alias"), minWidth: 60, weight: 2),
         TableColumn(title: L("column.service"), minWidth: 56),
         TableColumn(title: L("column.quickStart"), minWidth: 56),
         operationColumn]
    }

    var body: some View {
        ModulePage {
            SegmentedTabs(
                titles: [L("tab.service"), L("tab.versions"), L("tab.config"), L("tab.errorLog"), L("tab.accessLog")],
                selection: $tab
            )
        } content: {
            page
        }
        .onChange(of: tab) { value in
            if value == 2 { vm.loadConfig() }
            else if value == 3 { vm.loadLog("error") }
            else if value == 4 { vm.loadLog("access") }
        }
        .task { await vm.loadStatic() }
        .sheet(item: $editing) { version in
            VStack(alignment: .leading, spacing: 14) {
                Text("Nginx \(version.version) · " + L("column.note")).font(.headline)
                TextEditor(text: $fieldText).font(.system(.body, design: .monospaced)).frame(height: 150)
                HStack {
                    Spacer()
                    Button(L("action.cancel")) { editing = nil }
                    Button(L("action.save")) {
                        vm.notes[version.id] = fieldText
                        editing = nil
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: AppTheme.sheetWidth, height: AppTheme.sheetHeight)
        }
        .sheet(item: $aliasEditing) { version in AliasEditorView(vm: vm, version: version) }
        .sheet(isPresented: $customPathEditor) {
            CustomPathEditor(title: "Nginx", paths: $vm.customDirectories)
        }
        .alert(L("alert.resetConfigTitle"), isPresented: $confirmReset) {
            Button(L("action.cancel"), role: .cancel) {}
            Button(L("action.reset"), role: .destructive) {
                do {
                    vm.configText = try String(contentsOf: vm.defaultConfigURL, encoding: .utf8)
                    vm.saveConfig()
                } catch { app.state.message = error.localizedDescription }
            }
        } message: { Text(L("alert.resetConfigMessage")) }
        .alert(L("alert.uninstallNginxTitle"), isPresented: $confirmUninstall) {
            Button(L("action.cancel"), role: .cancel) {}
            Button(L("action.uninstall"), role: .destructive) { vm.brewAction("uninstall") }
        } message: { Text(L("alert.uninstallNginxMessage")) }
    }

    @ViewBuilder
    private var page: some View {
        switch tab {
        case 1: versionManager
        case 2: configPanel
        case 3, 4: logPanel
        default: serviceTable
        }
    }

    private var serviceTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Nginx").font(.title3)
                NginxIcon().frame(width: 22, height: 22)
                Button { customPathEditor = true } label: { Image(systemName: "folder.badge.plus") }
                    .help(L("action.customPathHint"))
                Spacer()
            }.panelHeader()
            Divider()
            DataTable(columns: tableColumns, rows: vm.versions, empty: L("message.noNginxInstalled")) { version in
                Button(version.version) { vm.selectedID = version.id }.buttonStyle(.borderless)
                Button { NSWorkspace.shared.open(version.directory) } label: { Text(tilde(version.directory.path)).lineLimit(1).truncationMode(.middle) }
                    .buttonStyle(.borderless).help(tilde(version.directory.path))
                let note = vm.notes[version.id, default: ""]
                Button(note.isEmpty ? L("action.add") : note) { fieldText = note; editing = version }
                    .buttonStyle(.borderless).lineLimit(1)
                EnvironmentVariableButton(membership: vm.pathMembership[version.id, default: .none]) { vm.togglePath(version) }
                    .disabled(app.state.busy)
                let names = vm.aliases[version.id, default: []].map(\.name).joined(separator: "、")
                Button(names.isEmpty ? L("action.add") : names) { aliasEditing = version }
                    .buttonStyle(.borderless).lineLimit(1)
                ServiceActionButtons(
                    running: vm.running(version),
                    name: "Nginx",
                    toggle: { Task { await vm.operate(vm.running(version) ? "stop" : "start", version) } },
                    restart: { Task { await vm.operate("restart", version) } }
                )
                .disabled(app.state.busy)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    let key = "nginx:" + version.id
                    app.setQuickStart(key, enabled: !app.state.quickStartTargets.contains(key))
                } label: {
                    Image(systemName: app.state.quickStartTargets.contains("nginx:" + version.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(app.state.quickStartTargets.contains("nginx:" + version.id) ? .blue : .secondary)
                }
                .buttonStyle(.borderless).help(L("action.quickStartHint"))
                Menu {
                    Button(L("tab.config")) { vm.selectedID = version.id; tab = 2 }
                    Button(L("tab.errorLog")) { tab = 3 }
                    Button(L("tab.accessLog")) { tab = 4 }
                    Divider()
                    Button(L("action.validate")) { Task { await vm.operate("validate", version) } }
                    Button(L("action.reloadConfig")) { Task { await vm.operate("reload", version) } }.disabled(!vm.running(version))
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
            }
        }
    }

    private var versionManager: some View {
        VStack(alignment: .leading, spacing: 0) {
            VersionManagerHeader(sources: ["Static", "Homebrew", "MacPorts"], source: $source,
                                 linkURL: URL(string: "https://nginx.org/en/download.html")!,
                                 busy: app.state.busy, refreshing: refreshing, onRefresh: {
                refreshing = true
                Task { await vm.refreshVersionManager(source, force: true); refreshing = false }
            }, actions: {
                if source == "Homebrew" { Button(L("action.updateBrew")) { vm.brewAction("update") }.disabled(app.state.busy) }
            })
            Divider()
            if source == "Homebrew" {
                if let formula = vm.formula {
                    // nginx 在 brew 里就一个公式，套成列表项走公共的 brew 列表。
                    BrewListView(formulae: [BrewFormulaItem(name: "nginx", stable: formula.version, installedVersions: formula.installedVersions,
                                                            linkedVersion: formula.linkedVersion, outdated: formula.outdated)],
                                 busy: app.state.busy) { action, _ in
                        if action == "uninstall" { confirmUninstall = true } else { vm.brewAction(action) }
                    }
                    if formula.versionedFormulae.isEmpty {
                        Text(L("brew.noVersionedFormulae"))
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }
                } else {
                    Text(L("brew.missing")).padding(24)
                    Link(L("brew.install"), destination: URL(string: "https://brew.sh")!).padding(.horizontal, 24)
                }
            } else if source == "MacPorts" {
                VStack(alignment: .leading, spacing: 12) {
                    Text(FileManager.default.isExecutableFile(atPath: "/opt/local/bin/port") ? L("macports.detectedNginx") : L("macports.missing"))
                    Link(L("macports.install"), destination: URL(string: "https://www.macports.org/install.php")!)
                }.padding(24)
            } else {
                StaticVersionListView(versions: vm.staticVersions, loading: vm.staticLoading) { vm.installStatic($0) } uninstall: { vm.uninstallStatic($0) }
            }
            Spacer()
        }
    }

    private var configPanel: some View {
        VStack(spacing: 0) {
            if !(vm.versions).isEmpty {
                HStack {
                    Picker(L("column.version"), selection: $vm.selectedID) {
                        ForEach(vm.versions) { version in Text(version.version).tag(version.id as String?) }
                    }
                    .pickerStyle(.menu)
                    Spacer()
                }
                .padding(.horizontal, 20).frame(height: 52)
                Divider()
            }
            CodeEditor(text: $vm.configText, editable: true)
            Divider()
            HStack {
                Button { NSWorkspace.shared.activateFileViewerSelecting([vm.configURL]) } label: { Image(systemName: "folder") }.help(L("config.openFolder"))
                Button { vm.saveConfig() } label: { Image(systemName: "square.and.arrow.down") }.help(L("action.save")).accessibilityLabel(L("action.save"))
                Button { vm.loadConfig() } label: { Image(systemName: "arrow.clockwise") }.help(L("action.reload"))
                Button { confirmReset = true } label: { Image(systemName: "arrow.counterclockwise") }.help(L("config.restoreDefault"))
                Spacer()
                Button(L("action.validate")) { if let version = vm.selectedVersion { Task { await vm.operate("validate", version) } } }.disabled(app.state.busy || vm.selectedVersion == nil)
                Button(L("action.saveAndReload")) {
                    vm.saveConfig()
                    if let version = vm.selectedVersion { Task { await vm.operate("reload", version) } }
                }.disabled(app.state.busy || !vm.isRunning)
            }.padding(18)
            Text(tilde(vm.configURL.path)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.bottom, 12)
        }
        .onAppear { vm.loadConfig() }
        .onChange(of: vm.selectedID) { _ in vm.loadConfig() }
    }

    private var logPanel: some View {
        VStack(spacing: 0) {
            if !(vm.versions).isEmpty {
                HStack {
                    Picker(L("column.version"), selection: $vm.selectedID) {
                        ForEach(vm.versions) { version in Text(version.version).tag(version.id as String?) }
                    }
                    .pickerStyle(.menu)
                    Spacer()
                }
                .padding(.horizontal, 20).frame(height: 52)
                Divider()
            }
            CodeEditor(text: $vm.logText, editable: false)
            Divider()
            HStack {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([tab == 3 ? vm.errorLogURL : vm.accessLogURL])
                } label: { Image(systemName: "folder") }.help(L("log.openFolder"))
                Button { vm.loadLog(tab == 3 ? "error" : "access") } label: { Image(systemName: "arrow.clockwise") }.help(L("action.refreshLog"))
                Spacer()
                Text(tab == 3 ? L("tab.errorLog") : L("tab.accessLog")).foregroundStyle(.secondary)
            }.padding(18)
        }
        .onAppear { vm.loadLog(tab == 3 ? "error" : "access") }
        .onChange(of: vm.selectedID) { _ in vm.loadLog(tab == 3 ? "error" : "access") }
    }
}

struct AliasEditorView: View {
    @ObservedObject var vm: NginxViewModel
    let version: NginxVersion
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var editingID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nginx \(version.version) · " + L("alias.title")).font(.headline)
            List {
                ForEach(vm.aliases[version.id, default: []]) { alias in
                    HStack {
                        Text(alias.name).textSelection(.enabled)
                        Spacer()
                        Button(L("action.edit")) { name = alias.name; editingID = alias.id }
                        Button(L("action.delete"), role: .destructive) { vm.deleteAlias(version, alias) }
                    }
                }
            }
            HStack {
                TextField(L("alias.placeholder"), text: $name)
                Button(editingID == nil ? L("action.add") : L("action.save")) {
                    vm.saveAlias(version, name: name, id: editingID)
                    name = ""; editingID = nil
                }.keyboardShortcut(.defaultAction)
            }
            HStack {
                Text(L("alias.directory") + tilde(vm.aliasDirectory.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(L("action.done")) { dismiss() }
            }
        }
        .padding(20).frame(width: AppTheme.sheetWidth, height: AppTheme.sheetHeight)
    }


}
