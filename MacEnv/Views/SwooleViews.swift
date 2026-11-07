import SwiftUI

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
                RefreshButton(refreshing: $refreshing, busy: app.state.busy) {
                    if showingAvailable { await vm.loadStatic(force: true) } else { await vm.refresh() }
                }
            }
            .panelHeader()
            Divider()
            if showingAvailable {
                StaticVersionListView(versions: vm.staticVersions, loading: vm.staticLoading, busy: app.state.installBusy) { vm.installStatic($0) } uninstall: { vm.uninstallStatic($0) }
            } else {
                installedTable
            }
            Spacer()
        }
        .sheet(isPresented: $customPathEditor) { CustomPathEditor(title: "Swoole CLI", paths: $vm.customDirectories) }
        .task { await vm.loadStatic() }
    }

    private var tableColumns: [TableColumn] {
        [TableColumn(title: L("column.version"), minWidth: 60),
         TableColumn(title: "PHP", minWidth: 60),
         TableColumn(title: L("column.path"), minWidth: 140, weight: 1),
         TableColumn(title: L("column.source"), minWidth: 70),
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
            Text(version.source).foregroundStyle(.secondary)
            EnvironmentVariableButton(membership: vm.pathMembership[version.id, default: .none]) { vm.togglePath(version) }
                .disabled(app.state.busy)
        }
    }
}
