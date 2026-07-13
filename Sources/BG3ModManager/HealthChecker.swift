import Foundation

/// Cross-checks the whole load order for dependency and compatibility problems, without reading disk
/// again (it works off the meta already parsed for each mod). Surfaces four classes of issue that
/// otherwise only show up as a crash or a missing feature in-game.
enum HealthChecker {

    enum Kind: Hashable {
        case missingDependency(uuid: String)          // declared dep isn't installed at all
        case dependencyDisabled(name: String)         // dep is installed but not enabled
        case dependencyLoadsAfter(name: String)       // dep is enabled but lower in the order (too late)
        case needsScriptExtender                      // SE-dependent mod in an env that can't run SE
        case unreadableMeta                           // pak's meta.lsx couldn't be parsed

        var severity: Severity {
            switch self {
            case .missingDependency, .dependencyDisabled, .needsScriptExtender: return .error
            case .dependencyLoadsAfter: return .warning
            case .unreadableMeta: return .warning
            }
        }
        var label: String {
            switch self {
            case .missingDependency(let uuid): return "Missing dependency \(uuid.prefix(8))…"
            case .dependencyDisabled(let n):   return "Requires “\(n)”, which is disabled"
            case .dependencyLoadsAfter(let n): return "Loads before its dependency “\(n)”"
            case .needsScriptExtender:         return "Needs Script Extender (not available here)"
            case .unreadableMeta:              return "Couldn’t read meta.lsx"
            }
        }
        var fixHint: String {
            switch self {
            case .missingDependency:   return "Install the required mod, or remove this one."
            case .dependencyDisabled:  return "Enable the required mod."
            case .dependencyLoadsAfter:return "Run Auto-sort, or drag the dependency above this mod."
            case .needsScriptExtender: return "Use a CrossOver install, or remove this mod."
            case .unreadableMeta:      return "The pak may be corrupt or an unsupported format."
            }
        }
    }

    enum Severity: Int, Hashable { case warning = 0, error = 1 }

    /// A concrete action the app can take to fix an issue, surfaced as a button in the Health tab.
    enum Resolution: Hashable {
        case none
        case autoSort                              // dependency loads too late → re-sort
        case enableDependency(uuid: String)        // required dep is installed but disabled
        case disableThisMod(modID: String)         // SE-incompatible here → turn it off
        case copyUUID(String)                      // missing dep → copy its UUID to go find it

        var actionTitle: String? {
            switch self {
            case .none:               return nil
            case .autoSort:           return "Auto-sort"
            case .enableDependency:   return "Enable dependency"
            case .disableThisMod:     return "Disable this mod"
            case .copyUUID:           return "Copy UUID"
            }
        }
        var actionIcon: String {
            switch self {
            case .autoSort:         return "wand.and.stars"
            case .enableDependency: return "power"
            case .disableThisMod:   return "minus.circle"
            case .copyUUID:         return "doc.on.doc"
            case .none:             return "questionmark"
            }
        }
        /// True for actions the app can apply with no further input (excludes copy/none).
        var isAutomatic: Bool {
            switch self {
            case .autoSort, .enableDependency, .disableThisMod: return true
            case .copyUUID, .none: return false
            }
        }
    }

    struct Issue: Identifiable, Hashable {
        let modName: String
        let kind: Kind
        let resolution: Resolution
        var id: String { modName + "|" + String(describing: kind) }
        var severity: Severity { kind.severity }
    }

    struct Report {
        var issues: [Issue]
        var checkedCount: Int
        var errorCount: Int { issues.filter { $0.severity == .error }.count }
        var warningCount: Int { issues.filter { $0.severity == .warning }.count }
        var isHealthy: Bool { issues.isEmpty }
        var hasAutoFixes: Bool { issues.contains { $0.resolution.isAutomatic } }
    }

    /// `enabled` must be the enabled mods in load order; `all` is every installed mod (for resolving deps).
    static func check(enabled: [Mod], all: [Mod]) -> Report {
        let installedByUUID: [String: Mod] = Dictionary(
            all.compactMap { m in m.meta.map { ($0.uuid.lowercased(), m) } },
            uniquingKeysWith: { a, _ in a }
        )
        let enabledIndex: [String: Int] = Dictionary(
            enabled.enumerated().compactMap { i, m in m.meta.map { ($0.uuid.lowercased(), i) } },
            uniquingKeysWith: { a, _ in a }
        )

        var issues: [Issue] = []

        for (i, mod) in enabled.enumerated() {
            guard let meta = mod.meta else {
                issues.append(Issue(modName: mod.displayName, kind: .unreadableMeta, resolution: .none))
                continue
            }
            if mod.compatibility == .needsScriptExtender {
                issues.append(Issue(modName: mod.displayName, kind: .needsScriptExtender,
                                    resolution: .disableThisMod(modID: mod.id)))
            }
            for depRaw in meta.dependencyUUIDs {
                let dep = depRaw.lowercased()
                if dep == ModSettings.gustavDev.uuid || dep == meta.uuid.lowercased() { continue }
                if let depMod = installedByUUID[dep] {
                    if let depIndex = enabledIndex[dep] {
                        if depIndex > i {
                            issues.append(Issue(modName: mod.displayName,
                                                kind: .dependencyLoadsAfter(name: depMod.displayName),
                                                resolution: .autoSort))
                        }
                    } else {
                        issues.append(Issue(modName: mod.displayName,
                                            kind: .dependencyDisabled(name: depMod.displayName),
                                            resolution: .enableDependency(uuid: dep)))
                    }
                } else {
                    issues.append(Issue(modName: mod.displayName, kind: .missingDependency(uuid: depRaw),
                                        resolution: .copyUUID(depRaw)))
                }
            }
        }

        // Errors first, then warnings; alphabetical within.
        issues.sort {
            $0.severity != $1.severity ? $0.severity.rawValue > $1.severity.rawValue
                                       : $0.modName.localizedCaseInsensitiveCompare($1.modName) == .orderedAscending
        }
        return Report(issues: issues, checkedCount: enabled.count)
    }
}
