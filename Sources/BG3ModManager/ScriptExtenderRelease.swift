import Foundation

/// Install BG3SE-macOS from its **pre-built binary release** — no toolchain, no
/// source checkout, no `cmake`.
///
/// This is the easy path added in 2026-08 once the extender started shipping a
/// tagged release with `libbg3se.dylib` attached. The whole install is:
///
///   1. find the game's `.app` bundle (Steam, native macOS),
///   2. download the latest release zip from GitHub and pull the dylib out,
///   3. copy the dylib into `Contents/MacOS/` (where the binary's weak
///      `@loader_path/libbg3se.dylib` load command finds it on its own),
///   4. strip the quarantine flag so Gatekeeper doesn't refuse the unsigned
///      dylib.
///
/// It coexists with `ScriptExtenderMac` (the build-from-source flow); this is
/// the recommended path for people who just want it working.
///
/// Release: https://github.com/mageweaver/bg3se-macos/releases
enum ScriptExtenderRelease {

    static let owner = "mageweaver"
    static let repo = "bg3se-macos"
    static let releasesPage = URL(string: "https://github.com/mageweaver/bg3se-macos/releases")!

    /// The game build these releases target. Shown in the game's main-menu
    /// corner; the extender fails closed on anything else.
    static let targetGameBuild = "4.1.1.7398727"

    // MARK: State

    /// What we know about the extender installed in the game bundle right now.
    struct State: Equatable {
        /// The resolved `Baldur's Gate 3.app` bundle, if we found one.
        var gameApp: URL?
        /// `Contents/MacOS/libbg3se.dylib`, if it is present.
        var installedDylib: URL?
        var installedBytes: Int64 = 0
        var installedAt: Date?
        /// Still quarantined? Then Gatekeeper will refuse to load it.
        var quarantined = false
        /// "0.47.2" — see `VersionSource` for where it came from; nil when
        /// nothing on disk says.
        var installedVersion: String?
        var versionSource: VersionSource = .none

        var isInstalled: Bool { installedDylib != nil }
        var isReady: Bool { isInstalled && !quarantined }
    }

    /// How `State.installedVersion` was learned.
    enum VersionSource: Equatable {
        /// Read out of the dylib's own header (`LC_ID_DYLIB`); the extender
        /// stamps its version there from the build after v0.47.2 on. Always
        /// describes the file that is actually in the game bundle.
        case dylib
        /// This app installed the release and the file is unchanged since —
        /// same size and modification date as when it was written.
        case installRecord
        /// Nothing to go on: an older release, or a dylib put there by hand.
        case none
    }

    /// One GitHub release and the dylib-bearing asset we can install from it.
    struct Release: Equatable {
        var tag: String
        var name: String
        var assetName: String
        var assetURL: URL
        var assetBytes: Int64
        var pageURL: URL
    }

    // MARK: Finding the game bundle

    /// Filename Steam gives the game executable / bundle.
    private static let appName = "Baldur's Gate 3.app"

    /// Locate the native-macOS `Baldur's Gate 3.app`. Checks every Steam
    /// library (parsed loosely from `libraryfolders.vdf`) plus the default
    /// location, and a couple of non-Steam spots.
    static func discoverGameApp() -> URL? {
        for library in steamLibraries() {
            let candidate = library
                .appendingPathComponent("steamapps/common/Baldurs Gate 3")
                .appendingPathComponent(appName)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        // Non-Steam fallbacks people occasionally use.
        let fm = FileManager.default
        for direct in ["/Applications/Baldur's Gate 3.app",
                       fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Baldur's Gate 3.app").path] {
            if fm.fileExists(atPath: direct) { return URL(fileURLWithPath: direct) }
        }
        return nil
    }

    /// Steam library roots. The default library is always included; extra
    /// libraries are recovered from `libraryfolders.vdf` by pulling out
    /// quoted absolute paths (the VDF schema is unstable across Steam versions,
    /// so this reads the one field that has never moved rather than parsing).
    private static func steamLibraries() -> [URL] {
        let fm = FileManager.default
        let steam = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam")
        var roots = [steam]   // default library lives under the Steam root itself

        let vdf = steam.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: vdf, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard line.contains("\"path\"") else { continue }
                // "path"		"/Volumes/Games/SteamLibrary"
                let parts = line.components(separatedBy: "\"").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if let path = parts.last, path.hasPrefix("/") {
                    roots.append(URL(fileURLWithPath: path))
                }
            }
        }
        // De-dup while preserving order.
        var seen = Set<String>()
        return roots.filter { seen.insert($0.path).inserted }
    }

    /// Where the dylib goes: `<app>/Contents/MacOS/libbg3se.dylib`.
    static func dylibDestination(in gameApp: URL) -> URL {
        gameApp.appendingPathComponent("Contents/MacOS/libbg3se.dylib")
    }

    // MARK: Reading current state

    /// Inspect the game bundle for an already-installed dylib.
    static func inspect(gameApp: URL?) -> State {
        var state = State(gameApp: gameApp)
        guard let gameApp else { return state }

        let dylib = dylibDestination(in: gameApp)
        guard FileManager.default.fileExists(atPath: dylib.path) else { return state }

        state.installedDylib = dylib
        let values = try? dylib.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        state.installedAt = values?.contentModificationDate
        state.installedBytes = Int64(values?.fileSize ?? 0)
        state.quarantined = hasQuarantine(dylib)

        if let stamped = MachOVersion.read(at: dylib) {
            state.installedVersion = stamped
            state.versionSource = .dylib
        } else if let record = InstallRecord.load(),
                  record.matches(bytes: state.installedBytes, modifiedAt: state.installedAt) {
            state.installedVersion = record.version
            state.versionSource = .installRecord
        }
        return state
    }

    // MARK: Versions

    /// Which release this app last installed, and what the file looked like
    /// right after. Lets the tab name the version of a release that predates
    /// the header stamp — as long as the file has not been replaced since.
    struct InstallRecord: Equatable {
        var version: String
        var bytes: Int64
        var modifiedAt: Date?

        private static let key = "macSEInstallRecord"

        func matches(bytes: Int64, modifiedAt: Date?) -> Bool {
            guard bytes == self.bytes, bytes > 0 else { return false }
            switch (modifiedAt, self.modifiedAt) {
            case let (a?, b?): return abs(a.timeIntervalSince(b)) < 1   // HFS+/APFS granularity
            case (nil, nil):   return true
            default:           return false
            }
        }

        static func load(from defaults: UserDefaults = .standard) -> InstallRecord? {
            guard let dict = defaults.dictionary(forKey: key),
                  let version = dict["version"] as? String,
                  let bytes = (dict["bytes"] as? NSNumber)?.int64Value else { return nil }
            let modified = (dict["modifiedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return InstallRecord(version: version, bytes: bytes, modifiedAt: modified)
        }

        func save(to defaults: UserDefaults = .standard) {
            var dict: [String: Any] = ["version": version, "bytes": NSNumber(value: bytes)]
            if let modifiedAt { dict["modifiedAt"] = NSNumber(value: modifiedAt.timeIntervalSince1970) }
            defaults.set(dict, forKey: Self.key)
        }

        static func clear(from defaults: UserDefaults = .standard) {
            defaults.removeObject(forKey: key)
        }
    }

    /// "v0.47.2" → "0.47.2". Release tags carry the `v`; the dylib header and
    /// the install record do not.
    static func version(fromTag tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
    }

    /// Numeric, component-wise comparison ("0.47.10" is newer than "0.47.9";
    /// "0.47" reads as "0.47.0"). Anything that is not a dotted number after
    /// an optional leading `v` compares as unknown → false, so a malformed tag
    /// never nags anyone to "update".
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let a = components(of: candidate), let b = components(of: installed) else { return false }
        let width = max(a.count, b.count)
        let pa = a + Array(repeating: 0, count: width - a.count)
        let pb = b + Array(repeating: 0, count: width - b.count)
        for (x, y) in zip(pa, pb) where x != y { return x > y }
        return false
    }

    private static func components(of version: String) -> [Int]? {
        let parts = self.version(fromTag: version).split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var out: [Int] = []
        for part in parts {
            guard let n = Int(part), n >= 0 else { return nil }
            out.append(n)
        }
        return out
    }

    /// True if the file still carries `com.apple.quarantine`.
    static func hasQuarantine(_ url: URL) -> Bool {
        // xattr exits 0 and prints the attribute name if present.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        proc.arguments = ["-p", "com.apple.quarantine", url.path]
        let out = Pipe(); proc.standardOutput = out; proc.standardError = Pipe()
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    // MARK: The GitHub release

    /// Fetch the latest release and the asset that contains the dylib.
    static func latestRelease() async throws -> Release {
        let api = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("BG3ModManagerMac", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallError.releaseLookup(http.statusCode)
        }

        struct Asset: Decodable { let name: String; let browser_download_url: String; let size: Int64 }
        struct Payload: Decodable { let tag_name: String; let name: String?; let html_url: String; let assets: [Asset] }

        let payload = try JSONDecoder().decode(Payload.self, from: data)

        // Prefer a .zip asset (holds the dylib + INSTALL.txt); accept a bare
        // .dylib asset if a future release attaches one directly.
        let asset = payload.assets.first { $0.name.lowercased().hasSuffix(".zip") }
                 ?? payload.assets.first { $0.name.lowercased().hasSuffix(".dylib") }
        guard let asset, let url = URL(string: asset.browser_download_url) else {
            throw InstallError.noAsset(payload.tag_name)
        }

        return Release(tag: payload.tag_name,
                       name: payload.name ?? payload.tag_name,
                       assetName: asset.name,
                       assetURL: url,
                       assetBytes: asset.size,
                       pageURL: URL(string: payload.html_url) ?? releasesPage)
    }

    // MARK: Install

    enum InstallError: LocalizedError {
        case noGameApp
        case releaseLookup(Int)
        case noAsset(String)
        case download(Int)
        case noDylibInArchive
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .noGameApp:
                return "Couldn't find Baldur's Gate 3.app. Set the game path in Settings, or install through Steam first."
            case .releaseLookup(let code):
                return "Couldn't reach the BG3SE-macOS releases (HTTP \(code)). Check your connection."
            case .noAsset(let tag):
                return "Release \(tag) has no downloadable dylib asset yet."
            case .download(let code):
                return "Download failed (HTTP \(code))."
            case .noDylibInArchive:
                return "The downloaded release didn't contain libbg3se.dylib."
            case .copyFailed(let why):
                return "Couldn't install the dylib into the game: \(why)"
            }
        }
    }

    /// What `installLatest` leaves behind: the bundle state plus the release
    /// it came from, so the caller can show "latest" without a second lookup.
    struct InstallResult {
        var state: State
        var release: Release
    }

    /// Download the latest release and install its dylib into the game bundle,
    /// then clear quarantine. `log` receives human-readable progress lines.
    /// Pass `release` to install one already looked up; nil fetches the latest.
    ///
    /// Re-runnable: an existing dylib is replaced (a `.prev` backup is kept
    /// the first time).
    @discardableResult
    static func installLatest(gameApp: URL,
                              release known: Release? = nil,
                              log: @escaping (String) -> Void) async throws -> InstallResult {
        let release: Release
        if let known { release = known } else { release = try await latestRelease() }
        log("Latest release: \(release.name) (\(release.tag))")
        log("Downloading \(release.assetName)…")

        let (tempFile, resp) = try await URLSession.shared.download(from: release.assetURL)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallError.download(http.statusCode)
        }

        let dylibSource = try extractDylib(from: tempFile,
                                           named: resp.suggestedFilename ?? release.assetName,
                                           log: log)

        let dest = dylibDestination(in: gameApp)
        let fm = FileManager.default

        // Back up any existing dylib the first time we replace one.
        if fm.fileExists(atPath: dest.path) {
            let backup = dest.appendingPathExtension("prev")
            if !fm.fileExists(atPath: backup.path) {
                try? fm.copyItem(at: dest, to: backup)
                log("Backed up the existing dylib to libbg3se.dylib.prev")
            }
            try? fm.removeItem(at: dest)
        }

        do {
            try fm.copyItem(at: dylibSource, to: dest)
        } catch {
            throw InstallError.copyFailed(error.localizedDescription)
        }
        log("Installed \(release.tag) into \(dest.path)")

        // Strip quarantine so Gatekeeper allows the unsigned dylib.
        clearQuarantine(dest, log: log)

        // Remember which release this file is, for dylibs that predate the
        // header stamp. Keyed to the file as written, so a later hand-copied
        // or locally built dylib is not mislabelled with this tag.
        let attrs = try? dest.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        InstallRecord(version: version(fromTag: release.tag),
                      bytes: Int64(attrs?.fileSize ?? 0),
                      modifiedAt: attrs?.contentModificationDate).save()

        let state = inspect(gameApp: gameApp)
        if state.isReady {
            log("")
            log("Done. Launch Baldur's Gate 3 through Steam; it loads the extender on its own.")
            log("Targets game build \(targetGameBuild) — the extender idles on any other build.")
        }
        return InstallResult(state: state, release: release)
    }

    /// Pull `libbg3se.dylib` out of a downloaded file that is either the dylib
    /// itself or a zip containing it. Returns a URL inside a temp dir.
    private static func extractDylib(from tempFile: URL, named suggested: String,
                                     log: (String) -> Void) throws -> URL {
        let fm = FileManager.default
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BG3SE-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        if suggested.lowercased().hasSuffix(".dylib") {
            let dest = work.appendingPathComponent("libbg3se.dylib")
            try fm.moveItem(at: tempFile, to: dest)
            return dest
        }

        // Treat as a zip.
        let zip = work.appendingPathComponent("release.zip")
        try fm.moveItem(at: tempFile, to: zip)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", "-q", zip.path, "-d", work.path]
        try unzip.run(); unzip.waitUntilExit()
        log("Unpacked the release archive.")

        if let e = fm.enumerator(at: work, includingPropertiesForKeys: nil) {
            for case let f as URL in e where f.lastPathComponent == "libbg3se.dylib" {
                return f
            }
        }
        throw InstallError.noDylibInArchive
    }

    /// Remove `com.apple.quarantine` from the installed dylib.
    static func clearQuarantine(_ url: URL, log: (String) -> Void) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        proc.arguments = ["-d", "com.apple.quarantine", url.path]
        proc.standardError = Pipe()
        do {
            try proc.run(); proc.waitUntilExit()
            log("Cleared Gatekeeper quarantine.")
        } catch {
            log("Note: couldn't clear quarantine automatically — run "
                + "`xattr -d com.apple.quarantine \"\(url.path)\"` if the game doesn't load it.")
        }
    }

    /// Remove an installed dylib, restoring the `.prev` backup if present.
    static func uninstall(gameApp: URL, log: (String) -> Void) {
        let fm = FileManager.default
        let dest = dylibDestination(in: gameApp)
        guard fm.fileExists(atPath: dest.path) else { log("Nothing installed."); return }
        try? fm.removeItem(at: dest)
        InstallRecord.clear()
        let backup = dest.appendingPathExtension("prev")
        if fm.fileExists(atPath: backup.path) {
            try? fm.moveItem(at: backup, to: dest)
            log("Removed the extender and restored the previous dylib.")
        } else {
            log("Removed libbg3se.dylib from the game bundle.")
        }
    }
}
