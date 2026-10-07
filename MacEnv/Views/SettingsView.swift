import SwiftUI

struct SettingsView: View {
    @ObservedObject var app: AppViewModel

    var body: some View {
        TabView {
            general
                .tabItem { Label(L("settings.general"), systemImage: "gearshape") }
            developer
                .tabItem { Label(L("settings.developer"), systemImage: "terminal") }
            modules
                .tabItem { Label(L("settings.module"), systemImage: "square.stack") }
        }
        .formStyle(.grouped)
        .padding(20)
        // 高度按通用/开发者这两个 tab 的内容定；模块 tab 内容更长，自己滚（而且不显示滚动条）。
        // 这两个 Form 关掉滚动：macOS 的 Form 自带滚动，高度差一点点就会冒出滚动条，很难看。
        .frame(width: 520, height: 360)
    }

    private var general: some View {
        Form {
            Picker(L("settings.appearance"), selection: $app.state.theme) {
                ForEach(ThemeMode.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: app.state.theme) { _ in app.state.applyTheme() }
            Picker(L("settings.language"), selection: $app.state.language) {
                ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
            }
            settingToggle(L("settings.launchAtLogin"), $app.state.autoLaunch)
            settingToggle(L("settings.hideOnClose"), $app.state.hideOnClose)
            settingToggle(L("settings.autoStartService"), $app.state.autoStartService)
            LabeledContent(L("settings.codeFontSize")) {
                HStack(spacing: 8) {
                    Slider(value: $app.state.codeFontSize, in: 11...20, step: 1)
                    Text("\(Int(app.state.codeFontSize)) pt")
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
            }
        }
        .scrollDisabled(true)
    }

    private var developer: some View {
        Form {
            TextField(L("settings.catalogService"), text: $app.state.catalogURL,
                      prompt: Text(StaticCatalogService.defaultEndpoint.absoluteString))
            Text(L("settings.catalogServiceHint") + StaticCatalogService.defaultEndpoint.absoluteString)
                .foregroundStyle(.secondary).textSelection(.enabled)
            settingToggle(L("settings.proxy"), $app.state.proxyEnabled)
            HStack {
                TextField(L("settings.proxyHost"), text: $app.state.proxyHost, prompt: Text("127.0.0.1"))
                TextField(L("settings.proxyPort"), text: $app.state.proxyPort, prompt: Text("7890")).frame(width: 90)
            }
            Button(L("settings.openDataDir")) { NSWorkspace.shared.open(app.root) }
        }
        .scrollDisabled(true)
    }

    // 一行 3 个卡片：窗口宽 500，去掉内边距和间距后每张约 146pt。
    private let moduleColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    private var modules: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // 「控制台」不来自 moduleGroups（侧栏里那个标题是手画的），但它的开关得在这儿，
                // 否则「环境工具」一旦关掉就再也没地方打开。
                moduleGroupCard(title: L("sidebar.console"), ids: consoleModules)
                ForEach(moduleGroups, id: \.0) { group in
                    moduleGroupCard(title: L(group.0), ids: group.1)
                }
            }
        }
    }

    // 分类名右边的开关照 FlyEnv：整组一键全开/全关，组内有一个开着就算开。
    private func moduleGroupCard(title: String, ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { ids.contains { app.state.modules[$0] ?? true } },
                    set: { value in ids.forEach { app.state.modules[$0] = value } }
                ))
                .labelsHidden().toggleStyle(ServiceSwitch())
            }
            .padding(.bottom, 8)
            Divider().padding(.bottom, 10)
            LazyVGrid(columns: moduleColumns, spacing: 10) {
                ForEach(ids, id: \.self) { moduleCard($0) }
            }
            .padding(.bottom, 18)
        }
    }

    private func moduleCard(_ id: String) -> some View {
        HStack(spacing: 6) {
            Text(moduleName(id)).lineLimit(1)
            // 图标跟在名字后面，高度跟文字差不多（14pt）。
            ModuleIcon(id: id).frame(width: 14, height: 14)
            Spacer(minLength: 2)
            Toggle("", isOn: Binding(get: { app.state.modules[id] ?? true }, set: { app.state.modules[id] = $0 }))
                .labelsHidden().toggleStyle(ServiceSwitch())
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(AppTheme.cardBackground, in: RoundedRectangle(cornerRadius: AppTheme.radiusCard))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusCard).stroke(AppTheme.stroke))
    }

    // 开关统一走 ServiceSwitch（自绘胶囊，窗口失焦也不会变灰），
    // label 交给 LabeledContent 渲染，保证跟代码字号那行的排布一致。
    private func settingToggle(_ title: String, _ isOn: Binding<Bool>) -> some View {
        LabeledContent(title) { Toggle("", isOn: isOn).labelsHidden().toggleStyle(ServiceSwitch()) }
    }
}
