import SwiftUI

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

    private var quickTargets: [LaunchTarget] { app.quickStartLaunchTargets }

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
