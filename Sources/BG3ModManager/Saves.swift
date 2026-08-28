import Foundation

/// One BG3 campaign save.
///
/// A save is a *folder*, not a file: `Savegames/Story/<campaignUUID>__<Label>/` holding the `.lsv`
/// itself and a `.WebP` screenshot. The folder name is the identity — it is what BG3 matches on, and
/// what makes the same save recognisable across two installs.
struct SaveGame: Identifiable, Hashable {
    var id: String { folderURL.path }
    var folderURL: URL
    var profile: String
    /// The `<campaignUUID>` half of the folder name — saves of one playthrough share it.
    var campaignID: String
    /// The `<Label>` half: "HonourMode", "AutoSave_3", "Ravaged Beach - 0h 08m".
    var label: String
    var saveFile: URL?
    var screenshot: URL?
    var modifiedAt: Date?
    var bytes: Int64

    /// Stable key for matching the same save in another install.
    var key: String { folderURL.lastPathComponent.lowercased() }

    var displayName: String { label.isEmpty ? folderURL.lastPathComponent : label }

    /// Autosaves and quicksaves are the bulk of a save folder and the usual thing to clear out.
    var isAutoSave: Bool {
        let l = label.lowercased()
        return l.hasPrefix("autosave") || l.hasPrefix("quicksave")
    }
    var isHonourMode: Bool { label.lowercased().contains("honourmode") }

    /// The playthrough this save belongs to, which is how BG3's own load screen groups saves.
    ///
    /// The folder prefix is `<CharacterName>-<digits>`, and the digits are unique per save — so the
    /// prefix alone is not a campaign key, but the name in front of it is. Honour Mode saves carry a
    /// UUID instead of a name and are grouped under their label.
    var characterName: String {
        if let match = campaignID.range(of: "-[0-9]{6,}$", options: .regularExpression) {
            let name = String(campaignID[..<match.lowerBound])
            if !name.isEmpty { return name }
        }
        if campaignID.range(of: "^[0-9a-fA-F-]{30,}$", options: .regularExpression) != nil {
            return label.isEmpty ? "Other" : label
        }
        return campaignID.isEmpty ? "Other" : campaignID
    }
}

/// Disk operations on save folders: list them, copy them between installs, stage them for transfer
/// elsewhere, and remove them.
struct SaveRepository {
    let environment: GameEnvironment

    /// Every save across every profile, newest first.
    func loadSaves() -> [SaveGame] {
        var saves: [SaveGame] = []
        for profile in environment.saveProfiles {
            let story = environment.savesFolder(profile: profile)
            let folders = (try? FileManager.default.contentsOfDirectory(
                at: story,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []

            for folder in folders {
                guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                else { continue }
                saves.append(read(folder, profile: profile))
            }
        }
        return saves.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    private func read(_ folder: URL, profile: String) -> SaveGame {
        let name = folder.lastPathComponent
        // "<uuid>__<label>". The separator is a double underscore; labels themselves can contain
        // single underscores ("AutoSave_3"), so split on the first "__" only.
        let campaign: String, label: String
        if let sep = name.range(of: "__") {
            campaign = String(name[..<sep.lowerBound])
            label = String(name[sep.upperBound...])
        } else {
            campaign = ""
            label = name
        }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []

        var bytes: Int64 = 0
        var newest: Date?
        var lsv: URL?
        var shot: URL?
        for file in contents {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            bytes += Int64(values?.fileSize ?? 0)
            if let date = values?.contentModificationDate, date > (newest ?? .distantPast) { newest = date }
            switch file.pathExtension.lowercased() {
            case "lsv":           lsv = file
            case "webp", "png":   shot = file
            default:              break
            }
        }

        return SaveGame(folderURL: folder, profile: profile, campaignID: campaign, label: label,
                        saveFile: lsv, screenshot: shot, modifiedAt: newest, bytes: bytes)
    }

    // MARK: Moving saves around

    enum SaveError: LocalizedError {
        case noProfile
        case alreadyExists(String)
        var errorDescription: String? {
            switch self {
            case .noProfile: return "That install has no player profile to copy saves into."
            case .alreadyExists(let n): return "“\(n)” already exists there."
            }
        }
    }

    /// Copy a save into this install, under the given profile (defaults to the first one).
    ///
    /// The folder name is preserved exactly — BG3 parses the campaign UUID out of it, so renaming
    /// would orphan the save from its playthrough.
    @discardableResult
    func receive(_ save: SaveGame, profile: String? = nil, overwrite: Bool) throws -> URL {
        let fm = FileManager.default
        guard let target = profile ?? environment.saveProfiles.first else { throw SaveError.noProfile }
        let story = environment.savesFolder(profile: target)
        try fm.createDirectory(at: story, withIntermediateDirectories: true)

        let dest = story.appendingPathComponent(save.folderURL.lastPathComponent, isDirectory: true)
        if fm.fileExists(atPath: dest.path) {
            guard overwrite else { throw SaveError.alreadyExists(save.displayName) }
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: save.folderURL, to: dest)
        return dest
    }

    /// Copy saves into a staging folder for moving to another machine.
    ///
    /// Folders are copied verbatim so the result can be dropped straight into another install's
    /// `Savegames/Story`. A manifest is written alongside them, because a directory of
    /// `<uuid>__AutoSave_3` folders is unreadable once it has left the machine that made it.
    @discardableResult
    func export(_ saves: [SaveGame], to directory: URL, overwrite: Bool) throws -> (copied: Int, skipped: [String], bytes: Int64) {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        var copied = 0
        var skipped: [String] = []
        var bytes: Int64 = 0

        for save in saves {
            let dest = directory.appendingPathComponent(save.folderURL.lastPathComponent, isDirectory: true)
            if fm.fileExists(atPath: dest.path) {
                guard overwrite else { skipped.append(save.displayName); continue }
                try? fm.removeItem(at: dest)
            }
            do {
                try fm.copyItem(at: save.folderURL, to: dest)
                copied += 1
                bytes += save.bytes
            } catch {
                skipped.append(save.displayName)
            }
        }

        try? writeManifest(saves, to: directory)
        return (copied, skipped, bytes)
    }

    private func writeManifest(_ saves: [SaveGame], to directory: URL) throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var lines = [
            "BG3 save export",
            "Source install : \(environment.label)",
            "Source folder  : \(environment.documentsBase.path)",
            "Exported       : \(stamp)",
            "Saves          : \(saves.count)",
            "",
            "Drop these folders into PlayerProfiles/<Profile>/Savegames/Story/ on the target machine.",
            "Keep the folder names exactly as they are — BG3 reads the campaign UUID from them.",
            "",
        ]
        for save in saves.sorted(by: { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }) {
            let when = save.modifiedAt.map { formatter.string(from: $0) } ?? "unknown date"
            let size = ByteCountFormatter.string(fromByteCount: save.bytes, countStyle: .file)
            lines.append("\(save.folderURL.lastPathComponent)")
            lines.append("    \(save.displayName) · \(when) · \(size)")
        }
        try lines.joined(separator: "\n").write(to: directory.appendingPathComponent("saves-manifest.txt"),
                                                atomically: true, encoding: .utf8)
    }

    /// Move a save to the Trash. Falls back to a permanent delete only if the volume refuses,
    /// and reports which happened — a save is unrepeatable progress, so recoverability matters.
    func remove(_ save: SaveGame) -> (trashed: Bool, removed: Bool) {
        let fm = FileManager.default
        if (try? fm.trashItem(at: save.folderURL, resultingItemURL: nil)) != nil { return (true, true) }
        if (try? fm.removeItem(at: save.folderURL)) != nil { return (false, true) }
        return (false, false)
    }
}
