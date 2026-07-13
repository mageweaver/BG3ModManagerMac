import Foundation

/// Parsed `meta.lsx` contents that BG3 needs in order to load a mod and order it correctly.
struct ModMeta: Hashable, Codable {
    var name: String
    var folder: String          // the in-pak top-level folder; used by modsettings.lsx
    var uuid: String
    var md5: String
    var version64: String       // BG3 packs the version into a single Int64 string
    var author: String
    /// UUIDs of mods this one depends on (from the <dependencies> node).
    var dependencyUUIDs: [String]
    /// True if the meta references the Script Extender (ScriptExtender config node or a known SE dependency).
    var requiresScriptExtender: Bool
}

/// A mod the user has on disk (a `.pak` file in the Mods folder), enriched with its meta and state.
struct Mod: Identifiable, Hashable {
    var id: String { meta?.uuid ?? fileURL.path }
    var fileURL: URL
    var meta: ModMeta?
    /// True when this mod appears in modsettings.lsx (i.e. enabled in the active load order).
    var isEnabled: Bool
    /// Position within the load order (only meaningful when enabled).
    var loadOrderIndex: Int?
    /// Why, if at all, this mod is flagged as problematic on Mac.
    var compatibility: Compatibility

    var displayName: String {
        meta?.name ?? fileURL.deletingPathExtension().lastPathComponent
    }

    enum Compatibility: Hashable {
        case ok
        /// Needs the Script Extender, which only works under CrossOver (never on the native Mac build).
        case needsScriptExtender
        /// meta.lsx could not be parsed; load order entry may be incomplete.
        case unreadableMeta
    }
}

/// A search hit from Nexus or mod.io that the user can download.
struct RemoteMod: Identifiable, Hashable {
    enum Source: String { case nexus = "Nexus Mods", modio = "mod.io" }
    var id: String           // "<source>:<modID>"
    var source: Source
    var modID: Int
    var name: String
    var summary: String
    var author: String
    var thumbnailURL: URL?
    var pageURL: URL?
    /// Heuristic: does the listing mention the Script Extender?
    var mentionsScriptExtender: Bool
}
