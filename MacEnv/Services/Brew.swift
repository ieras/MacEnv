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

    // 已安装版本只读本地 Cellar，不查询远程公式；第三方 tap 从安装凭据保留。
    static func installedBinaries(_ app: String, binary: String) async throws -> [(file: URL, formula: String)] {
        let fm = FileManager.default
        var result: [(URL, String)] = []
        for cellar in ["/opt/homebrew/Cellar", "/usr/local/Cellar"] {
            let formulae = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: cellar), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            for formula in formulae where formula.lastPathComponent == app || formula.lastPathComponent.hasPrefix(app + "@") {
                for keg in (try? fm.contentsOfDirectory(at: formula, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
                    let file = keg.appendingPathComponent("bin/\(binary)")
                    guard fm.isExecutableFile(atPath: file.path) else { continue }
                    let receipt = try? Data(contentsOf: keg.appendingPathComponent("INSTALL_RECEIPT.json"))
                    let json = receipt.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    let tap = (json?["source"] as? [String: Any])?["tap"] as? String
                    let name = tap.map { $0 == "homebrew/core" ? formula.lastPathComponent : $0 + "/" + formula.lastPathComponent } ?? formula.lastPathComponent
                    result.append((file, name))
                }
            }
        }
        return result
    }

    // 安装 / 卸载动辄几分钟（下瓶子、编译、装依赖），输出一律实时喂给任务日志 ——
    // 只在结束时把 output.text 一次性抛出来，界面全程是一动不动的转圈，出错了也看不到是哪一步。
    static func run(_ operation: String, formula: String,
                    report: @escaping (String) -> Void = { _ in },
                    onStart: ((Process) -> Void)? = nil) async throws {
        guard let executable else { throw CommandError(message: L("error.brewMissing")) }
        // 安装 / 升级要限定 core，否则裸名一样会撞上未信任的 tap。
        // 卸载绝不能限定：brew 拿到带 tap 的名字会按 tap 过滤已安装的 keg
        // （cli/named_args.rb 的 resolve_kegs），本机这些 keg 来自第三方 tap，限定后反而找不到。
        let name = operation == "install" || operation == "upgrade" ? core(formula) : formula
        let arguments = operation == "update" ? ["update"] : [operation, name]
        let status = try await Command.stream(executable, arguments, environment: Command.brewEnvironment,
                                              onStart: onStart, onOutput: report)
        // 失败原因已经在日志里了（brew 把每一步都打出来了），这里只补一句结论。
        guard status == 0 else { throw CommandError(message: L("error.brewFailed") + "（\(status)）") }
    }

    // brew 列表的展示行：一行 = 公式 + 一个已装版本（没装过的公式给一行空版本）。
    // 全表按版本号从大到小 —— 最新版本永远在最上面（跟 MacPorts 可装清单同一个口径）。
    // 表达式拆开写：整条链塞给类型检查器会「unable to type-check in reasonable time」。
    static func listRows(_ formulae: [BrewFormulaItem]) -> [(formula: BrewFormulaItem, version: String?)] {
        let rows: [(formula: BrewFormulaItem, version: String?)] = formulae.flatMap { formula -> [(formula: BrewFormulaItem, version: String?)] in
            if formula.installedVersions.isEmpty { return [(formula, nil as String?)] }
            return formula.installedVersions.map { (formula, $0) }
        }
        return rows.sorted { lhs, rhs in
            let left = lhs.version ?? lhs.formula.stable
            let right = rhs.version ?? rhs.formula.stable
            return left.compare(right, options: .numeric) == .orderedDescending
        }
    }
}
