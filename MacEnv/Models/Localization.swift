import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zhHans, zhHant, en, ja

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        case .ja: return "日本語"
        }
    }

    var lproj: String? {
        switch self {
        case .system: return nil
        case .zhHans: return "zh-Hans"
        case .zhHant: return "zh-Hant"
        case .en: return "en"
        case .ja: return "ja"
        }
    }

    func text(_ key: String) -> String {
        guard let name = lproj,
              let path = Bundle.main.path(forResource: name, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return Bundle.main.localizedString(forKey: key, value: key, table: nil)
        }
        let text = bundle.localizedString(forKey: key, value: nil, table: nil)
        return text == key ? Bundle.main.localizedString(forKey: key, value: key, table: nil) : text
    }
}

enum L10n {
    static var language: AppLanguage = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "macenv.language") ?? AppLanguage.system.rawValue) ?? .system
}

func L(_ key: String) -> String { L10n.language.text(key) }

enum ThemeMode: String, CaseIterable, Identifiable {
    case automatic, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return L("theme.automatic")
        case .light: return L("theme.light")
        case .dark: return L("theme.dark")
        }
    }
}

// Brew 下载源。只改我们调 brew 时注入的环境变量，不动用户自己的 brew 配置。
enum BrewSource: String, CaseIterable, Identifiable {
    case official, tencent, tsinghua, aliyun, ustc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .official: return L("brewSrc.official")
        case .tencent: return L("brewSrc.tencent")
        case .tsinghua: return L("brewSrc.tsinghua")
        case .aliyun: return L("brewSrc.aliyun")
        case .ustc: return L("brewSrc.ustc")
        }
    }

    // 现代 brew 认这两个：API 域给公式元数据，瓶子域给预编译包。官方源留空（不覆盖）。
    var environment: [String: String] {
        switch self {
        case .official: return [:]
        case .tencent: return domains("https://mirrors.tencent.com/homebrew-bottles")
        case .tsinghua: return domains("https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles")
        case .aliyun: return domains("https://mirrors.aliyun.com/homebrew/homebrew-bottles")
        case .ustc: return domains("https://mirrors.ustc.edu.cn/homebrew-bottles")
        }
    }

    private func domains(_ base: String) -> [String: String] {
        ["HOMEBREW_API_DOMAIN": base + "/api", "HOMEBREW_BOTTLE_DOMAIN": base]
    }
}

extension ThemeMode {
    var iconName: String {
        switch self {
        case .automatic: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    static var initial: ThemeMode { ThemeMode(rawValue: UserDefaults.standard.string(forKey: "macenv.theme") ?? automatic.rawValue) ?? .automatic }
}
