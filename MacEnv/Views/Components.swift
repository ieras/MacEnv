import SwiftUI
import AppKit

// 拷到剪切板。站点列表（网址 / 目录）和证书页（CA 根目录）共用这一条。
func copyText(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

struct NginxIcon: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image("NginxIcon")
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .foregroundStyle(colorScheme == .dark ? .white : .blue)
    }
}

struct DatabaseIcon: View {
    let kind: DatabaseKind
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(kind == .mysql ? "MySQLIcon" : "MariaDBIcon")
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .foregroundStyle(colorScheme == .dark ? .white : .blue)
    }
}

struct RedisIcon: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image("RedisIcon")
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .foregroundStyle(colorScheme == .dark ? .white : .blue)
    }
}

// 站点 / 站点证书共用。mkcert 那个盾牌 + SSL 字样的图标，跟 FlyEnv 用的是同一份。
struct SSLIcon: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image("SSLIcon")
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .foregroundStyle(colorScheme == .dark ? .white : .blue)
    }
}

struct PhpIcon: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image("PhpIcon")
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .foregroundStyle(colorScheme == .dark ? .white : .blue)
    }
}

struct SwooleIcon: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image("SwooleIcon")
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .foregroundStyle(colorScheme == .dark ? .white : .blue)
    }
}

// Go 官方 logo 的原始 viewBox 是 2586×1024（横向长条），这里套一层 1024×1024 的画布
// 把它等比缩放居中，侧栏里跟 Nginx / PHP 那些方形图标站一排才不会显得忽大忽小。
struct GoIcon: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image("GoIcon")
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .foregroundStyle(colorScheme == .dark ? .white : .blue)
    }
}

struct ComposerIcon: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image("ComposerIcon")
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .foregroundStyle(colorScheme == .dark ? .white : .blue)
    }
}

// 版本列表统一列宽：库 / 版本 / 是否安装 / 操作。
// Static、Homebrew、GVM 这几个列表字段一样，列宽就必须一样，否则切换来源时列位置会跳。
// MARK: - 表格

// 表格列：只声明最小宽度 + 分剩余宽度的权重，实际像素宽度由容器宽度反推。
// 为什么不让手填像素 —— LazyVGrid 按每列的 maximum 算宽度，总和超过容器时它不会收缩，
// 手写的固定宽度在窗口变窄时必然把右侧列顶出面板（这个坑踩过三次，所以宽度不再手填）。
struct TableColumn {
    let title: String
    var minWidth: CGFloat
    var weight: CGFloat = 0
}

// 每列先拿最小宽度，剩余宽度按权重分；容器比最小宽度总和还窄时整体等比压缩。
// 返回的列宽总和恒等于容器内宽，所以永远不会溢出。
//
// 坑：LazyVGrid 构造参数里的 spacing 是「行间距」，列与列之间的间距由每个 GridItem 自己的
// spacing 决定，不写就用系统默认（7 列能吃掉 56pt）—— 列宽算得再准，这 56pt 照样把表格
// 顶出面板。所以每个 GridItem 必须显式 spacing: 0。
private func tableItems(_ columns: [TableColumn], width: CGFloat) -> [GridItem] {
    let inner = max(0, width - 40)                       // 减掉表格自己的 .padding(.horizontal, 20)
    let floor = columns.reduce(0) { $0 + $1.minWidth }
    let total = columns.reduce(0) { $0 + $1.weight }
    guard floor > 0, inner > 0 else { return [] }
    let extra = inner - floor
    return (extra >= 0 && total > 0
            ? columns.map { $0.minWidth + extra * $0.weight / total }
            : columns.map { $0.minWidth * inner / floor })
        .map { GridItem(.fixed($0), spacing: 0, alignment: .leading) }
}

// 统一的「表头 + 可滚动数据行」表格。列声明一次，表头和数据行共用同一份算出来的宽度，
// 所以两边永远对齐；宽度由容器反推，所以永远不会溢出面板。cell 里按列顺序给单元格。
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

// 行尾那个「…」菜单：ellipsis 图标 + borderlessButton 自带的箭头 + 控件内边距，实测比表头
// 「操作」两个字宽得多。之前按表头宽度填 28 / 36，菜单直接顶到卡片外面 —— 宽度按内容给。
var operationColumn: TableColumn { TableColumn(title: L("column.operation"), minWidth: 56) }

// 版本管理页那几张表（库 / 版本 / 是否安装 / 操作）共用这一套列。
// 操作列要装「更新到 x.y + 卸载」两个按钮，所以权重最大；库列次之。
var versionTableColumns: [TableColumn] {
    [TableColumn(title: L("column.library"), minWidth: 110, weight: 2),
     TableColumn(title: L("column.version"), minWidth: 90, weight: 1),
     TableColumn(title: L("column.installed"), minWidth: 70),
     TableColumn(title: L("column.operation"), minWidth: 170, weight: 3)]
}

// brew 渠道公式列表：PHP / Nginx / Database / Go / Composer 共用的同一套
// 「安装 / 更新到 x.y / 已是最新 / 旧版本 / 卸载」状态机。空态由调用方自己渲染。
struct BrewListView: View {
    let formulae: [BrewFormulaItem]
    let busy: Bool
    let action: (_ brewAction: String, _ formula: String) -> Void

    // 摊平成「公式 + 已装版本」行，没装过的公式给一行空版本。
    private var rows: [(formula: BrewFormulaItem, version: String?)] {
        formulae.flatMap { formula in
            formula.installedVersions.isEmpty
                ? [(formula, nil)]
                : formula.installedVersions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { (formula, $0) }
        }
    }

    var body: some View {
        DataTable(columns: versionTableColumns, rows: rows, empty: L("brew.missing")) { row in
            Text(row.formula.name)
            Text(row.version ?? row.formula.stable)
            Group {
                if row.version == nil { Text(L("brew.notInstalled")).foregroundStyle(.secondary) }
                else { Image(systemName: "checkmark").foregroundStyle(AppTheme.green) }
            }
            // LazyVGrid 里 Group 会被摊平成多个 cell，操作列必须包在同一个 HStack 里才占一列。
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

// 版本管理页顶栏：来源切换 + 官网链接 + 刷新，右侧留给 brew update 之类的附加动作。
struct VersionManagerHeader<Actions: View>: View {
    let sources: [String]
    @Binding var source: String
    let linkURL: URL
    let busy: Bool
    let refreshing: Bool
    let onRefresh: () -> Void
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack {
            SegmentedTabs(items: sources.map { ($0, $0) }, selection: $source)
                .frame(width: 330)
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
    let install: (StaticVersion) -> Void
    let uninstall: (StaticVersion) -> Void

    var body: some View {
        DataTable(columns: versionTableColumns, rows: versions,
                  loading: loading, loadingText: L("message.loadingVersions"),
                  empty: L("message.noStaticVersions")) { version in
            Link(destination: version.url) { Label(version.name, systemImage: "link") }.buttonStyle(.borderless)
            Text(version.version)
            Group {
                if version.installed { Image(systemName: "checkmark").foregroundStyle(AppTheme.green) }
                else { Text("—").foregroundStyle(.secondary) }
            }
            Button(version.installed ? L("action.uninstall") : L("action.install")) {
                if version.installed { uninstall(version) } else { install(version) }
            }
            .buttonStyle(.borderless)
        }
    }
}

// 按 LaunchTarget.kind 取图标：nginx/php 有专属 icon，其余按数据库 kind 取。
struct ServiceIcon: View {
    let kind: String

    var body: some View {
        switch kind {
        case "nginx": NginxIcon()
        case "php": PhpIcon()
        case "redis": RedisIcon()
        default: DatabaseIcon(kind: DatabaseKind(rawValue: kind) ?? .mysql)
        }
    }
}

// 页面顶部的分段控件。不用系统 segmented Picker：它的每段宽度按内容算，
// 选中段还会加粗，段一多就总宽溢出窗口，而且切换时宽度来回变，肉眼可见地抖。
// 这里每段都是 .frame(maxWidth: .infinity)，宽度恒定，多少段都放得下。
struct SegmentedTabs<Value: Hashable>: View {
    @Environment(\.colorScheme) private var colorScheme
    let items: [(String, Value)]
    @Binding var selection: Value

    // 页面顶部那种「标题数组 + 下标」的用法不用每处都写一遍编号。
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
                        // 整段（含文字以外的空白）都要能点，不然只有字上才响应。
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

// 所有模块页面共用的外壳：顶部分段控件等分可用宽度（不会撑破窗口、切换也不抖），
// 下面是统一底色的内容面板。页面只要给 tabs 和 content 两段。
struct ModulePage<Tabs: View, Content: View>: View {
    @ViewBuilder var tabs: () -> Tabs
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            tabs()
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
            content()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: AppTheme.radiusPanel))
                .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusPanel).stroke(AppTheme.stroke))

        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
        .background(AppTheme.windowBackground)
    }
}

// 面板头统一的高度和边距，别再每个页面手写一遍数字。
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

// 按模块 id 取图标：站点用 SSL 盾牌，nginx/php/go 有专属 icon，其余按数据库 kind 取。
struct ModuleIcon: View {
    let id: String

    var body: some View {
        switch id {
        case "hosts": SSLIcon()
        case "nginx": NginxIcon()
        case "php": PhpIcon()
        case "go": GoIcon()
        case "redis": RedisIcon()
        default: DatabaseIcon(kind: DatabaseKind(rawValue: id) ?? .mysql)
        }
    }
}

// 右下角浮层提示：默认 3 秒自动消失，点一下也能手动关掉。
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
        .help(membership == .app ? L("action.removePath") : L("action.enablePath"))
    }
}

// 原生 switch 在窗口失去焦点时会被 AppKit 强制降级成灰色，.tint() 压不住，
// 结果是服务明明在跑、开关却是灰的。所以自己画一个，颜色只由开关状态决定。
// 全局视觉参数：颜色、圆角、描边只在这里定义，页面里一律用它，别再现写数值。
enum AppTheme {
    // 开关开态 / 运行中 / 图标指示灯统一这个绿，跟托盘图标的 #32D74B 对齐。
    static let green = Color(red: 0.196, green: 0.843, blue: 0.294)
    static let panelBackground = Color(nsColor: .textBackgroundColor)
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let cardBackground = Color.primary.opacity(0.06)
    static let stroke = Color.primary.opacity(0.08)
    static let radiusPanel: CGFloat = 8
    static let radiusCard: CGFloat = 6
    static let radiusRow: CGFloat = 10
    static let radiusOverlay: CGFloat = 10

    // 弹窗尺寸规范：宽度一律 560；高度三档 —— 常规 360，多字段表单 560，
    // 超长表单 680（站点编辑展开 SSL 后最多 12 个字段 + 两个多行编辑器，560 装不下）。
    static let sheetWidth: CGFloat = 560
    static let sheetHeight: CGFloat = 360
    static let formSheetHeight: CGFloat = 560
    static let tallSheetHeight: CGFloat = 680

    // 主色调和侧栏选中色按明暗两套给，系统色一失焦就变灰，所以自己算。
    static func tint(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.38, green: 0.50, blue: 0.63) : Color(red: 0.42, green: 0.54, blue: 0.66)
    }
    static func selection(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.27, green: 0.34, blue: 0.43) : Color(red: 0.82, green: 0.87, blue: 0.93)
    }
}

struct ServiceSwitch: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    // 自绘胶囊，不用系统 NSSwitch：系统的那个窗口一失焦就变灰，看着跟关了一样。
    // label 在这里渲染，所以 Toggle("标题") 直接带文字也能用；不需要文字的地方照样 .labelsHidden()。
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

// 使用 AppKit 自带的文本编辑器，系统外观变化时编辑器背景和文字一起更新。
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var editable: Bool

    // 设置页「界面」里的代码字号，改完下次打开编辑区生效。
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

