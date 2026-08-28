import Foundation
import CryptoKit

/// What the manager knows about where an installed pak came from, and whether something newer
/// exists upstream.
///
/// A `.pak` on disk carries no provenance of its own — nothing in the file says "this is Nexus mod
/// 1234". So the link to an upstream page is either recorded at install time (exact), recovered by
/// hashing the pak and asking Nexus (exact when it hits), or made by hand.
struct InstallRecord: Codable, Hashable {
    /// Where the pak came from. `nil` until the mod is linked.
    var source: RemoteMod.Source?
    var modID: Int?
    /// The upstream file this pak was installed from, when known.
    var fileID: Int?
    var version: String?

    /// Set when this app installed the pak. Mods that were already on disk have no exact date and
    /// fall back to the file's creation date — see `Mod.installedAt`.
    var installedAt: Date?

    /// md5 of the pak, cached so the backfill hashes each file only once.
    var md5: String?
    var link: LinkState = .unlinked

    // Latest known upstream state, filled in by an update check.
    var latestVersion: String?
    var latestFileID: Int?
    var latestFileName: String?
    var lastCheckedAt: Date?

    /// How the upstream link was established — or why there isn't one.
    enum LinkState: String, Codable {
        case unlinked        // never looked
        case installedHere   // downloaded through this app, so provenance is exact
        case matchedByHash   // the pak's md5 identified it upstream
        case manual          // the user linked it
        case noHashMatch     // hashed, upstream didn't recognise it — don't hash it again
    }

    var isLinked: Bool { source != nil && modID != nil }

    /// True when the newest upstream file differs from the one on disk.
    ///
    /// File id is the reliable comparison — Nexus version strings are free text and authors reuse
    /// them. Version is the fallback for links made by hand, where no file id was ever recorded.
    var updateAvailable: Bool {
        guard isLinked else { return false }
        if let latestFileID, let fileID { return latestFileID != fileID }
        guard let latestVersion, let version else { return false }
        return latestVersion != version
    }

    /// A mod that has been looked at and simply isn't recognised upstream — worth showing
    /// differently from one nobody has checked yet.
    var isUnrecognised: Bool { link == .noHashMatch && !isLinked }
}

/// Persists install records to `~/Library/Application Support/BG3ModManagerMac/installs.json`,
/// keyed by each mod's `noteKey` — the same key notes use, so a record survives refreshes and
/// follows the mod between installs that share a UUID.
enum InstallRecordStore {
    private static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BG3ModManagerMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("installs.json")
    }

    static func load() -> [String: InstallRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: InstallRecord].self, from: data)) ?? [:]
    }

    static func save(_ records: [String: InstallRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(records) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: File hashing

enum PakHash {
    /// Streaming md5 of a file. Paks run to hundreds of megabytes, so this reads in 1 MB chunks
    /// rather than loading the whole file. Returns nil if the file can't be read.
    static func md5(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = Insecure.MD5()
        while true {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1 << 20) } catch { return nil }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
