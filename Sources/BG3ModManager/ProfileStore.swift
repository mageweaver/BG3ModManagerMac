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

    init(name: String, environmentID: String?, mods: [Mod]) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.environmentID = environmentID
        self.entries = mods.compactMap { mod in
            mod.meta.map { Entry(uuid: $0.uuid, folder: $0.folder, name: $0.name) }
        }
    }
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

    /// Read a shared profile file. Accepts either a single profile or an array (takes the first).
    static func importProfile(from url: URL) throws -> LoadOrderProfile {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let one = try? decoder.decode(LoadOrderProfile.self, from: data) { return one }
        let many = try decoder.decode([LoadOrderProfile].self, from: data)
        guard let first = many.first else {
            throw NSError(domain: "BG3MM", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "That file contains no profiles."])
        }
        return first
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
