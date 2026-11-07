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

    private let moduleColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    private var modules: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                moduleGroupCard(title: L("sidebar.console"), ids: consoleModules)
                ForEach(moduleGroups, id: \.0) { group in
                    moduleGroupCard(title: L(group.0), ids: group.1)
                }
            }
        }
    }

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
            ModuleIcon(id: id).frame(width: 14, height: 14)
            Spacer(minLength: 2)
            Toggle("", isOn: Binding(get: { app.state.modules[id] ?? true }, set: { app.state.modules[id] = $0 }))
                .labelsHidden().toggleStyle(ServiceSwitch())
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(AppTheme.cardBackground, in: RoundedRectangle(cornerRadius: AppTheme.radiusCard))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.radiusCard).stroke(AppTheme.stroke))
    }

    private func settingToggle(_ title: String, _ isOn: Binding<Bool>) -> some View {
        LabeledContent(title) { Toggle("", isOn: isOn).labelsHidden().toggleStyle(ServiceSwitch()) }
    }
}
