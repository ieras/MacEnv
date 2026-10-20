import SwiftUI

struct Neo4jManagementView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var vm: Neo4jViewModel
    // 没有兼容 JDK 时跳 Java 模块（装 / 卸 JDK 都在那儿）。ContentView 传入跳转闭包，其余调用方用默认空实现。
    var openJavaModule: () -> Void = {}
    @State private var tab = 0
    @State private var source = "Static"
    @State private var customPathEditor = false
    @State private var refreshing = false

    // 双端口列宽至少 80 的硬规矩见 AGENTS.md；java 列是 Picker，给点分量。
    private var tableColumns: [TableColumn] {
        [TableColumn(title: L("column.version"), minWidth: 50),
         TableColumn(title: L("column.path"), minWidth: 120, weight: 6),
         TableColumn(title: L("column.dataDir"), minWidth: 70, weight: 2),
         TableColumn(title: L("column.port"), minWidth: 80),
         TableColumn(title: L("column.java"), minWidth: 90, weight: 2),
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
            CustomPathEditor(title: "Neo4j", paths: Binding(get: { vm.customDirectories }, set: { vm.setCustomDirectories($0) }))
        }
        .onChange(of: tab) { value in
            if value == 2 { vm.loadConfig() }
            else if value == 3 { vm.loadLog() }
        }
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
                SelectableTitle(text: "Neo4j")
                Neo4jIcon().frame(width: 22, height: 22)
                Button { customPathEditor = true } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.borderless)
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
            DataTable(columns: tableColumns, rows: vm.versions,
                      empty: L("message.noDatabaseInstalled") + "Neo4j" + L("message.installOrAddPath")) { version in
                Button(version.version) { vm.selected = version.id }.buttonStyle(.borderless)
                Button { NSWorkspace.shared.open(version.directory) } label: {
                    Text(tilde(version.directory.path)).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.borderless).help(tilde(version.directory.path))
                Button { NSWorkspace.shared.open(vm.dataURL(version)) } label: {
                    Text(vm.dataURL(version).lastPathComponent).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless).lineLimit(1).help(tilde(vm.dataURL(version).path))
                Text(vm.port(version))
                javaCell(version)
                EnvironmentVariableButton(membership: vm.pathMembership[version.id] ?? .none) { vm.togglePath(version) }
                    .disabled(app.state.busy)
                ServiceActionButtons(
                    running: vm.running(version),
                    name: "Neo4j",
                    toggle: { Task { await vm.operate(vm.running(version) ? "stop" : "start", version) } },
                    restart: { Task { await vm.operate("restart", version) } }
                )
                .disabled(app.state.busy)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    app.setQuickStart(version.id, enabled: !app.state.quickStartTargets.contains(version.id))
                } label: {
                    Image(systemName: app.state.quickStartTargets.contains(version.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(app.state.quickStartTargets.contains(version.id) ? .blue : .secondary)
                }
                .buttonStyle(.borderless).help(L("action.quickStartHint"))
                Menu {
                    Button(L("neo4j.openBrowser")) { NSWorkspace.shared.open(URL(string: "http://localhost:\(vm.httpPort(version))")!) }
                    Button(L("config.openFile")) { tab = 2; vm.selected = version.id }
                    Button(L("tab.logs")) { vm.selected = version.id; tab = 3 }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
            }
        }
    }

    // Java 列：候选按策略表（Neo4jService.supportedJavaMajors）过滤后倒序排列，
    // 没候选就引导去 Java 模块 —— 装 / 卸 JDK 都归那个页面管。
    // 运行中禁用：换 JAVA_HOME 下次启动才生效，放着在跑的服务动它根基纯属捣乱。
    @ViewBuilder
    private func javaCell(_ version: Neo4jVersion) -> some View {
        let candidates = vm.javaCandidates(version)
        if candidates.isEmpty {
            Button(L("neo4j.installJava")) { openJavaModule() }
                .buttonStyle(.link)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Picker("", selection: Binding(get: { vm.selectedJava(version) }, set: { vm.setJava(version, $0) })) {
                // label 用完整版本号（"Java 21.0.12"）：大版本号就是第一段，
                // 同机多个同 major 的 JDK 靠补丁号区分，路径太长表格里放不下。
                ForEach(candidates, id: \.directory.path) { candidate in
                    Text("Java " + candidate.version).tag(candidate.directory.path)
                }
            }
            .disabled(vm.running(version))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // 只有一个来源：官方只发社区 tar.gz，brew 只有启动服务的 cask（公式接口查不到）。
    private var versionManager: some View {
        VStack(alignment: .leading, spacing: 0) {
            VersionManagerHeader(sources: ["Static"], source: $source,
                                 linkURL: URL(string: "https://neo4j.com/deployment-center/")!,
                                 busy: app.state.installBusy, refreshing: refreshing, onRefresh: {
                refreshing = true
                Task {
                    await vm.loadStatic(force: true)
                    await vm.refresh()
                    refreshing = false
                }
            }, actions: {})
            Divider()
            StaticVersionListView(versions: vm.staticVersions, loading: vm.staticLoading, busy: app.state.installBusy) { vm.installStatic($0) } uninstall: { vm.uninstallStatic($0) }
            Spacer()
        }
        .task { await vm.loadStatic() }
    }

    private var configPanel: some View {
        VStack(spacing: 0) {
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
                Text(L("message.selectDatabaseVersion") + "Neo4j" + L("message.version")).foregroundStyle(.secondary).padding(30)
            }
        }
        .onAppear { vm.loadConfig() }
        .onChange(of: vm.selected) { _ in vm.loadConfig() }
    }

    private var logPanel: some View {
        VStack(spacing: 0) {
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
