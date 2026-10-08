import SwiftUI

// 托盘面板：MenuBarExtra(.window) 点状态栏图标弹出的浮层，全 SwiftUI。
// 开关 / 图标 / 颜色直接复用侧栏同款组件（ServiceSwitch / ServiceIcon / AppTheme），
// 保证托盘和主窗口的操作手感完全一致；启停逻辑统一走 AppViewModel（toggleKind / launch）。
struct TrayMenuView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var nginxVM: NginxViewModel
    @ObservedObject var databaseVM: DatabaseViewModel
    @ObservedObject var phpVM: PhpViewModel
    @ObservedObject var redisVM: RedisViewModel
    @ObservedObject var postgresVM: PostgresViewModel
    @ObservedObject var clickhouseVM: ClickHouseViewModel
    @ObservedObject var qdrantVM: QdrantViewModel
    @ObservedObject var consulVM: ConsulViewModel
    @ObservedObject var etcdVM: EtcdViewModel
    @Environment(\.dismiss) private var dismiss

    private var busy: Bool { app.state.busy }

    // 已勾的快捷启动项。它们出现在上面的独立段落里，下面的分组段就不再重复。
    private var quickTargets: [LaunchTarget] {
        app.launchTargets.filter { app.state.quickStartTargets.contains($0.key) }
    }

    // 分组段：照搬 moduleGroups 的分组与顺序（侧栏同款标题）。
    // 滤掉无服务的模块（hosts/go/java/python 这些没有 ServiceManageable），再滤掉已在快捷启动段出现过的 kind；
    // 整组滤空就连标题一起不画（比如 redis 勾了快捷启动，「缓存与队列」组整组消失）。
    private var groups: [(title: String, kinds: [String])] {
        let quickKinds = Set(quickTargets.map(\.kind))
        return moduleGroups.compactMap { key, ids in
            let kinds = ids.filter { app.entry($0) != nil && !quickKinds.contains($0) }
            return kinds.isEmpty ? nil : (L(key), kinds)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            masterRow
            separator
            if !quickTargets.isEmpty {
                ForEach(quickTargets) { target in
                    toggleRow(title: target.title, kind: target.kind, isOn: app.targetRunning(target.key)) {
                        app.launch([target.key], stop: app.targetRunning(target.key))
                    }
                }
                separator
            }
            ForEach(groups, id: \.title) { group in
                Text(group.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                ForEach(group.kinds, id: \.self) { kind in
                    kindRow(kind)
                }
                separator
            }
            bottomRows
        }
        .padding(12)
        .frame(width: 280)
    }

    // 顶部电源行 = 快捷启动总开关：一键启停全部已勾项。
    private var masterRow: some View {
        let anyRunning = app.state.quickStartTargets.contains { app.targetRunning($0) }
        return HStack(spacing: 8) {
            Image(systemName: "power")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(anyRunning ? AppTheme.green : Color.secondary)
                .frame(width: 20)
            Text(L("sidebar.quickStart"))
                .font(.callout)
                .fontWeight(.medium)
                .lineLimit(1)
            Spacer()
            Toggle("", isOn: Binding(get: { anyRunning }, set: { _ in
                app.launch(app.state.quickStartTargets, stop: anyRunning)
            }))
            .labelsHidden()
            .toggleStyle(ServiceSwitch())
            .disabled(busy || app.state.quickStartTargets.isEmpty)
        }
        .frame(height: 30)
        .contentShape(Rectangle())
    }

    // 分组段的一行：标题 = 点开关会起的那个版本的 target.title（与 toggleKind 的选择一致）。
    // PHP 是特例：开关 = 全部 php-fpm 全起/全停（同侧栏），版本号无意义，只显示模块名。
    private func kindRow(_ kind: String) -> some View {
        let targets = app.launchTargets.filter { $0.kind == kind }
        let title: String
        if kind == "php" {
            title = moduleName(kind)
        } else if kind == "nginx" {
            let version = nginxVM.versions.first { app.state.quickStartTargets.contains("nginx:" + $0.id) }
                ?? nginxVM.versions.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
            title = version.map { moduleName(kind) + " " + $0.version } ?? moduleName(kind)
        } else if let dbKind = DatabaseKind(rawValue: kind) {
            let all = databaseVM.versions[dbKind] ?? []
            let version = all.first { app.state.quickStartTargets.contains($0.id) }
                ?? all.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
            title = version.map { dbKind.title + " " + $0.version } ?? moduleName(kind)
        } else {
            let chosen = targets.first { app.state.quickStartTargets.contains($0.key) } ?? targets.first
            title = chosen?.title ?? moduleName(kind)
        }
        return toggleRow(title: title, kind: kind, isOn: app.kindRunning(kind)) {
            app.toggleKind(kind)
        }
        .disabled(busy || targets.isEmpty)
    }

    private func toggleRow(title: String, kind: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            ServiceIcon(kind: kind)
                .frame(width: 20, height: 20)
            Text(title)
                .font(.callout)
                .lineLimit(1)
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: { _ in action() }))
                .labelsHidden()
                .toggleStyle(ServiceSwitch())
        }
        .frame(height: 28)
        .contentShape(Rectangle())
    }

    private var separator: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .padding(.vertical, 4)
    }

    private var bottomRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            plainButton(L("menu.open")) {
                dismiss()
                MacEnvAppDelegate.showMainWindow()
            }
            plainButton(L("menu.settings")) {
                dismiss()
                openSettings()
            }
            plainButton(L("menu.quit")) { NSApp.terminate(nil) }
        }
    }

    // 托盘点「设置」：面板刚 dismiss、app 可能处在 accessory（hideOnClose 关过主窗口），
    // 不先激活的话 Settings 窗口就算建了也在别人后面，看着就是「弹不出」。
    // macOS 14 起的 selector 是 showSettingsWindow:，13 叫 showPreferencesWindow:，两个都试；
    // SwiftUI 的 Settings 窗口建了也不保证自动前置，最后兜底提一下。
    private func openSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.sendAction(NSSelectorFromString("showSettingsWindow:"), to: nil, from: nil) {
            NSApp.sendAction(NSSelectorFromString("showPreferencesWindow:"), to: nil, from: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.windows.first { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }?
                .makeKeyAndOrderFront(nil)
        }
    }

    private func plainButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: 28)
    }
}
