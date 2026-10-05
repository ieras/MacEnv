import SwiftUI

// Composer 挂在 PHP 页面里当 tab。跟 Swoole CLI 一样不是服务：没有启停，
// 只有版本、PATH，外加一条 brew 通道（brew 的 composer 就是个 .phar 壳子）。
struct ComposerPanel: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var vm: ComposerViewModel
    @State private var source = "installed"
    @State private var customPathEditor = false
    @State private var refreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                SegmentedTabs(items: [(L("tab.installed"), "installed"), ("Static", "static"), ("Homebrew", "brew")],
                              selection: $source)
                    .frame(width: 250)
                ComposerIcon().frame(width: 22, height: 22)
                Button { customPathEditor = true } label: { Image(systemName: "folder.badge.plus") }
                    .help(L("action.customPathHint"))
                Link(destination: URL(string: "https://getcomposer.org/download/")!) { Image(systemName: "globe") }
                Spacer()
                Button {
                    refreshing = true
                    Task {
                        if source == "static" { await vm.loadStatic(force: true) } else { await vm.refresh() }
                        refreshing = false
                    }
                } label: { Image(systemName: "arrow.clockwise") }
                .help(L("action.refreshVersions"))
                .disabled(app.state.busy || refreshing)
                if source == "brew" { Button(L("action.updateBrew")) { vm.brewAction("update", formula: "composer") }.disabled(app.state.busy) }
            }
            .panelHeader()
            Divider()
            switch source {
            case "static":
                StaticVersionListView(versions: vm.staticVersions, loading: vm.staticLoading) { vm.installStatic($0) } uninstall: { vm.uninstallStatic($0) }
            case "brew":
                if vm.formulae.isEmpty {
                    Text(L("brew.missing")).padding(24)
                    Link(L("brew.install"), destination: URL(string: "https://brew.sh")!).padding(.horizontal, 24)
                } else {
                    BrewListView(formulae: vm.formulae, busy: app.state.busy) { vm.brewAction($0, formula: $1) }
                }
            default:
                installedTable
            }
            Spacer()
        }
        .sheet(isPresented: $customPathEditor) { CustomPathEditor(title: "Composer", paths: $vm.customDirectories) }
        .task { await vm.loadStatic() }
    }

    // 版本 / 路径 / 环境变量。宽度交给 DataTable 按容器反推。
    private var tableColumns: [TableColumn] {
        [TableColumn(title: L("column.version"), minWidth: 60),
         TableColumn(title: L("column.path"), minWidth: 140, weight: 1),
         TableColumn(title: L("column.env"), minWidth: 56)]
    }

    private var installedTable: some View {
        DataTable(columns: tableColumns, rows: vm.versions, empty: L("message.noComposerInstalled")) { version in
            Text(version.version)
            Button { NSWorkspace.shared.open(version.directory) } label: {
                Text(tilde(version.directory.path)).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.borderless).help(tilde(version.directory.path))
            EnvironmentVariableButton(membership: vm.pathMembership[version.id, default: .none]) { vm.togglePath(version) }
                .disabled(app.state.busy)
        }
    }

}
