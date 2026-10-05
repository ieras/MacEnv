import SwiftUI
import AppKit

struct HostManagementView: View {
    @ObservedObject var app: AppViewModel
    @ObservedObject var vm: HostViewModel
    @State private var tab = 0
    @State private var editing: Host?
    @State private var configHost: Host?
    @State private var deleting: Host?

    var body: some View {
        ModulePage {
            SegmentedTabs(
                titles: [L("tab.hosts"), L("tab.hostLogs"), L("tab.hostsFile"), L("tab.vhostTemplate")],
                selection: $tab
            )
        } content: {
            page
        }
        .onChange(of: tab) { value in if value == 1 { vm.loadLog() } }
        .task { await vm.refresh() }
        .sheet(item: $editing) { HostEditorView(vm: vm, host: $0) }
        .sheet(item: $configHost) { HostConfigView(vm: vm, host: $0) }
        .alert(L("alert.deleteHostTitle"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L("action.cancel"), role: .cancel) { deleting = nil }
            Button(L("action.delete"), role: .destructive) {
                if let host = deleting { vm.delete(host) }
                deleting = nil
            }
        } message: { Text(String(format: L("alert.deleteHostMessage"), deleting?.name ?? "")) }
    }

    @ViewBuilder
    private var page: some View {
        switch tab {
        case 1: logPanel
        case 2: hostsPanel
        case 3: templatePanel
        default: listPanel
        }
    }

    // MARK: - 站点列表

    // 列声明：宽度交给 DataTable 按容器实际宽度反推，不再手填像素。
    private var tableColumns: [TableColumn] {
        [TableColumn(title: L("host.columnName"), minWidth: 80, weight: 2),
         TableColumn(title: L("column.alias"), minWidth: 90, weight: 2),
         TableColumn(title: L("column.path"), minWidth: 140, weight: 5),
         TableColumn(title: L("column.port"), minWidth: 46),
         TableColumn(title: "PHP", minWidth: 50),
         TableColumn(title: L("column.note"), minWidth: 60, weight: 1),
         operationColumn]
    }

    private var listPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(L("host.title")).font(.title3)
                Image(systemName: "globe").foregroundStyle(.secondary)
                Button { editing = Host() } label: { Image(systemName: "plus") }
                    .help(L("host.new"))
                    .disabled(app.state.busy)
                Button { Task { await vm.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("action.reload"))
                Spacer()
                Text("\(vm.hosts.count)").foregroundStyle(.secondary)
            }
            .panelHeader()
            Divider()
            DataTable(columns: tableColumns, rows: vm.hosts, empty: L("host.empty")) { row($0) }
        }
    }

    private func row(_ host: Host) -> some View {
        Group {
            HStack(spacing: 6) {
                if host.isTop { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                Button(host.name) { NSWorkspace.shared.open(URL(string: host.url)!) }
                    .buttonStyle(.borderless)
                    .help(L("host.visit"))
                Button { copy(host.url) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help(L("host.copyURL"))
                if host.useSSL { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(AppTheme.green) }
            }
            Text(host.aliases.joined(separator: "、")).foregroundStyle(.secondary)
            // 路径列只显示末级目录名（/Users/ieras/Sites/laravel → laravel），完整路径挂在
            // 悬停提示里；点名字开目录，右边的复制按钮拷完整路径 —— 和域名列一个套路。
            HStack(spacing: 6) {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: host.root, isDirectory: true))
                } label: {
                    Text(URL(fileURLWithPath: host.root).lastPathComponent)
                }
                .buttonStyle(.borderless).help(tilde(host.root))
                Button { copy(host.root) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help(L("host.copyPath"))
            }
            Text(host.useSSL ? "\(host.sslPort)" : "\(host.port)")
            Text(host.phpVersion.isEmpty ? L("host.phpStatic") : vm.phpLabel(host.phpVersion))
                .foregroundStyle(host.phpVersion.isEmpty ? .secondary : .primary)
            Text(host.mark).foregroundStyle(.secondary)
            Menu {
                Button(L("host.visit")) { NSWorkspace.shared.open(URL(string: host.url)!) }
                Button(L("host.editConfig")) { configHost = host }
                Button(L("action.openFolder")) { NSWorkspace.shared.open(URL(fileURLWithPath: host.root, isDirectory: true)) }
                Button(L("action.edit")) { editing = host }
                Button(L("host.park")) { vm.park(host) }.disabled(app.state.busy)
                Divider()
                Button(host.isTop ? L("host.unpin") : L("host.pin")) { vm.toggleTop(host) }
                Button(L("tab.hostLogs")) { vm.selectedID = host.id; vm.loadLog(); tab = 1 }
                Divider()
                Button(L("action.delete"), role: .destructive) { deleting = host }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
        }
    }

    // 拷到剪切板。网址和站点目录共用这一条。
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - 日志

    private var logPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(L("tab.hostLogs")).font(.title3)
                Picker("", selection: $vm.selectedID) {
                    ForEach(vm.hosts) { host in Text(host.name).tag(host.id as String?) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
                SegmentedTabs(items: [(L("tab.accessLog"), "access"), (L("tab.errorLog"), "error")],
                              selection: $vm.logKind)
                    .frame(width: 180)
                Spacer()
                Button { vm.loadLog() } label: { Image(systemName: "arrow.clockwise") }.help(L("action.refreshLog"))
            }
            .panelHeader()
            .onChange(of: vm.logKind) { _ in vm.loadLog() }
            Divider()
            if vm.hosts.isEmpty {
                Text(L("host.empty")).foregroundStyle(.secondary).padding(24)
            } else {
                CodeEditor(text: $vm.logText, editable: false)
            }
        }
    }

    // MARK: - 系统 hosts

    private var hostsPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(L("tab.hostsFile")).font(.title3)
                Image(systemName: vm.hostsSynced ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(vm.hostsSynced ? AppTheme.green : .orange)
                Text(vm.hostsSynced ? L("hosts.synced") : L("hosts.unsynced")).foregroundStyle(.secondary)
                Spacer()
                Toggle(L("hosts.auto"), isOn: $vm.autoWriteHosts).toggleStyle(ServiceSwitch())
                Button(L("hosts.write")) { vm.syncHostsNow() }.disabled(app.state.busy)
            }
            .panelHeader()
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text(String(format: L("hosts.hint"), tilde(vm.hostsFile.path))).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(String(format: L("hosts.trustHint"), tilde(vm.rootCertificate.path))).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 12) {
                    Button(L("hosts.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([vm.hostsFile]) }
                    Button(L("hosts.trust")) { vm.trustRootCertificate() }.disabled(app.state.busy)
                }
                .buttonStyle(.borderless).font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 16)
            Divider()
            CodeEditor(text: .constant(vm.service.hostsBlock(vm.hosts)), editable: false)
        }
    }

    // MARK: - 站点模板

    private var templatePanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(L("tab.vhostTemplate")).font(.title3)
                Spacer()
                Button(L("template.reveal")) { NSWorkspace.shared.open(vm.service.templateDirectory) }
                Button(L("template.copy")) { copyTemplates() }
            }
            .panelHeader()
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(String(format: L("template.hint"), tilde(vm.service.templateDirectory.path)))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                ForEach(["nginx.vhost", "nginxSSL.vhost"], id: \.self) { name in
                    HStack(spacing: 10) {
                        Image(systemName: FileManager.default.fileExists(atPath: vm.service.templateDirectory.appendingPathComponent(name).path)
                              ? "pencil.circle.fill" : "doc.text")
                            .foregroundStyle(.secondary)
                        Text(name)
                        Spacer()
                        Text(FileManager.default.fileExists(atPath: vm.service.templateDirectory.appendingPathComponent(name).path)
                             ? L("template.custom") : L("template.builtin"))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(L("template.placeholderHint")).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(20)
        }
    }

    private func copyTemplates() {
        let fm = FileManager.default
        guard let defaults = Bundle.main.url(forResource: "HostDefaults", withExtension: nil) else { return }
        do {
            try vm.service.prepare()
            for name in ["nginx.vhost", "nginxSSL.vhost"] {
                let target = vm.service.templateDirectory.appendingPathComponent(name)
                try? fm.removeItem(at: target)
                try fm.copyItem(at: defaults.appendingPathComponent(name), to: target)
            }
            app.state.message = L("message.templateCopied")
        } catch {
            app.state.message = error.localizedDescription
        }
    }
}

// MARK: - 站点编辑

struct HostEditorView: View {
    @ObservedObject var vm: HostViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var host: Host
    @State private var isNew: Bool
    @State private var rewriteTemplate = ""
    @State private var rewriteTemplates: [(String, String)] = []

    init(vm: HostViewModel, host: Host) {
        self.vm = vm
        // 新建时预填一个随机域名（照 FlyEnv 的 flyenv-test-<uuid>.test），点保存就能直接建站点。
        var item = host
        if !vm.hosts.contains(where: { $0.id == host.id }), item.name.isEmpty {
            item.name = "macenv-test-" + String(UUID().uuidString.prefix(8)).lowercased() + ".test"
        }
        _host = State(initialValue: item)
        _isNew = State(initialValue: !vm.hosts.contains { $0.id == host.id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(isNew ? L("host.new") : L("host.edit")).font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20).frame(height: 56)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field(L("host.columnName"), hint: L("host.nameHint")) {
                        TextField("myapp.test", text: $host.name).textFieldStyle(.roundedBorder)
                    }
                    field(L("column.alias"), hint: L("host.aliasHint")) {
                        editor($host.alias, height: 60)
                    }
                    field(L("column.note")) {
                        TextField(L("host.markHint"), text: $host.mark).textFieldStyle(.roundedBorder)
                    }
                    field(L("column.path"), hint: L("host.rootHint")) {
                        HStack(spacing: 8) {
                            // 框里显示 ~，落库时展开回绝对路径。host.root 必须**始终**是绝对路径：
                            // 自动识别伪静态要拿它去 fileExists，写 vhost 时也是原样塞进 nginx 配置，
                            // 而 nginx 不认 ~ —— 之前占位符写着 ~/Sites/myapp 但真敲进去是坏的。
                            TextField("~/Sites/myapp", text: Binding(
                                get: { tilde(host.root) },
                                set: { host.root = expandTilde($0) }
                            )).textFieldStyle(.roundedBorder)
                            Button { chooseRoot() } label: { Image(systemName: "folder") }.buttonStyle(.borderless)
                        }
                    }
                    HStack(alignment: .top, spacing: 16) {
                        field("PHP") {
                            Picker("", selection: $host.phpVersion) {
                                Text(L("host.phpStatic")).tag("")
                                ForEach(vm.phpVersions, id: \.self) { version in
                                    Text(vm.phpLabel(version)).tag(version)
                                }
                            }
                            .pickerStyle(.menu).labelsHidden().fixedSize()
                        }
                        field(L("column.port")) {
                            TextField("80", value: $host.port, format: .number).textFieldStyle(.roundedBorder).frame(width: 80)
                        }
                    }
                    field(L("host.rewrite"), hint: L("host.rewriteHint")) {
                        Picker("", selection: $rewriteTemplate) {
                            Text(L("host.rewriteTemplate")).tag("")
                            ForEach(rewriteTemplates, id: \.0) { item in
                                Text(item.0).tag(item.0)
                            }
                        }
                        .pickerStyle(.menu).labelsHidden().frame(maxWidth: 240, alignment: .leading)
                        .onChange(of: rewriteTemplate) { name in
                            guard let item = rewriteTemplates.first(where: { $0.0 == name }) else { return }
                            host.rewrite = item.1
                        }
                        HStack(alignment: .top, spacing: 8) {
                            editor($host.rewrite, height: 110)
                            Button(L("host.autoFill")) {
                                vm.service.autoFillRewrite(&host)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Text(host.name.isEmpty ? "" : host.url).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("action.cancel")) { dismiss() }
                Button(L("action.save")) { vm.apply(host); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.name.trimmingCharacters(in: .whitespaces).isEmpty || host.root.isEmpty)
            }
            .padding(20)
        }
        .frame(width: AppTheme.sheetWidth, height: AppTheme.formSheetHeight)
        .onAppear { if rewriteTemplates.isEmpty { rewriteTemplates = loadRewriteTemplates() } }
    }

    // 内置伪静态模板（RewriteDefaults/，抄自 FlyEnv 的 static/rewrite）。
    private func loadRewriteTemplates() -> [(String, String)] {
        guard let url = Bundle.main.url(forResource: "RewriteDefaults", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return [] }
        return files.filter { $0.pathExtension == "conf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { ($0.deletingPathExtension().lastPathComponent, (try? String(contentsOf: $0, encoding: .utf8)) ?? "") }
    }

    private func field<Content: View>(_ label: String, hint: String = "", @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.callout.weight(.semibold))
            content()
            if !hint.isEmpty { Text(hint).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func editor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.system(.body, design: .monospaced))
            .frame(height: height)
            .padding(4)
            .background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: AppTheme.radiusCard))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusCard).stroke(AppTheme.stroke))
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        host.root = url.path
    }
}

// MARK: - 站点配置文件

struct HostConfigView: View {
    @ObservedObject var vm: HostViewModel
    @Environment(\.dismiss) private var dismiss
    let host: Host
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(host.name + " · " + L("host.editConfig")).font(.headline)
                Spacer()
                Button(L("action.cancel")) { dismiss() }
                Button(L("action.save")) {
                    vm.saveConfig(host, text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .panelHeader()
            Divider()
            CodeEditor(text: $text, editable: true)
        }
        .frame(width: AppTheme.sheetWidth, height: AppTheme.sheetHeight)
        .onAppear { text = vm.configText(host) }
    }
}
