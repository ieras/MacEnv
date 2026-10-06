import SwiftUI

struct ContentView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var nginxVM: NginxViewModel
    @ObservedObject var databaseVM: DatabaseViewModel
    @ObservedObject var redisVM: RedisViewModel
    @ObservedObject var certVM: MkCertViewModel
    @ObservedObject var phpVM: PhpViewModel
    @ObservedObject var hostVM: HostViewModel
    @ObservedObject var goVM: GoViewModel
    @State private var selectedPage = "nginx"
    @State private var toastVisible = false
    @State private var toastDismissTask: Task<Void, Never>?
    @Environment(\.colorScheme) private var colorScheme

    private var themeTint: Color { AppTheme.tint(colorScheme) }

    private var sidebarSelection: Color { AppTheme.selection(colorScheme) }

    private var busy: Bool { app.state.busy }

    // 快捷启动里只要有一个在跑，电源键就是绿的；全关才是灰的。
    private var quickStartRunning: Bool { app.state.quickStartTargets.contains { app.targetRunning($0) } }

    // 模块开关关掉的条目不出现在侧栏；当前正看着的那页被关掉就回落到快捷启动，避免右侧白屏。
    private var page: String { (app.state.modules[selectedPage] ?? true) ? selectedPage : "quick-start" }

    // 侧栏那一行显示「在跑/总数」，比如 1/3。
    private var quickStartCountLabel: String {
        let total = app.state.quickStartTargets.count
        return "\(app.state.quickStartTargets.filter { app.targetRunning($0) }.count)/\(total)"
    }

    private func presentToast() {
        toastDismissTask?.cancel()
        toastVisible = true
        // 多行/长文案（多半是报错）给点时间看，普通 tips 3 秒就够。
        let seconds: UInt64 = (app.state.message.count > 40 || app.state.message.contains("\n")) ? 6 : 3
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
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
            if page == "quick-start" {
                QuickStartListView(app: app, nginxVM: nginxVM, databaseVM: databaseVM, phpVM: phpVM)
            } else if page == "php" {
                PhpManagementView(app: app, vm: phpVM)
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if page == "go" {
                GoManagementView(app: app, vm: goVM)
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if page == "hosts" {
                HostManagementView(app: app, vm: hostVM, certVM: certVM)
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if page == "redis" {
                RedisManagementView(app: app, vm: redisVM)
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let kind = DatabaseKind(rawValue: page) {
                DatabaseManagementView(app: app, vm: databaseVM, kind: kind)
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .id(kind)
            } else {
                NginxManagementView(app: app, vm: nginxVM)
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
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
        // 等待指示：浮在右上角、外观切换按钮正下方。工具栏那一排是系统标题栏的一部分，
        // SwiftUI 视图塞不进去（会被标题栏裁掉），所以落在其下方的浮层里。
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
        // 右下角浮层：长任务日志（跑完不自动消失）在上，短提示 toast 在下，两个都出现时摞着不打架。
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
        // 刷新完才有版本可起，所以自动拉服务必须排在 refreshAll 后面。
        .task {
            guard !isTesting else { return }
            await app.refreshAll()
            if app.state.autoStartService { app.launch(app.state.quickStartTargets) }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("sidebar.console")).font(.headline).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 12)
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.fill").frame(width: 20, height: 20)
                        Text(L("sidebar.quickStart"))
                        Spacer()
                        Text(quickStartCountLabel).foregroundStyle(.secondary).monospacedDigit()
                        // 电源键跟它管的东西待在同一行、最右侧：点一下起/停快捷启动里的全部服务。
                        Button {
                            app.launch(app.state.quickStartTargets, stop: quickStartRunning)
                        } label: {
                            Image(systemName: quickStartRunning ? "power.circle.fill" : "power.circle")
                                .foregroundStyle(quickStartRunning ? AppTheme.green : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(quickStartRunning ? L("menu.stopQuickStart") : L("menu.startQuickStart"))
                        .disabled(busy || app.state.quickStartTargets.isEmpty)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(page == "quick-start" ? sidebarSelection : .clear, in: RoundedRectangle(cornerRadius: AppTheme.radiusRow))
                    .contentShape(Rectangle()).onTapGesture { selectedPage = "quick-start" }

                    // 分组、条目顺序全读 moduleGroups，跟设置页的模块开关同一份配置。
                    // 控制台那一组的标题和快捷启动行上面已经画了，moduleGroups 里也不再有它。
                    ForEach(moduleGroups, id: \.0) { group in
                        Text(L(group.0)).font(.headline).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 12)
                        ForEach(group.1.filter { app.state.modules[$0] ?? true }, id: \.self) { moduleRow($0) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
    }

    // 一行侧栏条目：图标 + 名字 + 右侧（开关或数量），选中高亮和点击切页对所有模块都一样。
    private func moduleRow(_ id: String) -> some View {
        HStack(spacing: 8) {
            ModuleIcon(id: id).frame(width: 20, height: 20)
            Text(moduleName(id))
            Spacer()
            moduleTrailing(id)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(page == id ? sidebarSelection : .clear, in: RoundedRectangle(cornerRadius: AppTheme.radiusRow))
        .contentShape(Rectangle())
        .onTapGesture { selectedPage = id }
    }

    @ViewBuilder
    private func moduleTrailing(_ id: String) -> some View {
        switch id {
        // 站点、Go 都没有常驻进程，只显示数量。
        case "hosts": Text(String(hostVM.hosts.count)).foregroundStyle(.secondary)
        case "go": Text(String(goVM.versions.count)).foregroundStyle(.secondary)
        case "nginx":
            Toggle("", isOn: Binding(get: { nginxVM.isRunning }, set: { _ in
                if nginxVM.isRunning {
                    app.launch(app.launchTargets.filter { $0.kind == "nginx" }.map(\.key), stop: true)
                } else {
                    // 侧栏开关的启动规则：优先起勾了快捷启动的版本，没配就起版本号最大的。
                    let version = nginxVM.versions.first { app.state.quickStartTargets.contains("nginx:" + $0.id) }
                        ?? nginxVM.versions.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
                    if let version { nginxVM.selectedID = version.id; app.launch(["nginx:" + version.id]) }
                }
            }))
            .labelsHidden().toggleStyle(ServiceSwitch())
            .disabled(busy || nginxVM.versions.isEmpty)
            .help(L("sidebar.nginxToggleHint"))
        // php 是特例：一键把所有 php-fpm 版本全部拉起来（nginx 站点依赖 fpm）。
        case "php":
            Toggle("", isOn: Binding(get: { phpVM.fpmRunningAny }, set: { _ in
                Task { if phpVM.fpmRunningAny { await phpVM.stopAll() } else { await phpVM.startAll() } }
            }))
            .labelsHidden().toggleStyle(ServiceSwitch())
            .disabled(busy || phpVM.versions.isEmpty)
            .help(L("sidebar.phpToggleHint"))
        // Redis 同数据库：默认 6379，一次只跑一个版本。
        case "redis":
            Toggle("", isOn: Binding(get: { app.launchTargets.contains { $0.kind == "redis" && app.targetRunning($0.key) } }, set: { _ in
                let keys = app.launchTargets.filter { $0.kind == "redis" }.map(\.key)
                if keys.contains(where: { app.targetRunning($0) }) { app.launch(keys, stop: true) }
                else {
                    let version = redisVM.versions.first { app.state.quickStartTargets.contains($0.id) } ?? redisVM.versions.first
                    if let version { app.launch([version.id]) }
                }
            }))
            .labelsHidden().toggleStyle(ServiceSwitch())
            .disabled(busy || redisVM.versions.isEmpty)
            .help(L("sidebar.databaseToggleHint") + "Redis" + L("sidebar.version"))
        default:
            if let kind = DatabaseKind(rawValue: id) {
                Toggle("", isOn: Binding(get: { databaseVM.running(kind) }, set: { _ in
                    if databaseVM.running(kind) {
                        app.launch(app.launchTargets.filter { $0.kind == kind.rawValue }.map(\.key), stop: true)
                    } else {
                        // 同 Nginx：优先起勾了快捷启动的版本，没配就起版本号最大的。
                        // 数据库的 launch key 就是 version.id，没有前缀。
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

    private var targets: [LaunchTarget] {
        app.launchTargets.filter { app.state.quickStartTargets.contains($0.key) }
    }

    // 服务 / 环境变量 / 端口 / 操作。宽度交给 DataTable 按容器反推。
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
