import Foundation

/// A saved, named load order the user can swap to. Stores just enough per mod (UUID + folder + name)
/// to re-enable and re-order whatever is currently installed.
struct LoadOrderProfile: Identifiable, Codable, Hashable {
    struct Entry: Codable, Hashable {
        var uuid: String
        var folder: String
        var name: String
    }
    var id: UUID
    var name: String
    var createdAt: Date
    /// Which install this was saved from (documentsBase path) — informational.
    var environmentID: String?
    var entries: [Entry]

    /// Mods that couldn't be stored, and why — so a save can report an honest count instead of a
    /// silently shortened one.
    struct Skipped {
        var noMeta: [String] = []      // no readable meta.lsx, so no UUID to record
        var duplicates: [String] = []  // a second pak claiming a UUID already in the profile
        var total: Int { noMeta.count + duplicates.count }
    }

    init(name: String, environmentID: String?, mods: [Mod], skipped: inout Skipped) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.environmentID = environmentID
        self.entries = []

        // A profile is keyed on UUID: a mod with no readable meta has none, and a second pak
        // claiming a UUID already present would just be dropped again on apply. Both are excluded —
        // but recorded, because a count that quietly disagrees with the load order is worse than a
        // smaller one that explains itself.
        var seen = Set<String>()
        for mod in mods {
            guard let meta = mod.meta else {
                skipped.noMeta.append(mod.displayName)
                continue
            }
            guard seen.insert(meta.uuid.lowercased()).inserted else {
                skipped.duplicates.append(mod.displayName)
                continue
            }
            entries.append(Entry(uuid: meta.uuid, folder: meta.folder, name: meta.name))
        }
    }

    init(name: String, environmentID: String?, mods: [Mod]) {
        var ignored = Skipped()
        self.init(name: name, environmentID: environmentID, mods: mods, skipped: &ignored)
    }

    /// Build from a bare list of entries — for orders that arrive without a profile identity
    /// of their own, so `id` and `createdAt` have to be minted here.
    init(name: String, entries: [Entry]) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.environmentID = nil
        self.entries = entries
    }
}

/// A plain load order as written by external tooling and by BG3 Mod Manager on Windows:
/// `{"Order": [{"UUID": …, "Name": …}]}`, with no profile identity attached. `Folder` is
/// optional because Windows omits it; only `UUID` is load-bearing, since that is what
/// `applyProfile` matches installed mods on.
private struct PlainOrderFile: Decodable {
    struct Entry: Decodable {
        var uuid: String
        var folder: String?
        var name: String?

        private enum CodingKeys: String, CodingKey {
            case uuid = "UUID", folder = "Folder", name = "Name"
        }
    }
    var order: [Entry]

    private enum CodingKeys: String, CodingKey { case order = "Order" }
}

/// Persists profiles to `~/Library/Application Support/BG3ModManagerMac/profiles.json`.
enum ProfileStore {
    private static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BG3ModManagerMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("profiles.json")
    }

    static func load() -> [LoadOrderProfile] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LoadOrderProfile].self, from: data)) ?? []
    }

    static func save(_ profiles: [LoadOrderProfile]) {
        if let data = try? encoder().encode(profiles) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: Share a single profile as a portable .json file

    static func exportProfile(_ profile: LoadOrderProfile, to url: URL) throws {
        let data = try encoder().encode(profile)
        try data.write(to: url, options: .atomic)
    }

    /// Read a shared load order. Accepts a profile as exported here (one, or an array — takes the
    /// first), or a plain `{"Order": […]}` list from external tooling, which is named after the file.
    static func importProfile(from url: URL) throws -> LoadOrderProfile {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let one = try? decoder.decode(LoadOrderProfile.self, from: data) { return one }

        if let many = try? decoder.decode([LoadOrderProfile].self, from: data) {
            guard let first = many.first else { throw ImportError.noProfiles }
            return first
        }

        if let plain = try? decoder.decode(PlainOrderFile.self, from: data) {
            // Entries without a UUID can never match an installed mod, so they are dropped rather
            // than carried along as permanently-missing rows.
            let entries = plain.order.compactMap { entry -> LoadOrderProfile.Entry? in
                let uuid = entry.uuid.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !uuid.isEmpty else { return nil }
                let folder = entry.folder ?? ""
                let name = entry.name ?? (folder.isEmpty ? uuid : folder)
                return LoadOrderProfile.Entry(uuid: uuid, folder: folder, name: name)
            }
            guard !entries.isEmpty else { throw ImportError.noProfiles }
            return LoadOrderProfile(name: profileName(for: url), entries: entries)
        }

        throw ImportError.unrecognized
    }

    enum ImportError: LocalizedError {
        case noProfiles
        case unrecognized

        var errorDescription: String? {
            switch self {
            case .noProfiles:
                return "That file contains no mods."
            case .unrecognized:
                return "That file isn’t a load order this app can read. "
                     + "Expected a profile exported from here, or a list of the form "
                     + "{\"Order\": [{\"UUID\": …, \"Name\": …}]}."
            }
        }
    }

    /// Name a plain order after its file: `loadorder.json` → “loadorder”.
    private static func profileName(for url: URL) -> String {
        var stem = url.deletingPathExtension().lastPathComponent
        if stem.hasSuffix(".bg3profile") { stem.removeLast(".bg3profile".count) }
        return stem.isEmpty ? "Imported order" : stem
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
