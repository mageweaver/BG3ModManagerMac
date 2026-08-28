import Foundation

/// One entry from a mod's `<node id="Dependencies">`. The name travels with the UUID because a bare
/// UUID tells the user nothing about what to go and install.
struct ModDependency: Hashable, Codable {
    var uuid: String
    var name: String
    var folder: String
}

/// Parsed `meta.lsx` contents that BG3 needs in order to load a mod and order it correctly.
struct ModMeta: Hashable, Codable {
    var name: String
    var folder: String          // the in-pak top-level folder; used by modsettings.lsx
    var uuid: String
    var md5: String
    var version64: String       // BG3 packs the version into a single Int64 string
    var author: String
    /// Mods this one depends on (from the <Dependencies> node).
    var dependencies: [ModDependency]
    /// Mods this one declares itself incompatible with (from the <Conflicts> node). Usually
    /// alternative editions of the same mod — the author expects exactly one to be installed.
    var conflicts: [ModDependency] = []
    /// Just the UUIDs, for the ordering code that only cares about identity.
    var dependencyUUIDs: [String] { dependencies.map(\.uuid) }
    /// True if the meta references the Script Extender (ScriptExtender config node or a known SE dependency).
    var requiresScriptExtender: Bool
}

/// A mod the user has on disk (a `.pak` file in the Mods folder), enriched with its meta and state.
struct Mod: Identifiable, Hashable {
    /// Identity is the file on disk, not the module UUID.
    ///
    /// Several paks can legitimately declare the same UUID — an old copy kept beside a new one, a
    /// duplicate "… 2.pak" from a re-download — and a UUID-keyed identity then makes them one row as
    /// far as SwiftUI, selection and load-order positions are concerned. The path is always unique.
    var id: String { fileURL.path }
    /// The module UUID, when the meta could be read. This is what BG3 and the load order key on, and
    /// what dependency resolution matches; it is deliberately not the row identity.
    var moduleUUID: String? { meta?.uuid }
    var fileURL: URL
    var meta: ModMeta?
    /// True when this mod appears in modsettings.lsx (i.e. enabled in the active load order).
    var isEnabled: Bool
    /// Position within the load order (only meaningful when enabled).
    var loadOrderIndex: Int?
    /// Why, if at all, this mod is flagged as problematic on Mac.
    var compatibility: Compatibility
    /// Extra files this archive is split across (`Name_1.pak`, …). Not mods in their own right —
    /// they carry no header — but the game needs them beside the main pak, so they travel with it
    /// and are deleted with it.
    var parts: [URL] = []
    /// Split parts the pak's own header says should exist but that aren't in the Mods folder.
    /// The mod will not load correctly without them.
    var missingParts: [String] = []
    /// When the pak landed in the Mods folder, from the filesystem. Only a proxy for "installed":
    /// copying a pak between folders (native <-> CrossOver, or off a share) resets it. An exact
    /// date is recorded in `InstallRecord.installedAt` for anything installed through this app.
    var fileCreatedAt: Date?

    var displayName: String {
        meta?.name ?? fileURL.deletingPathExtension().lastPathComponent
    }

    /// Every file on disk that belongs to this mod — the archive plus any split parts.
    var allFiles: [URL] { [fileURL] + parts }
    var isSplit: Bool { !parts.isEmpty || !missingParts.isEmpty }

    /// Stable key for attaching user notes: the UUID when known, else the `.pak` filename. Survives
    /// refreshes and folder moves (native ↔ CrossOver) better than the full file path.
    var noteKey: String {
        meta.map { $0.uuid.lowercased() } ?? fileURL.lastPathComponent.lowercased()
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
    enum Source: String, Codable { case nexus = "Nexus Mods", modio = "mod.io" }
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
