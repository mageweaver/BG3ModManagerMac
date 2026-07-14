import Foundation

/// A single portable snapshot of the user's setup: the current load order, every per-mod note, and
/// all saved profiles. One file you can stash or move to another machine, then import to restore.
/// It captures *configuration*, not the (potentially many-GB) `.pak` files themselves.
struct AppBackup: Codable {
    static let currentSchema = 1
    var schema: Int
    var createdAt: Date
    var appVersion: String
    var environmentLabel: String?
    /// The active load order at backup time (enabled mods, in order).
    var loadOrder: LoadOrderProfile
    var notes: [String: String]
    var profiles: [LoadOrderProfile]
}

/// Reads/writes `AppBackup`s. One-click backups land in
/// `~/Library/Application Support/BG3ModManagerMac/Backups/`; import accepts a backup from anywhere.
enum BackupStore {
    static var backupsDir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BG3ModManagerMac/Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static let fileSuffix = ".bg3backup.json"

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Write a backup into the Backups folder with a timestamped name; returns its URL.
    @discardableResult
    static func write(_ backup: AppBackup) throws -> URL {
        let url = backupsDir.appendingPathComponent("BG3-backup-\(filenameStamp(backup.createdAt))\(fileSuffix)")
        try encoder().encode(backup).write(to: url, options: .atomic)
        return url
    }

    /// Write a backup to a user-chosen location.
    static func export(_ backup: AppBackup, to url: URL) throws {
        try encoder().encode(backup).write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> AppBackup {
        try decoder().decode(AppBackup.self, from: Data(contentsOf: url))
    }

    /// Backups in the Backups folder, newest first.
    static func recent(limit: Int = 8) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: backupsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { $0.lastPathComponent.hasSuffix(fileSuffix) }
            .sorted { modDate($0) > modDate($1) }
            .prefix(limit)
            .map { $0 }
    }

    private static func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func filenameStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
