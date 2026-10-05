import SwiftUI

// Swoole CLI 挂在 PHP 页面里当 tab（FlyEnv 把它做成独立模块，但它的版本管理和
// 运行时文件跟 PHP 是同一套东西，分开只会让人以为要装两遍）。
struct SwoolePanel: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var vm: SwooleViewModel
    @State private var showingAvailable = false
    @State private var customPathEditor = false
    @State private var refreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                SegmentedTabs(items: [(L("tab.installed"), false), (L("tab.versions"), true)],
                              selection: $showingAvailable)
                    .frame(width: 180)
                SwooleIcon().frame(width: 22, height: 22)
                Button { customPathEditor = true } label: { Image(systemName: "folder.badge.plus") }
                    .help(L("action.customPathHint"))
                Link(destination: URL(string: "https://www.swoole.com/")!) { Image(systemName: "globe") }
                Spacer()
                Button {
                    refreshing = true
                    Task {
                        if showingAvailable { await vm.loadStatic(force: true) } else { await vm.refresh() }
                        refreshing = false
                    }
                } label: { Image(systemName: "arrow.clockwise") }
                .help(L("action.refreshVersions"))
                .disabled(app.state.busy || refreshing)
            }
            .panelHeader()
            Divider()
            if showingAvailable {
                StaticVersionListView(versions: vm.staticVersions, loading: vm.staticLoading) { vm.installStatic($0) } uninstall: { vm.uninstallStatic($0) }
            } else {
                installedTable
            }
            Spacer()
        }
        .sheet(isPresented: $customPathEditor) { CustomPathEditor(title: "Swoole CLI", paths: $vm.customDirectories) }
        .task { await vm.loadStatic() }
    }

    // 版本 / PHP / 路径 / 环境变量。宽度交给 DataTable 按容器反推。
    private var tableColumns: [TableColumn] {
        [TableColumn(title: L("column.version"), minWidth: 60),
         TableColumn(title: "PHP", minWidth: 60),
         TableColumn(title: L("column.path"), minWidth: 140, weight: 1),
         TableColumn(title: L("column.env"), minWidth: 56)]
    }

    private var installedTable: some View {
        DataTable(columns: tableColumns, rows: vm.versions, empty: L("message.noSwooleInstalled")) { version in
            Text(version.version)
            Text(version.phpVersion)
            Button { NSWorkspace.shared.open(version.directory) } label: {
                Text(tilde(version.directory.path)).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.borderless).help(tilde(version.directory.path))
            EnvironmentVariableButton(membership: vm.pathMembership[version.id, default: .none]) { vm.togglePath(version) }
                .disabled(app.state.busy)
        }
    }
}
