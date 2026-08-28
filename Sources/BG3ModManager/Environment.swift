import Foundation

/// Where Baldur's Gate 3 stores its data on this Mac.
///
/// BG3 has two very different layouts on macOS:
///  - `.nativeMac`   — the native Mac build (Larian / Mac App Store / Steam Mac). Files live in
///                     `~/Documents/Larian Studios/Baldur's Gate 3`.
///  - `.crossOver`   — the *Windows* build running inside a CrossOver (or plain Wine) bottle. Files
///                     live inside the bottle under `drive_c/users/<user>/Documents/...`. Because this
///                     is the Windows build, the Windows Script Extender can actually be installed here.
struct GameEnvironment: Identifiable, Hashable, Codable {
    enum Kind: String, Codable {
        case nativeMac
        case crossOver
        case custom
    }

    var id: String { documentsBase.path }
    var kind: Kind
    /// Display name (e.g. "Native macOS" or the CrossOver bottle name).
    var label: String
    /// `.../Larian Studios/Baldur's Gate 3`
    var documentsBase: URL
    /// The Windows game `bin` folder inside the bottle, if known. Only meaningful for `.crossOver`.
    /// This is where the Script Extender loader (DWrite.dll) is placed.
    var gameBinFolder: URL?
    /// Root of a built BG3SE-macOS checkout, when one is set up. Only meaningful for `.nativeMac`,
    /// where it is what makes Script Extender mods possible at all.
    var macScriptExtenderRoot: URL?

    var modsFolder: URL { documentsBase.appendingPathComponent("Mods", isDirectory: true) }

    /// `.../PlayerProfiles` — one folder per profile, plus the profile index file.
    var playerProfilesFolder: URL {
        documentsBase.appendingPathComponent("PlayerProfiles", isDirectory: true)
    }

    /// Profile names that actually exist on disk. Almost always just "Public", but BG3 supports more
    /// and saves live under whichever one is active.
    var saveProfiles: [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: playerProfilesFolder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map(\.lastPathComponent)
            .sorted { $0 == "Public" ? true : ($1 == "Public" ? false : $0 < $1) }
    }

    /// Where campaign saves live for a profile. Each save is a folder inside this one.
    func savesFolder(profile: String) -> URL {
        playerProfilesFolder
            .appendingPathComponent(profile, isDirectory: true)
            .appendingPathComponent("Savegames", isDirectory: true)
            .appendingPathComponent("Story", isDirectory: true)
    }

    var modSettingsFile: URL {
        documentsBase
            .appendingPathComponent("PlayerProfiles", isDirectory: true)
            .appendingPathComponent("Public", isDirectory: true)
            .appendingPathComponent("modsettings.lsx", isDirectory: false)
    }

    /// Whether Script Extender mods can run in this environment.
    ///
    /// Two different routes get you there. Under CrossOver you are running the Windows build, so the
    /// Windows SE loads via a DWrite.dll proxy. On the native Mac build, BG3SE-macOS provides a
    /// native dylib injected through Steam's launch options — a separate project with a separate
    /// setup, but the same answer for the user: SE mods work.
    var supportsScriptExtender: Bool {
        switch kind {
        case .crossOver: return gameBinFolder != nil
        case .nativeMac: return macScriptExtenderRoot != nil
        case .custom:    return gameBinFolder != nil || macScriptExtenderRoot != nil
        }
    }
}

/// Discovers BG3 installations: the native Mac build and any CrossOver/Wine bottles.
enum EnvironmentLocator {
    private static let fm = FileManager.default
    private static let larianTail = "Larian Studios/Baldur's Gate 3"

    static func discover() -> [GameEnvironment] {
        var found: [GameEnvironment] = []
        if let native = nativeMacEnvironment() { found.append(native) }
        found.append(contentsOf: crossOverEnvironments())
        return found
    }

    // MARK: Native Mac

    static func nativeMacEnvironment() -> GameEnvironment? {
        let home = fm.homeDirectoryForCurrentUser
        let base = home
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(larianTail, isDirectory: true)
        guard fm.fileExists(atPath: base.path) else { return nil }
        return GameEnvironment(kind: .nativeMac, label: "Native macOS", documentsBase: base, gameBinFolder: nil)
    }

    // MARK: CrossOver / Wine bottles

    /// Common locations where CrossOver and Wine keep bottles.
    private static func bottleRoots() -> [URL] {
        let home = fm.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Application Support/CrossOver/Bottles", isDirectory: true),
            home.appendingPathComponent(".wine", isDirectory: true),                 // default wine prefix (parent handled below)
            home.appendingPathComponent("Library/Application Support/com.codeweavers.CrossOver/Bottles", isDirectory: true),
            home.appendingPathComponent("Wine/Bottles", isDirectory: true)
        ]
    }

    static func crossOverEnvironments() -> [GameEnvironment] {
        var results: [GameEnvironment] = []

        for root in bottleRoots() {
            // A bottle root contains one folder per bottle, each with its own drive_c.
            let candidates: [URL]
            if root.lastPathComponent == ".wine" {
                candidates = [root] // the prefix itself is the bottle
            } else {
                candidates = (try? fm.contentsOfDirectory(at: root,
                                                          includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles])) ?? []
            }

            for bottle in candidates {
                let driveC = bottle.appendingPathComponent("drive_c", isDirectory: true)
                guard fm.fileExists(atPath: driveC.path) else { continue }

                if let base = findLarianBase(inDriveC: driveC) {
                    let bin = findGameBin(inDriveC: driveC)
                    results.append(GameEnvironment(
                        kind: .crossOver,
                        label: "CrossOver · \(bottle.lastPathComponent)",
                        documentsBase: base,
                        gameBinFolder: bin
                    ))
                }
            }
        }
        return results
    }

    /// Find the Windows BG3 data base inside a bottle, e.g.
    /// `drive_c/users/<user>/AppData/Local/Larian Studios/Baldur's Gate 3`.
    private static func findLarianBase(inDriveC driveC: URL) -> URL? {
        let usersDir = driveC.appendingPathComponent("users", isDirectory: true)
        let users = (try? fm.contentsOfDirectory(at: usersDir,
                                                 includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles])) ?? []
        // The Windows build stores mods + modsettings.lsx under %LOCALAPPDATA% (AppData/Local) — check
        // that FIRST. A bottle's "Documents" is usually a symlink to the Mac's ~/Documents, so matching
        // it would shadow the real Windows mod folder with the native-Mac one (a confusing duplicate of
        // the native environment) and the actual CrossOver mods would never appear.
        let subpaths = ["AppData/Local", "AppData/Roaming", "Documents", "My Documents", "OneDrive/Documents"]
        for user in users {
            for sub in subpaths {
                let base = user
                    .appendingPathComponent(sub, isDirectory: true)
                    .appendingPathComponent(larianTail, isDirectory: true)
                if fm.fileExists(atPath: base.path) { return base }
            }
        }
        return nil
    }

    /// Find the BG3 game `bin` folder (contains bg3.exe) inside the bottle, across common Steam/GOG paths.
    private static func findGameBin(inDriveC driveC: URL) -> URL? {
        let relativeInstalls = [
            "Program Files (x86)/Steam/steamapps/common/Baldurs Gate 3/bin",
            "Program Files (x86)/GOG Galaxy/Games/Baldurs Gate 3/bin",
            "GOG Games/Baldurs Gate 3/bin",
            "Games/Baldurs Gate 3/bin"
        ]
        for rel in relativeInstalls {
            let candidate = driveC.appendingPathComponent(rel, isDirectory: true)
            if fm.fileExists(atPath: candidate.appendingPathComponent("bg3.exe").path)
                || fm.fileExists(atPath: candidate.appendingPathComponent("bg3_dx11.exe").path)
                || fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Build a `.custom` environment from a user-chosen "Baldur's Gate 3" documents folder.
    static func custom(at base: URL, gameBin: URL? = nil) -> GameEnvironment {
        GameEnvironment(kind: .custom, label: "Custom · \(base.lastPathComponent)",
                        documentsBase: base, gameBinFolder: gameBin)
    }
}
