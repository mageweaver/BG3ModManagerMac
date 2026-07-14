import Foundation

/// Persists free-form per-mod notes to
/// `~/Library/Application Support/BG3ModManagerMac/notes.json`.
///
/// Keyed by each mod's stable `noteKey` (its UUID when known, else the `.pak` filename), so a note
/// follows the mod across refreshes and even across installs (native ↔ CrossOver) that share a UUID.
enum NotesStore {
    private static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BG3ModManagerMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("notes.json")
    }

    static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    static func save(_ notes: [String: String]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(notes) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
