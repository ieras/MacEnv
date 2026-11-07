import SwiftUI
import AppKit

func copyText(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

struct NginxIcon: View {
    var body: some View { AssetIcon(name: "NginxIcon") }
}

struct DatabaseIcon: View {
    let kind: DatabaseKind
    var body: some View { AssetIcon(name: kind == .mysql ? "MySQLIcon" : "MariaDBIcon") }
}

struct RedisIcon: View {
    var body: some View { AssetIcon(name: "RedisIcon") }
}

struct QdrantIcon: View {
    var body: some View { AssetIcon(name: "QdrantIcon") }
}

struct Neo4jIcon: View {
    var body: some View { AssetIcon(name: "Neo4jIcon") }
}

struct RabbitMQIcon: View {
    var body: some View { AssetIcon(name: "RabbitMQIcon") }
}

struct ErlangIcon: View {
    var body: some View { AssetIcon(name: "ErlangIcon") }
}

struct SSLIcon: View {
    var body: some View { AssetIcon(name: "SSLIcon") }
}

struct PhpIcon: View {
    var body: some View { AssetIcon(name: "PhpIcon") }
}

struct SwooleIcon: View {
    var body: some View { AssetIcon(name: "SwooleIcon") }
}

struct GoIcon: View {
    var body: some View { AssetIcon(name: "GoIcon") }
}

struct ComposerIcon: View {
    var body: some View { AssetIcon(name: "ComposerIcon") }
}

struct AssetIcon: View {
    let name: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .foregroundStyle(colorScheme == .dark ? .white : .blue)
    }
}

struct HomebrewIcon: View {
    var body: some View {
        Image("HomebrewIcon")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }
}

struct FnmIcon: View {
    var body: some View {
        Image("FnmIcon")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }
}

struct NvmIcon: View {
    var body: some View {
        Image("NvmIcon")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }
}

struct GvmIcon: View {
    var body: some View { AssetIcon(name: "GVMIcon") }
}

// MARK: - 表格

struct TableColumn {
    let title: String
    var minWidth: CGFloat
    var weight: CGFloat = 0
}

private func tableItems(_ columns: [TableColumn], width: CGFloat) -> [GridItem] {
    let inner = max(0, width - 40)
    let floor = columns.reduce(0) { $0 + $1.minWidth }
    let total = columns.reduce(0) { $0 + $1.weight }
    guard floor > 0, inner > 0 else { return [] }
    let extra = inner - floor
    return (extra >= 0 && total > 0
            ? columns.map { $0.minWidth + extra * $0.weight / total }
            : columns.map { $0.minWidth * inner / floor })
        .map { GridItem(.fixed($0), spacing: 0, alignment: .leading) }
}

struct DataTable<Row, Cell: View>: View {
    let columns: [TableColumn]
    let rows: [Row]
    var loading = false
    var loadingText = ""
    let empty: String
    @ViewBuilder let cell: (Row) -> Cell

    var body: some View {
        GeometryReader { geo in
            let items = tableItems(columns, width: geo.size.width)
            VStack(spacing: 0) {
                LazyVGrid(columns: items, spacing: 0) {
                    ForEach(columns.indices, id: \.self) { Text(columns[$0].title) }
                        .foregroundStyle(.secondary).font(.callout.weight(.semibold)).frame(height: 60)
                }
                .padding(.horizontal, 20)
                Divider()
                ScrollView(.vertical) {
                    if loading {
                        ProgressView(loadingText).padding(30)
                    } else if rows.isEmpty {
                        Text(empty).foregroundStyle(.secondary).padding(30)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        LazyVGrid(columns: items, spacing: 0) {
                            ForEach(rows.indices, id: \.self) { cell(rows[$0]) }
                                .frame(minHeight: 60)
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .scrollIndicators(.visible)
            }
        }
        .font(.callout).lineLimit(1)
    }
}

var operationColumn: TableColumn { TableColumn(title: L("column.operation"), minWidth: 56) }

var versionTableColumns: [TableColumn] {
    [TableColumn(title: L("column.library"), minWidth: 110, weight: 2),
     TableColumn(title: L("column.version"), minWidth: 90, weight: 1),
     TableColumn(title: L("column.installed"), minWidth: 70),
     TableColumn(title: L("column.operation"), minWidth: 170, weight: 3)]
}

struct BrewListView: View {
    let formulae: [BrewFormulaItem]
    let busy: Bool
    let action: (_ brewAction: String, _ formula: String) -> Void

    private var rows: [(formula: BrewFormulaItem, version: String?)] {
        Brew.listRows(formulae)
    }

    var body: some View {
        DataTable(columns: versionTableColumns, rows: rows, empty: L("brew.missing")) { row in
            Text(row.formula.name)
            Text(row.version ?? row.formula.stable)
            Group {
                if row.version == nil { Text(L("brew.notInstalled")).foregroundStyle(.secondary) }
                else { Image(systemName: "checkmark").foregroundStyle(AppTheme.green) }
            }
            HStack(spacing: 16) {
                if row.version == nil {
                    Button(L("action.install")) { action("install", row.formula.name) }.disabled(busy)
                } else if row.version == row.formula.linkedVersion {
                    if row.formula.outdated {
                        Button(L("action.upgradeTo") + " \(row.formula.stable)") { action("upgrade", row.formula.name) }.disabled(busy)
                    } else {
                        Text(L("brew.upToDate")).foregroundStyle(.secondary)
                    }
                } else {
                    Text(L("brew.oldVersion")).foregroundStyle(.secondary).help(L("brew.oldVersionHint"))
                }
                if row.version != nil {
                    Button(L("action.uninstall")) { action("uninstall", row.formula.name) }.disabled(busy)
                }
            }
            .buttonStyle(.borderless)
        }
    }
}

struct PortListView: View {
    let items: [PortItem]
    var loading = false
    let busy: Bool
    let load: () async -> Void
    let install: (PortItem) -> Void
    let uninstall: (PortItem) -> Void

    var body: some View {
        DataTable(columns: versionTableColumns, rows: items,
                  loading: loading, loadingText: L("message.loadingVersions"),
                  empty: L("port.empty")) { item in
            Text(item.name)
            Text(item.version)
            Group {
                if item.installed { Image(systemName: "checkmark").foregroundStyle(AppTheme.green) }
                else { Text(L("brew.notInstalled")).foregroundStyle(.secondary) }
            }
            HStack(spacing: 16) {
                if item.installed {
                    Button(L("action.uninstall")) { uninstall(item) }.disabled(busy)
                } else {
                    Button(L("action.install")) { install(item) }.disabled(busy)
                }
            }
            .buttonStyle(.borderless)
        }
        .task { await load() }
    }
}

struct VersionManagerHeader<Actions: View>: View {
    let sources: [String]
    @Binding var source: String
    let linkURL: URL
    let busy: Bool
    let refreshing: Bool
    let onRefresh: () -> Void
    var width: CGFloat = 330
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack {
            SegmentedTabs(items: sources.map { ($0, $0) }, selection: $source)
                .frame(width: width)
            Link(destination: linkURL) { Image(systemName: "globe") }
            Spacer()
            Button { onRefresh() } label: { Image(systemName: "arrow.clockwise") }
                .help(L("action.refreshVersions"))
                .disabled(busy || refreshing)
            actions()
        }
        .panelHeader()
    }
}

struct StaticVersionListView: View {
    let versions: [StaticVersion]
    var loading = false
    var busy = false
    let install: (StaticVersion) -> Void
    let uninstall: (StaticVersion) -> Void
    var badge: ((StaticVersion) -> String?)? = nil

    private var rows: [StaticVersion] {
        versions.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    var body: some View {
        DataTable(columns: versionTableColumns, rows: rows,
                  loading: loading, loadingText: L("message.loadingVersions"),
                  empty: L("message.noStaticVersions")) { version in
            HStack(spacing: 6) {
                Link(destination: version.url) { Label(version.name, systemImage: "link") }.buttonStyle(.borderless)
                if let badge, let text = badge(version) {
                    Text(text)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AppTheme.cardBackground, in: Capsule())
                }
            }
            Text(version.version)
            Group {
                if version.installed { Image(systemName: "checkmark").foregroundStyle(AppTheme.green) }
                else { Text("—").foregroundStyle(.secondary) }
            }
            Button(version.installed ? L("action.uninstall") : L("action.install")) {
                if version.installed { uninstall(version) } else { install(version) }
            }
            .buttonStyle(.borderless)
            .disabled(busy)
        }
    }
}

struct ServiceIcon: View {
    let kind: String

    var body: some View {
        switch kind {
        case "nginx": NginxIcon()
        case "php": PhpIcon()
        case "redis": RedisIcon()
        case "qdrant": QdrantIcon()
        case "postgresql": AssetIcon(name: "PostgresIcon")
        case "clickhouse": AssetIcon(name: "ClickHouseIcon")
        case "consul": AssetIcon(name: "ConsulIcon")
        case "etcd": AssetIcon(name: "EtcdIcon")
        case "neo4j": Neo4jIcon()
        case "rabbitmq": RabbitMQIcon()
        default: DatabaseIcon(kind: DatabaseKind(rawValue: kind) ?? .mysql)
        }
    }
}

struct SegmentedTabs<Value: Hashable>: View {
    @Environment(\.colorScheme) private var colorScheme
    let items: [(String, Value)]
    @Binding var selection: Value

    init(titles: [String], selection: Binding<Int>) where Value == Int {
        items = titles.enumerated().map { ($0.element, $0.offset) }
        _selection = selection
    }

    init(items: [(String, Value)], selection: Binding<Value>) {
        self.items = items
        _selection = selection
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                Button {
                    selection = item.1
                } label: {
                    Text(item.0)
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(selection == item.1 ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(selection == item.1 ? AppTheme.tint(colorScheme) : .clear,
                                    in: RoundedRectangle(cornerRadius: AppTheme.radiusCard))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(AppTheme.cardBackground, in: RoundedRectangle(cornerRadius: AppTheme.radiusPanel))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusPanel).stroke(AppTheme.stroke))
    }
}

struct ModulePage<Tabs: View, Content: View>: View {
    @EnvironmentObject private var state: AppState
    @ViewBuilder var tabs: () -> Tabs
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            tabs()
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
            if let title = state.runningTaskTitle {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
            }
            content()
                .textSelection(.enabled)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: AppTheme.radiusPanel))
                .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusPanel).stroke(AppTheme.stroke))

        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
        .background(AppTheme.windowBackground)
    }
}

struct PanelHeader: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(.borderless)
            .padding(.horizontal, 20)
            .frame(height: 64)
    }
}

extension View {
    func panelHeader() -> some View { modifier(PanelHeader()) }
}

struct SelectableTitle: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.isSelectable = true
        field.isEditable = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.textColor = .labelColor
        field.font = .systemFont(ofSize: 20)
        field.lineBreakMode = .byClipping
        field.maximumNumberOfLines = 1
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }
}

struct ModuleIcon: View {
    let id: String

    var body: some View {
        switch id {
        case "hosts": SSLIcon()
        case "go": GoIcon()
        case "java": AssetIcon(name: "JavaIcon")
        case "python": AssetIcon(name: "PythonIcon")
        case "node": AssetIcon(name: "NodeIcon")
        case "rust": AssetIcon(name: "RustIcon")
        case "tools": AssetIcon(name: "ToolsIcon")
        case "erlang": ErlangIcon()
        default: ServiceIcon(kind: id)
        }
    }
}

struct ToastCard: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(text)
                .font(.callout)
                .lineLimit(6)
                .textSelection(.enabled)
                .frame(maxWidth: 340, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L("action.close"))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppTheme.radiusOverlay))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusOverlay).stroke(AppTheme.stroke))
    }
}

struct TaskLogOverlay: View {
    let task: TaskProgress
    let cancel: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if task.running { ProgressView().controlSize(.small) }
                Text(task.title).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                if task.running {
                    Button(L("action.cancel"), action: cancel)
                } else {
                    Button(action: dismiss) { Image(systemName: "xmark") }
                        .accessibilityLabel(L("action.close"))
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .frame(height: 40)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    Text(task.log.isEmpty ? L("message.taskStarting") : task.log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("task-log-tail")
                }
                .scrollIndicators(.visible)
                .onChange(of: task.log) { _ in proxy.scrollTo("task-log-tail", anchor: .bottom) }
            }
            .frame(height: AppTheme.taskLogHeight)
        }
        .frame(width: AppTheme.taskLogWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppTheme.radiusOverlay))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusOverlay).stroke(AppTheme.stroke))
    }
}

struct ServiceActionButtons: View {
    let running: Bool
    let name: String
    let toggle: () -> Void
    let restart: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                Image(systemName: running ? "stop" : "play")
                    .foregroundStyle(running ? AppTheme.green : .primary)
            }
            .help(Text(running ? L("action.stop") + " \(name)" : L("action.start") + " \(name)"))
            if running {
                Button(action: restart) { Image(systemName: "arrow.clockwise") }.help(Text(L("action.restart") + " \(name)"))
            }
        }
        .font(.title3)
        .buttonStyle(.borderless)
    }
}

struct EnvironmentVariableButton: View {
    let membership: PathMembership
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: membership.icon)
                .foregroundStyle(membership == .app ? .blue : membership == .shell ? .orange : .secondary)
        }
        .buttonStyle(.borderless)
        .help(membership == .shell
              ? membership.source.map { String(format: L("path.externalAt"), $0) } ?? L("path.external")
              : membership == .app ? L("action.removePath") : L("action.enablePath"))
    }
}

enum AppTheme {
    static let green = Color(red: 0.196, green: 0.843, blue: 0.294)
    static let panelBackground = Color(nsColor: .textBackgroundColor)
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let cardBackground = Color.primary.opacity(0.06)
    static let stroke = Color.primary.opacity(0.08)
    static let radiusPanel: CGFloat = 8
    static let radiusCard: CGFloat = 6
    static let radiusRow: CGFloat = 10
    static let radiusOverlay: CGFloat = 10

    static let taskLogWidth: CGFloat = 520
    static let taskLogHeight: CGFloat = 200

    static let sheetWidth: CGFloat = 560
    static let sheetHeight: CGFloat = 360
    static let tallSheetHeight: CGFloat = 680

    static func tint(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.38, green: 0.50, blue: 0.63) : Color(red: 0.42, green: 0.54, blue: 0.66)
    }
}

struct ServiceSwitch: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.label
            Button {
                configuration.isOn.toggle()
            } label: {
                Capsule()
                    .fill(configuration.isOn ? AppTheme.green : Color.gray.opacity(0.35))
                    .frame(width: 28, height: 16)
                    .overlay {
                        Circle()
                            .fill(.white)
                            .frame(width: 12, height: 12)
                            .shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
                            .offset(x: configuration.isOn ? 6 : -6)
                    }
                    .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
                    .opacity(isEnabled ? 1 : 0.4)
            }
            .buttonStyle(.plain)
        }
        .accessibilityValue(configuration.isOn ? "on" : "off")
    }
}

struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var editable: Bool

    static var fontSize: CGFloat { CGFloat(UserDefaults.standard.object(forKey: "macenv.code.fontSize") as? Double ?? 14) }

    func makeNSView(context: Context) -> NSScrollView {
        let view = NSTextView.scrollableTextView()
        let editor = view.documentView as! NSTextView
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.isEditable = editable
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: CodeEditor.fontSize, weight: .regular)
        editor.textContainerInset = NSSize(width: 18, height: 16)
        editor.backgroundColor = .textBackgroundColor
        editor.textColor = .textColor
        return view
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        let editor = view.documentView as! NSTextView
        if editor.string != text { editor.string = text }
        editor.font = .monospacedSystemFont(ofSize: CodeEditor.fontSize, weight: .regular)
        editor.backgroundColor = .textBackgroundColor
        editor.textColor = .textColor
        editor.insertionPointColor = .textColor
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        init(_ parent: CodeEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { parent.text = editor.string }
        }
    }
}

struct CustomPathEditor: View {
    let title: String
    @Binding var paths: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("\(title) " + L("pathEditor.title")).font(.headline)
                Spacer()
                Button { chooseDirectory() } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.borderless)
                    .help(L("pathEditor.add"))
            }
            Text(L("pathEditor.hint")).font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(paths, id: \.self) { path in
                    HStack {
                        Text(tilde(path)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: { Image(systemName: "folder") }.buttonStyle(.borderless)
                        Button(role: .destructive) { paths.removeAll { $0 == path } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
                if paths.isEmpty { Text(L("pathEditor.empty")).foregroundStyle(.secondary) }
            }
            HStack {
                Spacer()
                Button(L("action.done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: AppTheme.sheetWidth, height: AppTheme.sheetHeight)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !paths.contains(url.path) { paths.append(url.path) }
    }
}


struct QuickStartCheckButton: View {
    @ObservedObject var app: AppViewModel
    let key: String

    private var isOn: Bool { app.state.quickStartTargets.contains(key) }

    var body: some View {
        Button {
            app.setQuickStart(key, enabled: !isOn)
        } label: {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isOn ? .blue : .secondary)
        }
        .buttonStyle(.borderless).help(L("action.quickStartHint"))
    }
}

struct RefreshButton: View {
    @Binding var refreshing: Bool
    let busy: Bool
    let refresh: () async -> Void

    var body: some View {
        Button {
            refreshing = true
            Task { await refresh(); refreshing = false }
        } label: { Image(systemName: "arrow.clockwise") }
        .help(L("action.refreshVersions"))
        .disabled(busy || refreshing)
    }
}
