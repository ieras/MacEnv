import Foundation

// Homebrew 的公共入口。PHP 和数据库两个模块都要「按公式名查版本 + 执行安装卸载」，
// 抽出来省一份重复的 JSON 解析。Nginx 的 brew 信息结构不同，留在自己那边。
enum Brew {
    static var executable: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // 机器上装了第三方 tap（比如 shivammathur/php）时，裸公式名会解析到那个 tap 上，
    // brew 以「untrusted tap」为由直接拒绝加载，整个版本列表就空了。限定 homebrew/core/
    // 就绕开了 —— 返回的 full_name 还是裸名，界面照旧。
    private static func core(_ name: String) -> String { name.contains("/") ? name : "homebrew/core/\(name)" }

    // 查 name 和 name@版本 这一族公式，只留 brew 真实返回的那些。
    static func formulae(_ name: String) async throws -> [BrewFormulaItem] {
        guard let executable else { return [] }
        let search = try await Command.run(executable, ["search", "--formula", "/^\(name)(@[0-9.]+)?$/"], environment: Command.brewEnvironment)
        var names = Set([name])
        for line in search.stdout.split(whereSeparator: \.isNewline).map(String.init) {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value == name || (value.hasPrefix(name + "@") && value.dropFirst(name.count + 1).allSatisfy { $0.isNumber || $0 == "." }) {
                names.insert(value)
            }
        }
        let output = try await Command.run(executable, ["info", "--json=v2", "--formula"] + names.sorted().map(core), environment: Command.brewEnvironment)
        guard output.status == 0,
              let json = try JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any],
              let values = json["formulae"] as? [[String: Any]] else { return [] }
        return values.compactMap { item in
            guard let formula = item["full_name"] as? String ?? item["name"] as? String else { return nil }
            return BrewFormulaItem(name: formula,
                                   stable: (item["versions"] as? [String: Any])?["stable"] as? String ?? "",
                                   installedVersions: (item["installed"] as? [[String: Any]] ?? []).compactMap { $0["version"] as? String },
                                   linkedVersion: item["linked_keg"] as? String,
                                   outdated: item["outdated"] as? Bool ?? false)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func run(_ operation: String, formula: String) async throws -> String {
        guard let executable else { throw CommandError(message: L("error.brewMissing")) }
        // 安装 / 升级要限定 core，否则裸名一样会撞上未信任的 tap。
        // 卸载绝不能限定：brew 拿到带 tap 的名字会按 tap 过滤已安装的 keg
        // （cli/named_args.rb 的 resolve_kegs），本机这些 keg 来自第三方 tap，限定后反而找不到。
        let name = operation == "install" || operation == "upgrade" ? core(formula) : formula
        let output = try await Command.run(executable, operation == "update" ? ["update"] : [operation, name], environment: Command.brewEnvironment)
        guard output.status == 0 else { throw CommandError(message: output.text) }
        return output.text
    }
}
