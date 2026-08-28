import Foundation

/// Cross-checks the whole load order for dependency and compatibility problems, without reading disk
/// again (it works off the meta already parsed for each mod). Surfaces four classes of issue that
/// otherwise only show up as a crash or a missing feature in-game.
enum HealthChecker {

    enum Kind: Hashable {
        case missingDependency(name: String, uuid: String)   // declared dep isn't installed at all
        case dependencyDisabled(name: String)         // dep is installed but not enabled
        case dependencyLoadsAfter(name: String)       // dep is enabled but lower in the order (too late)
        case needsScriptExtender                      // SE-dependent mod in an env that can't run SE
        case unreadableMeta                           // pak's meta.lsx couldn't be parsed
        case missingPakPart(names: [String])          // split archive is missing one of its parts
        case conflictsWith(name: String)              // an incompatible mod is enabled at the same time
        case duplicateModule(names: [String], files: [String])   // several paks declare one module UUID

        var severity: Severity {
            switch self {
            case .missingDependency, .dependencyDisabled, .needsScriptExtender: return .error
            case .missingPakPart, .conflictsWith: return .error
            case .duplicateModule: return .warning
            case .dependencyLoadsAfter: return .warning
            case .unreadableMeta: return .warning
            }
        }
        var label: String {
            switch self {
            case .missingDependency(let name, let uuid):
                // The name is what the user can act on; the UUID is only a fallback when a mod
                // declares a dependency without naming it.
                return name.isEmpty ? "Missing dependency \(uuid.prefix(8))…" : "Missing dependency “\(name)”"
            case .dependencyDisabled(let n):   return "Requires “\(n)”, which is disabled"
            case .dependencyLoadsAfter(let n): return "Loads before its dependency “\(n)”"
            case .needsScriptExtender:         return "Needs Script Extender (not set up for this install)"
            case .unreadableMeta:              return "Couldn’t read meta.lsx"
            case .conflictsWith(let name):     return "Conflicts with “\(name)”, also enabled"
            case .duplicateModule(let names, let files):
                // Name them as the list names them. A mod renamed between versions appears under two
                // different titles, so listing only filenames sends you hunting for a row that
                // doesn't exist.
                let shown = names.map { "“\($0)”" }.joined(separator: " and ")
                return "Installed \(files.count) times — shown in the list as \(shown)"
            case .missingPakPart(let names):
                let list = names.joined(separator: ", ")
                return names.count == 1 ? "Missing split file \(list)" : "Missing split files \(list)"
            }
        }
        var fixHint: String {
            switch self {
            case .missingDependency:   return "Install the required mod, or remove this one. Use Copy UUID to search for it."
            case .dependencyDisabled:  return "Enable the required mod."
            case .dependencyLoadsAfter:return "Run Auto-sort, or drag the dependency above this mod."
            case .needsScriptExtender: return "Set up the Script Extender for this install (see the Script Extender tab), or remove this mod."
            case .unreadableMeta:      return "The pak may be corrupt or an unsupported format."
            case .duplicateModule(_, let files):
                return "Same mod UUID in \(files.joined(separator: ", ")) — newest version first. The load order names a mod once, so BG3 loads one of these and ignores the rest. Delete the ones you don't want."
            case .conflictsWith:
                return "The author marked these as incompatible — usually alternative editions of the same mod. Enable only one."
            case .missingPakPart:
                return "This mod is split across several files. Copy the missing one into the Mods folder — the mod won’t load without it."
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

        // Several paks claiming one module UUID: the order names it once, so the list shows more
        // rows than the game will actually load, and which copy wins is undefined.
        var byUUID: [String: [Mod]] = [:]
        for mod in enabled {
            guard let uuid = mod.meta?.uuid.lowercased() else { continue }
            byUUID[uuid, default: []].append(mod)
        }
        for (_, group) in byUUID where group.count > 1 {
            // Newest first, so the hint's file list reads as "keep this one".
            let ordered = group.sorted {
                (Int64($0.meta?.version64 ?? "0") ?? 0) > (Int64($1.meta?.version64 ?? "0") ?? 0)
            }
            issues.append(Issue(modName: ordered[0].displayName,
                                kind: .duplicateModule(names: ordered.map(\.displayName),
                                                       files: ordered.map { $0.fileURL.lastPathComponent }),
                                resolution: .none))
        }

        for (i, mod) in enabled.enumerated() {
            // Checked before meta, because a mod missing its first part can't be read at all.
            if !mod.missingParts.isEmpty {
                issues.append(Issue(modName: mod.displayName,
                                    kind: .missingPakPart(names: mod.missingParts),
                                    resolution: .none))
            }
            guard let meta = mod.meta else {
                issues.append(Issue(modName: mod.displayName, kind: .unreadableMeta, resolution: .none))
                continue
            }
            if mod.compatibility == .needsScriptExtender {
                issues.append(Issue(modName: mod.displayName, kind: .needsScriptExtender,
                                    resolution: .disableThisMod(modID: mod.id)))
            }
            // Conflicts only matter when the other mod is actually enabled; an uninstalled or
            // disabled conflict is the state the author wanted.
            for conflict in meta.conflicts {
                let key = conflict.uuid.lowercased()
                guard key != meta.uuid.lowercased(), enabledIndex[key] != nil,
                      let other = installedByUUID[key] else { continue }
                issues.append(Issue(modName: mod.displayName,
                                    kind: .conflictsWith(name: other.displayName),
                                    resolution: .disableThisMod(modID: other.id)))
            }

            for dependency in meta.dependencies {
                let dep = dependency.uuid.lowercased()
                // Larian's own modules are declared by nearly every mod and are never paks on disk,
                // so checking them would flag almost the whole list and hide the real problems.
                if BaseGameModules.isBaseGame(dependency) { continue }
                if dep == meta.uuid.lowercased() { continue }
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
                    issues.append(Issue(modName: mod.displayName,
                                        kind: .missingDependency(name: dependency.name, uuid: dependency.uuid),
                                        resolution: .copyUUID(dependency.uuid)))
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
