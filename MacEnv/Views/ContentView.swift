import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var nginxVM: NginxViewModel
    @ObservedObject var databaseVM: DatabaseViewModel
    @ObservedObject var redisVM: RedisViewModel
    @ObservedObject var certVM: MkCertViewModel
    @ObservedObject var phpVM: PhpViewModel
    @ObservedObject var hostVM: HostViewModel
    @ObservedObject var goVM: GoViewModel
    @ObservedObject var erlangVM: ErlangViewModel
    @ObservedObject var postgresVM: PostgresViewModel
    @ObservedObject var clickhouseVM: ClickHouseViewModel
    @ObservedObject var qdrantVM: QdrantViewModel
    @ObservedObject var neo4jVM: Neo4jViewModel
    @ObservedObject var rabbitmqVM: RabbitMQViewModel
    @ObservedObject var consulVM: ConsulViewModel
    @ObservedObject var etcdVM: EtcdViewModel
    @ObservedObject var minioVM: MinioViewModel
    @ObservedObject var rustfsVM: RustFSViewModel
    @ObservedObject var kafkaVM: KafkaViewModel
    @State private var selectedPage = "nginx"
    @State private var toastVisible = false
    @State private var toastDismissTask: Task<Void, Never>?
    @Environment(\.colorScheme) private var colorScheme

    private var themeTint: Color { AppTheme.tint(colorScheme) }

    private var busy: Bool { app.state.busy }

    private var quickStartTargets: [LaunchTarget] { app.quickStartLaunchTargets }

    private var quickStartKeys: [String] { quickStartTargets.map(\.key) }

    private var quickStartRunning: Bool { quickStartTargets.contains { app.targetRunning($0.key) } }

    private var quickStartCountLabel: String {
        "\(quickStartTargets.filter { app.targetRunning($0.key) }.count)/\(quickStartTargets.count)"
    }

    private var page: String { (app.state.modules[selectedPage] ?? true) ? selectedPage : "quick-start" }

    private func presentToast() {
        toastDismissTask?.cancel()
        toastVisible = true
        let seconds: UInt64 = (app.state.message.count > 40 || app.state.message.contains("\n")) ? 6 : 3
        toastDismissTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
            toastVisible = false
        }
    }

    private func dismissToast() {
        toastDismissTask?.cancel()
        toastVisible = false
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            Group {
                if page == "quick-start" {
                    QuickStartListView(app: app, nginxVM: nginxVM, databaseVM: databaseVM, phpVM: phpVM)
                } else if page == "tools" {
                    ToolsView(app: app, vm: app.toolsVM)
                } else if page == "php" {
                    PhpManagementView(app: app, vm: phpVM)
                } else if page == "go" {
                    GoManagementView(app: app, vm: goVM)
                } else if page == "erlang" {
                    ErlangManagementView(app: app, vm: erlangVM)
                } else if page == "java" {
                    JavaManagementView(app: app, vm: app.javaVM)
                } else if page == "python" {
                    PythonManagementView(app: app, vm: app.pythonVM)
                } else if page == "node" {
                    NodeManagementView(app: app, vm: app.nodeVM)
                } else if page == "rust" {
                    RustManagementView(app: app, vm: app.rustVM)
                } else if page == "hosts" {
                    HostManagementView(app: app, vm: hostVM, certVM: certVM)
                } else if page == "redis" {
                    RedisManagementView(app: app, vm: redisVM)
                } else if page == "postgresql" {
                    PostgresManagementView(app: app, vm: postgresVM)
                } else if page == "clickhouse" {
                    ClickHouseManagementView(app: app, vm: clickhouseVM)
                } else if page == "qdrant" {
                    QdrantManagementView(app: app, vm: qdrantVM)
                } else if page == "neo4j" {
                    Neo4jManagementView(app: app, vm: neo4jVM) { selectedPage = "java" }
                } else if page == "rabbitmq" {
                    RabbitMQManagementView(app: app, vm: rabbitmqVM) { selectedPage = "erlang" }
                } else if page == "consul" {
                    ConsulManagementView(app: app, vm: consulVM)
                } else if page == "etcd" {
                    EtcdManagementView(app: app, vm: etcdVM)
                } else if page == "minio" {
                    MinioManagementView(app: app, vm: minioVM)
                } else if page == "rustfs" {
                    RustFSManagementView(app: app, vm: rustfsVM)
                } else if page == "kafka" {
                    KafkaManagementView(app: app, vm: kafkaVM) { selectedPage = "java" }
                } else if let kind = DatabaseKind(rawValue: page) {
                    DatabaseManagementView(app: app, vm: databaseVM, kind: kind).id(kind)
                } else {
                    NginxManagementView(app: app, vm: nginxVM)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle(L("app.name"))
        .toolbar {
            ToolbarItem {
                Button {
                    switch app.state.theme {
                    case .automatic: app.state.theme = .light
                    case .light: app.state.theme = .dark
                    case .dark: app.state.theme = .automatic
                    }
                    app.state.applyTheme()
                } label: { Image(systemName: app.state.theme.iconName) }
                .help(L("settings.appearance") + "：" + app.state.theme.title)
                .accessibilityLabel(L("settings.appearance") + "：" + app.state.theme.title)
            }
        }
        .tint(themeTint)
        .overlay(alignment: .topTrailing) {
            if busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("message.working")).font(.callout)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(AppTheme.stroke))
                .padding(.top, 10).padding(.trailing, 18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 12) {
                if let task = app.state.task {
                    TaskLogOverlay(task: task, cancel: { app.state.cancelTask() }, dismiss: { app.state.dismissTask() })
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if toastVisible {
                    ToastCard(text: app.state.message) { dismissToast() }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(20)
        }
        .animation(.easeOut(duration: 0.18), value: busy)
        .animation(.easeOut(duration: 0.18), value: toastVisible)
        .animation(.easeOut(duration: 0.18), value: app.state.task != nil)
        .onChange(of: app.state.messageToken) { _ in presentToast() }
        .task {
            guard !isTesting else { return }
            await app.refreshAll()
            if app.state.autoStartService { app.launch(quickStartKeys) }
        }
    }

    private var sidebar: some View {
        List(selection: Binding<String?>(
            get: { page },
            set: { newValue in if let newValue { selectedPage = newValue } }
        )) {
            Section {
                quickStartRow
                ForEach(consoleModules.filter { app.state.modules[$0] ?? true }, id: \.self) { moduleRow($0) }
            } header: {
                sectionTitle(L("sidebar.console"))
            }
            ForEach(moduleGroups, id: \.0) { group in
                Section {
                    ForEach(group.1.filter { app.state.modules[$0] ?? true }, id: \.self) { moduleRow($0) }
                } header: {
                    sectionTitle(L(group.0))
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .background(SidebarSelectionHighlightOff())
        .background(AppTheme.windowBackground)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationSplitViewColumnWidth(min: 232, ideal: 252, max: 300)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.headline).foregroundStyle(.secondary)
    }

    private struct SidebarSelectionHighlightOff: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { Probe() }
        func updateNSView(_ nsView: NSView, context: Context) {}

        private final class Probe: NSView {
            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                DispatchQueue.main.async { [weak self] in
                    guard let root = self?.window?.contentView else { return }
                    Self.turnOff(root)
                    DispatchQueue.main.async { [weak self] in
                        guard let root = self?.window?.contentView else { return }
                        Self.turnOff(root)
                    }
                }
            }

            private static func turnOff(_ view: NSView) {
                if let outline = view as? NSOutlineView { outline.selectionHighlightStyle = .none }
                for sub in view.subviews { turnOff(sub) }
            }
        }
    }

    private func rowBackground(_ id: String) -> some View {
        RoundedRectangle(cornerRadius: AppTheme.radiusRow)
            .fill(page == id ? themeTint : Color.clear)
            .padding(.horizontal, 8)
    }

    private var quickStartRow: some View {
        HStack(spacing: 8) {
            AssetIcon(name: "StartIcon").frame(width: 20, height: 20)
            Text(L("sidebar.quickStart"))
                .foregroundStyle(page == "quick-start" ? Color.white : Color.primary)
            Spacer()
            Text(quickStartCountLabel)
                .foregroundStyle(page == "quick-start" ? Color.white.opacity(0.85) : Color.secondary)
                .monospacedDigit()
            Button {
                app.launch(quickStartKeys, stop: quickStartRunning)
            } label: {
                Image(systemName: quickStartRunning ? "power.circle.fill" : "power.circle")
                    .foregroundStyle(quickStartRunning ? AppTheme.green
                                     : (page == "quick-start" ? Color.white.opacity(0.85) : Color.secondary))
            }
            .buttonStyle(.borderless)
            .help(quickStartRunning ? L("menu.stopQuickStart") : L("menu.startQuickStart"))
            .disabled(busy || quickStartTargets.isEmpty)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowBackground(rowBackground("quick-start"))
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .tag("quick-start")
    }

    private func moduleRow(_ id: String) -> some View {
        HStack(spacing: 8) {
            ModuleIcon(id: id).frame(width: 20, height: 20)
            Text(moduleName(id))
                .foregroundStyle(page == id ? Color.white : Color.primary)
                .fixedSize(horizontal: true, vertical: false)
            Spacer()
            moduleTrailing(id, selected: page == id)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowBackground(rowBackground(id))
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .tag(id)
    }

    @ViewBuilder
    private func moduleTrailing(_ id: String, selected: Bool) -> some View {
        let badge = selected ? Color.white.opacity(0.85) : Color.secondary
        switch id {
        case "hosts": Text(String(hostVM.hosts.count)).foregroundStyle(badge)
        case "go": Text(String(goVM.versions.count)).foregroundStyle(badge)
        case "java": Text(String(app.javaVM.versions.count)).foregroundStyle(badge)
        case "python": Text(String(app.pythonVM.versions.count)).foregroundStyle(badge)
        case "node": Text(String(app.nodeVM.versions.count)).foregroundStyle(badge)
        case "rust": Text(String(app.rustVM.versions.count)).foregroundStyle(badge)
        case "erlang": Text(String(erlangVM.versions.count)).foregroundStyle(badge)
        case "nginx":
            Toggle("", isOn: Binding(get: { nginxVM.isRunning }, set: { _ in
                if nginxVM.isRunning {
                    app.launch(app.launchTargets.filter { $0.kind == "nginx" }.map(\.key), stop: true)
                } else {
                    let version = nginxVM.versions.first { app.state.quickStartTargets.contains("nginx:" + $0.id) }
                        ?? nginxVM.versions.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
                    if let version { nginxVM.selectedID = version.id; app.launch(["nginx:" + version.id]) }
                }
            }))
            .labelsHidden().toggleStyle(ServiceSwitch())
            .disabled(busy || nginxVM.versions.isEmpty)
            .help(L("sidebar.nginxToggleHint"))
        case "php":
            Toggle("", isOn: Binding(get: { phpVM.fpmRunningAny }, set: { _ in
                Task { if phpVM.fpmRunningAny { await phpVM.stopAll() } else { await phpVM.startAll() } }
            }))
            .labelsHidden().toggleStyle(ServiceSwitch())
            .disabled(busy || phpVM.versions.isEmpty)
            .help(L("sidebar.phpToggleHint"))
        case "redis", "consul", "etcd", "postgresql", "clickhouse", "qdrant", "neo4j", "rabbitmq", "minio", "rustfs", "kafka":
            if let entry = app.entry(id) {
                Toggle("", isOn: Binding(
                    get: { entry.targets.contains { app.targetRunning($0.key) } },
                    set: { _ in
                        let keys = entry.targets.map(\.key)
                        if keys.contains(where: { app.targetRunning($0) }) { app.launch(keys, stop: true) }
                        else if let target = entry.preferredTarget(quickStart: app.state.quickStartTargets) { app.launch([target.key]) }
                    }))
                .labelsHidden().toggleStyle(ServiceSwitch())
                .disabled(busy || entry.targets.isEmpty)
                .help(L("sidebar.databaseToggleHint") + moduleName(id) + L("sidebar.version"))
            }
        default:
            if let kind = DatabaseKind(rawValue: id) {
                Toggle("", isOn: Binding(get: { databaseVM.running(kind) }, set: { _ in
                    if databaseVM.running(kind) {
                        app.launch(app.launchTargets.filter { $0.kind == kind.rawValue }.map(\.key), stop: true)
                    } else {
                        let all = databaseVM.versions[kind] ?? []
                        let version = all.first { app.state.quickStartTargets.contains($0.id) }
                            ?? all.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
                        if let version { databaseVM.selected[kind] = version.id; app.launch([version.id]) }
                    }
                }))
                .labelsHidden().toggleStyle(ServiceSwitch())
                .disabled(busy || databaseVM.selectedVersion(kind) == nil)
                .help(L("sidebar.databaseToggleHint") + kind.title + L("sidebar.version"))
            }
        }
    }
}

struct QuickStartListView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var nginxVM: NginxViewModel
    @ObservedObject var databaseVM: DatabaseViewModel
    @ObservedObject var phpVM: PhpViewModel

    private var targets: [LaunchTarget] { app.quickStartLaunchTargets }

    private var tableColumns: [TableColumn] {
        [TableColumn(title: L("column.service"), minWidth: 110, weight: 1),
         TableColumn(title: L("column.env"), minWidth: 90, weight: 2),
         TableColumn(title: L("column.port"), minWidth: 60),
         TableColumn(title: L("column.operation"), minWidth: 100)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DataTable(columns: tableColumns, rows: targets, empty: L("message.quickStartEmpty")) { target in
                let running = app.targetRunning(target.key)
                HStack(spacing: 10) {
                    ServiceIcon(kind: target.kind).frame(width: 22, height: 22)
                    Text(target.title)
                }
                pathButton(target)
                Text(app.port(target))
                ServiceActionButtons(
                    running: running,
                    name: target.title,
                    toggle: { toggle(target, running: running) },
                    restart: { restart(target) }
                )
                .disabled(app.state.busy)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: AppTheme.radiusPanel))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusPanel).stroke(AppTheme.stroke))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
        .background(AppTheme.windowBackground)
    }

    private func pathButton(_ target: LaunchTarget) -> some View {
        EnvironmentVariableButton(membership: app.entry(target.kind)?.membership(target.versionID) ?? .none) {
            app.entry(target.kind)?.togglePath(target.versionID)
        }
        .disabled(app.state.busy)
    }

    private func toggle(_ target: LaunchTarget, running: Bool) {
        Task { await app.entry(target.kind)?.operate(running ? "stop" : "start", target.versionID) }
    }

    private func restart(_ target: LaunchTarget) {
        Task { await app.entry(target.kind)?.operate("restart", target.versionID) }
    }
}
