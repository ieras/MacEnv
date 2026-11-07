import Foundation

enum Brew {
    static var executable: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func core(_ name: String) -> String { name.contains("/") ? name : "homebrew/core/\(name)" }

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

    static func installedBinaries(_ app: String, binary: String, subdirectory: String = "bin") async throws -> [(file: URL, formula: String)] {
        let fm = FileManager.default
        var result: [(URL, String)] = []
        for cellar in ["/opt/homebrew/Cellar", "/usr/local/Cellar"] {
            let formulae = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: cellar), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            for formula in formulae where formula.lastPathComponent == app || formula.lastPathComponent.hasPrefix(app + "@") {
                for keg in (try? fm.contentsOfDirectory(at: formula, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
                    let file = keg.appendingPathComponent("\(subdirectory)/\(binary)")
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

    static func run(_ operation: String, formula: String,
                    report: @escaping (String) -> Void = { _ in },
                    onStart: ((Process) -> Void)? = nil) async throws {
        guard let executable else { throw CommandError(message: L("error.brewMissing")) }
        let name = operation == "install" || operation == "upgrade" ? core(formula) : formula
        let arguments = operation == "update" ? ["update"] : [operation, name]
        let status = try await Command.stream(executable, arguments, environment: Command.brewEnvironment,
                                              onStart: onStart, onOutput: report)
        guard status == 0 else { throw CommandError(message: L("error.brewFailed") + "（\(status)）") }
    }

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
