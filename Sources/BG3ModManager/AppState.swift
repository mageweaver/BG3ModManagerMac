import Foundation
import SwiftUI
import CryptoKit
import AppKit

/// The single source of truth the UI binds to. Owns the active environment, the mod list, the load
/// order, remote browsing, and all the actions that mutate disk.
@MainActor
final class AppState: ObservableObject {
    // Discovered installs + the one we're managing.
    @Published var environments: [GameEnvironment] = []
    @Published var activeEnvironment: GameEnvironment? { didSet { refresh() } }

    // Local mods.
    @Published var mods: [Mod] = []
    @Published var statusMessage: String = ""
    @Published var isBusy = false
    /// True while the Mods folder is being rescanned. Until it clears, `mods` is stale (and right
    /// after launch or an install switch, empty) — anything that snapshots the load order has to wait.
    @Published private(set) var isScanningMods = false

    // Save games.
    @Published var saves: [SaveGame] = []
    @Published var isLoadingSaves = false
    /// Folder chosen for staging exports, remembered between runs.
    @AppStorage("saveExportPath") var saveExportPath = ""

    // Copying mods between installs.
    @Published var syncSource: GameEnvironment?
    @Published var syncCandidates: [Mod] = []
    @Published var isScanningSync = false

    // Remote browsing.
    @Published var remoteResults: [RemoteMod] = []
    @Published var remoteSource: RemoteMod.Source = .modio

    // Conflict detection.
    @Published var conflictReport: ConflictDetector.Report?
    @Published var isScanningConflicts = false

    // Saved load-order profiles.
    @Published var profiles: [LoadOrderProfile] = []

    // Free-form per-mod notes (persisted), keyed by Mod.noteKey.
    @Published var notes: [String: String] = [:]

    // Where each installed pak came from and what the newest upstream version is, keyed by Mod.noteKey.
    @Published var installRecords: [String: InstallRecord] = [:]
    @Published var isCheckingUpdates = false
    /// Provenance for paks installed this session, keyed by destination filename. The mod list is
    /// rebuilt asynchronously, so the record can only be filed under the mod's real noteKey once the
    /// following refresh has parsed its meta.
    private var pendingProvenance: [String: InstallRecord] = [:]

    // BG3SE-macOS install progress.
    @Published var isInstallingScriptExtender = false

    // Mac shader-compatibility (Windows-only .bshd detection / fixing).
    @Published var shaderScanResults: [ShaderCompatFixer.ScanResult] = []
    @Published var isScanningShaders = false
    @Published var shaderScanProgress: String = ""
    @Published var shaderScanRan = false
    /// Pak paths fixed this session or found backed up on disk.
    @Published var fixedShaderPaks: Set<String> = []
    @Published var scriptExtenderLog: [String] = []

    /// State of the native-macOS Script Extender, if a checkout can be found. Drives whether the
    /// native install counts as SE-capable at all.
    @Published var macScriptExtender: ScriptExtenderMac.Installation?

    /// State of a BINARY-RELEASE Script Extender install (the one-click path):
    /// the dylib copied straight into the game bundle, no build required.
    @Published var macSERelease: ScriptExtenderRelease.State?
    @Published var isDownloadingSE = false

    // Dependency / compatibility health of the current load order (recomputed on every refresh).
    @Published var healthReport = HealthChecker.Report(issues: [], checkedCount: 0)

    // Settings (persisted).
    @AppStorage("nexusAPIKey") var nexusAPIKey = ""
    @AppStorage("modioAPIKey") var modioAPIKey = ""
    @AppStorage("customDocumentsPath") private var customDocumentsPath = ""
    @AppStorage("customGameBinPath") private var customGameBinPath = ""
    /// Where the BG3SE-macOS checkout lives, when it isn't in one of the usual places.
    @AppStorage("bg3seMacPath") var bg3seMacPath = ""
    /// Point size for mod description text — Browse summaries, and the author/note/provenance lines
    /// under each mod. Stored rather than derived from a Dynamic Type style because the whole point
    /// is to override what the system considers readable.
    @AppStorage("descriptionTextSize") var descriptionTextSize: Double = AppState.defaultDescriptionTextSize

    static let defaultDescriptionTextSize: Double = 11
    static let descriptionTextSizeRange: ClosedRange<Double> = 9...22

    /// Font for mod description text. Read by every row, so it stays in one place.
    var descriptionFont: Font { .system(size: descriptionTextSize) }
    /// Slightly smaller companion for the densest secondary lines, floored so it never disappears.
    var detailFont: Font { .system(size: max(9, descriptionTextSize - 1)) }
    /// Load-order numbers. Monospaced digits so the column stays aligned down a list of hundreds.
    var positionFont: Font { .system(size: descriptionTextSize).monospacedDigit() }
    /// Width the number column needs at the current size, so three- and four-digit positions
    /// don't get clipped as the text grows.
    var positionColumnWidth: CGFloat { max(30, descriptionTextSize * 2.6) }

    private var repo: ModRepository? {
        activeEnvironment.map { ModRepository(environment: $0) }
    }

    // MARK: Discovery / refresh

    func bootstrap() {
        profiles = ProfileStore.load()
        notes = NotesStore.load()
        installRecords = InstallRecordStore.load()
        var envs = EnvironmentLocator.discover()
        if !customDocumentsPath.isEmpty {
            let base = URL(fileURLWithPath: customDocumentsPath)
            let bin = customGameBinPath.isEmpty ? nil : URL(fileURLWithPath: customGameBinPath)
            envs.append(EnvironmentLocator.custom(at: base, gameBin: bin))
        }
        // Detect the native Script Extender before publishing the environments: whether an install
        // is SE-capable is baked into GameEnvironment, and the mod list is classified against it.
        macScriptExtender = ScriptExtenderMac.discover(configuredPath: bg3seMacPath)
        macSERelease = ScriptExtenderRelease.inspect(gameApp: ScriptExtenderRelease.discoverGameApp())
        if let root = macScriptExtender?.root, macScriptExtender?.isBuilt == true {
            for index in envs.indices where envs[index].kind == .nativeMac {
                envs[index].macScriptExtenderRoot = root
            }
        }

        environments = envs
        activeEnvironment = envs.first
        if envs.isEmpty {
            statusMessage = "No BG3 install found. Add a folder in Settings."
        }
    }

    /// Bumped on every refresh so a superseded background scan can't clobber a newer one.
    private var refreshGeneration = 0

    func refresh() {
        conflictReport = nil   // load order changed → previous scan is stale
        guard let repo else { mods = []; isScanningMods = false; return }
        // Scanning the Mods folder means memory-mapping and parsing every .pak (potentially thousands
        // of files / many GB). That must never run on the main actor or the window can't even paint —
        // so do the disk work in a detached task and publish the result back on the main actor.
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isBusy = true
        isScanningMods = true
        statusMessage = "Scanning mods in \(activeEnvironment?.label ?? "")…"
        Task { [repo] in
            let loaded = await Task.detached { repo.loadMods() }.value
            guard generation == self.refreshGeneration else { return } // a newer refresh superseded us
            self.mods = loaded
            self.adoptPendingProvenance(into: loaded)
            self.healthReport = HealthChecker.check(enabled: loaded.filter { $0.isEnabled }, all: loaded)
            let enabled = loaded.filter { $0.isEnabled }.count
            self.statusMessage = "\(loaded.count) mod\(loaded.count == 1 ? "" : "s") · \(enabled) enabled · \(self.activeEnvironment?.label ?? "")"
            self.isBusy = false
            self.isScanningMods = false
        }
    }

    /// Point the app at a BG3SE-macOS checkout by hand, then re-evaluate what that enables.
    func setScriptExtenderMacPath(_ url: URL?) {
        bg3seMacPath = url?.path ?? ""
        let selected = activeEnvironment?.id
        bootstrap()
        if let selected, let match = environments.first(where: { $0.id == selected }) {
            activeEnvironment = match
        }
        if let install = macScriptExtender {
            statusMessage = install.isBuilt
                ? "Found BG3SE-macOS at \(install.root.lastPathComponent)\(install.wiredIntoSteam ? " — set up and wired into Steam." : " — built, but Steam launch options aren't set yet.")"
                : "Found BG3SE-macOS at \(install.root.lastPathComponent), but it hasn't been built yet."
        } else {
            statusMessage = "No BG3SE-macOS checkout found there."
        }
    }

    /// Default place to put a fresh checkout when the user hasn't chosen one.
    var defaultScriptExtenderRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("bg3se-macos")
    }

    /// Clone and build BG3SE-macOS. Re-runnable: an existing checkout is updated and rebuilt.
    func installScriptExtenderMac(into root: URL) async {
        isInstallingScriptExtender = true
        scriptExtenderLog = []
        defer { isInstallingScriptExtender = false }

        do {
            let install = try await ScriptExtenderInstaller.install(into: root) { [weak self] line in
                guard let self else { return }
                self.scriptExtenderLog.append(line)
                // The log can run to thousands of lines during a build; keep the tail.
                if self.scriptExtenderLog.count > 400 { self.scriptExtenderLog.removeFirst(100) }
            }
            bg3seMacPath = install.root.path
            refreshScriptExtenderMac()
            scriptExtenderLog.append("")
            scriptExtenderLog.append("Done. \(install.wiredIntoSteam ? "Steam is already launching through it." : "Next: set the Steam launch options.")")
            statusMessage = "BG3SE-macOS built at \(install.root.path)."
        } catch {
            scriptExtenderLog.append("")
            scriptExtenderLog.append("Failed: \(error.localizedDescription)")
            statusMessage = "Script Extender install failed: \(error.localizedDescription)"
        }
    }

    /// Write BG3's launch options into Steam's config so the game starts through the launcher.
    func wireScriptExtenderIntoSteam() {
        guard let options = macScriptExtender?.launchOptions else {
            statusMessage = "Build BG3SE-macOS first — there's no launcher to point Steam at."
            return
        }
        do {
            let count = try SteamLaunchOptions.set(options)
            refreshScriptExtenderMac()
            statusMessage = "Set BG3's Steam launch options in \(count) account\(count == 1 ? "" : "s"). Start Steam and launch the game."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Re-read the binary-release Script Extender state (dylib present in the
    /// game bundle? quarantined?).
    func refreshSERelease() {
        macSERelease = ScriptExtenderRelease.inspect(gameApp: ScriptExtenderRelease.discoverGameApp())
    }

    /// One-click: download the latest release dylib and install it into the
    /// game bundle, clearing quarantine. No toolchain, no source checkout.
    func installSEFromRelease() async {
        guard let gameApp = ScriptExtenderRelease.discoverGameApp() else {
            statusMessage = ScriptExtenderRelease.InstallError.noGameApp.localizedDescription
            return
        }
        isDownloadingSE = true
        scriptExtenderLog = []
        defer { isDownloadingSE = false }
        do {
            let state = try await ScriptExtenderRelease.installLatest(gameApp: gameApp) { [weak self] line in
                self?.scriptExtenderLog.append(line)
            }
            macSERelease = state
            statusMessage = state.isReady
                ? "Script Extender installed. Launch Baldur's Gate 3 through Steam."
                : "Downloaded, but something's off — see the log."
        } catch {
            scriptExtenderLog.append("")
            scriptExtenderLog.append("Failed: \(error.localizedDescription)")
            statusMessage = error.localizedDescription
        }
    }

    /// Remove a binary-release Script Extender install.
    func uninstallSERelease() {
        guard let gameApp = ScriptExtenderRelease.discoverGameApp() else { return }
        scriptExtenderLog = []
        ScriptExtenderRelease.uninstall(gameApp: gameApp) { [weak self] in self?.scriptExtenderLog.append($0) }
        refreshSERelease()
        statusMessage = "Removed the Script Extender from the game bundle."
    }

    /// Re-read the Script Extender state — after a build, or after pasting the Steam launch options.
    func refreshScriptExtenderMac() {
        let wasCapable = activeEnvironment?.supportsScriptExtender ?? false
        macScriptExtender = ScriptExtenderMac.discover(configuredPath: bg3seMacPath)
        let selected = activeEnvironment?.id
        bootstrap()
        if let selected, let match = environments.first(where: { $0.id == selected }) {
            activeEnvironment = match
        }
        let isCapable = activeEnvironment?.supportsScriptExtender ?? false
        if isCapable && !wasCapable {
            statusMessage = "Script Extender is now available here — mods that need it are no longer flagged."
        } else if let install = macScriptExtender {
            statusMessage = install.isReady
                ? "BG3SE-macOS is built and wired into Steam."
                : (install.isBuilt ? "BG3SE-macOS is built, but Steam launch options aren't set yet."
                                   : "BG3SE-macOS is present but not built yet.")
        } else {
            statusMessage = "No BG3SE-macOS checkout found."
        }
    }

    func setCustomPaths(documents: URL, gameBin: URL?) {
        customDocumentsPath = documents.path
        customGameBinPath = gameBin?.path ?? ""
        bootstrap()
        activeEnvironment = environments.last
    }

    // MARK: Local mod actions

    var enabledMods: [Mod] { mods.filter { $0.isEnabled } }
    var disabledMods: [Mod] { mods.filter { !$0.isEnabled } }

    // MARK: Per-mod notes

    func note(for mod: Mod) -> String { notes[mod.noteKey] ?? "" }
    func hasNote(_ mod: Mod) -> Bool { !(notes[mod.noteKey] ?? "").isEmpty }

    /// Set (or, when blank, clear) the note for a mod and persist immediately.
    func setNote(_ text: String, for mod: Mod) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { notes.removeValue(forKey: mod.noteKey) }
        else { notes[mod.noteKey] = trimmed }
        NotesStore.save(notes)
    }

    func toggle(_ mod: Mod, on: Bool) {
        guard let idx = mods.firstIndex(of: mod) else { return }
        mods[idx].isEnabled = on
        applyOrder()
    }

    /// Move an enabled mod within the load order.
    func moveEnabled(from offsets: IndexSet, to destination: Int) {
        var enabled = enabledMods
        enabled.move(fromOffsets: offsets, toOffset: destination)
        // Rebuild `mods` keeping disabled ones, with new order applied.
        let disabled = disabledMods
        mods = enabled + disabled
        applyOrder()
    }

    /// 1-based load-order positions, keyed by mod id — what the numbers in the list show.
    /// Built once per change rather than searched per row, which would be quadratic at 751 mods.
    var loadOrderPositions: [String: Int] {
        Dictionary(enabledMods.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { a, _ in a })
    }

    /// Move a mod so it sits immediately before whatever currently occupies `position`.
    ///
    /// Anchored to the *mod* at that position, not to the index, because the two differ when moving
    /// downward: taking #1 and asking for "before #3" should leave it above the mod that was third,
    /// which is index 1 after the removal shifts everything up. Resolving the anchor first makes the
    /// result match what the number meant when you read it.
    ///
    /// A position past the end moves the mod to the bottom.
    func moveMod(_ mod: Mod, before position: Int) {
        var enabled = enabledMods
        guard let from = enabled.firstIndex(where: { $0.id == mod.id }) else { return }

        let anchor: Mod? = (position >= 1 && position <= enabled.count) ? enabled[position - 1] : nil
        guard anchor?.id != mod.id else { return }        // already there

        let moving = enabled.remove(at: from)
        if let anchor, let target = enabled.firstIndex(where: { $0.id == anchor.id }) {
            enabled.insert(moving, at: target)
        } else {
            enabled.append(moving)                        // past the end, or no anchor
        }

        mods = enabled + disabledMods
        applyOrder()

        let landed = enabled.firstIndex(where: { $0.id == mod.id }).map { $0 + 1 } ?? position
        statusMessage = "Moved “\(mod.displayName)” to position \(landed)."
    }

    private func applyOrder() {
        guard let repo else { return }
        do {
            try repo.applyLoadOrder(enabledMods)
            refresh()
        } catch {
            statusMessage = "Couldn't save load order: \(error.localizedDescription)"
        }
    }

    func deleteMod(_ mod: Mod) {
        guard let repo else { return }
        do {
            try repo.deletePak(mod.fileURL)
            // Split parts are useless on their own and invisible in the list, so they'd otherwise
            // be left behind as orphaned gigabytes.
            for part in mod.parts { try? repo.deletePak(part) }
            refresh()
        } catch {
            statusMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    /// Add a mod the user downloaded themselves — either a bare `.pak` or the `.zip` it arrived in.
    ///
    /// A zip routinely holds more than one pak (a main file plus optional patches) and often buries
    /// them a folder or two deep, so every pak in the tree is considered. Split parts are not
    /// installed on their own: `install` copies them alongside the archive they belong to, and
    /// installing them separately would report a headerless fragment as if it were a mod.
    func addLocalFile(_ url: URL) {
        guard let repo else { statusMessage = "Pick a BG3 install first."; return }
        do {
            let extracted = try Downloader.paks(inArchiveAt: url)
            defer { if let work = extracted.workDir { try? FileManager.default.removeItem(at: work) } }

            guard !extracted.paks.isEmpty else {
                statusMessage = "No .pak file inside \(url.lastPathComponent)."
                return
            }

            let archives = extracted.paks.filter { PakReader.isArchive($0) }
            // A zip containing only a split part is still worth installing — the user may be adding
            // the second half of a mod whose first half is already in place.
            let toInstall = archives.isEmpty ? extracted.paks : archives

            var installed: [String] = []
            var failed: [String] = []
            for pak in toInstall {
                do {
                    let dest = try repo.install(pakAt: pak)
                    installed.append(dest.lastPathComponent)
                } catch {
                    failed.append(pak.lastPathComponent)
                }
            }

            let carried = extracted.paks.count - toInstall.count
            var message = installed.isEmpty
                ? "Couldn't install anything from \(url.lastPathComponent)"
                : "Installed \(installed.count) pak\(installed.count == 1 ? "" : "s") from \(url.lastPathComponent): \(installed.joined(separator: ", "))"
            if carried > 0 { message += " · \(carried) split file\(carried == 1 ? "" : "s") copied with it" }
            if !failed.isEmpty { message += " · \(failed.count) failed" }
            statusMessage = message + "."
            refresh()
        } catch {
            statusMessage = "Couldn't add \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func installLocalPak(_ url: URL, provenance: InstallRecord? = nil) {
        guard let repo else { return }
        do {
            let dest = try repo.install(pakAt: url)
            if let provenance { pendingProvenance[dest.lastPathComponent] = provenance }
            statusMessage = "Installed \(url.lastPathComponent)."
            refresh()
        } catch {
            statusMessage = "Install failed: \(error.localizedDescription)"
        }
    }

    // MARK: Remote browse / download

    func browse(_ source: RemoteMod.Source, query: String) async {
        remoteSource = source
        isBusy = true; defer { isBusy = false }
        do {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            switch source {
            case .nexus:
                // Empty query → trending feed; otherwise full-catalog search via the Nexus search service.
                let nexus = NexusClient(apiKey: nexusAPIKey)
                remoteResults = trimmed.isEmpty ? try await nexus.browse(.trending)
                                                : try await nexus.search(trimmed)
            case .modio:
                remoteResults = try await ModIOClient(apiKey: modioAPIKey).search(trimmed)
            }
            let scope = trimmed.isEmpty ? (source == .nexus ? "trending" : "popular") : "“\(trimmed)”"
            statusMessage = "\(remoteResults.count) result\(remoteResults.count == 1 ? "" : "s") for \(scope) from \(source.rawValue)."
        } catch {
            statusMessage = error.localizedDescription
            remoteResults = []
        }
    }

    func download(_ remote: RemoteMod) async {
        guard repo != nil else { statusMessage = "Pick a BG3 install first."; return }
        isBusy = true; defer { isBusy = false }
        do {
            let url: URL
            // Provenance is only knowable here, at the moment of download — a .pak on disk says
            // nothing about where it came from. Recording it now is what makes update checks possible
            // later without having to hash and guess.
            var provenance = InstallRecord()
            provenance.source = remote.source
            provenance.modID = remote.modID
            provenance.link = .installedHere
            provenance.installedAt = Date()
            provenance.lastCheckedAt = Date()

            switch remote.source {
            case .modio:
                let file = try await ModIOClient(apiKey: modioAPIKey).primaryFile(modID: remote.modID)
                url = file.url
                provenance.fileID = file.fileID
                provenance.version = file.version
                provenance.latestFileID = file.fileID
                provenance.latestVersion = file.version
                provenance.latestFileName = file.filename
            case .nexus:
                let nexus = NexusClient(apiKey: nexusAPIKey)
                let files = try await nexus.files(modID: remote.modID)
                guard let main = files.first(where: { $0.isMain }) ?? files.first else {
                    statusMessage = "No file found for \(remote.name)."; return
                }
                provenance.fileID = main.file_id
                provenance.version = main.version
                provenance.latestFileID = main.file_id
                provenance.latestVersion = main.version
                provenance.latestFileName = main.name
                url = try await nexus.downloadLink(modID: remote.modID, fileID: main.file_id)
            }
            let paks = try await Downloader.fetchPaks(from: url, suggestedName: remote.name)
            for pak in paks { installLocalPak(pak, provenance: provenance) }
            statusMessage = "Downloaded \(remote.name) (\(paks.count) pak\(paks.count == 1 ? "" : "s"))."
        } catch {
            statusMessage = "Download failed: \(error.localizedDescription)"
        }
    }



    // MARK: Copying mods between installs

    /// The other BG3 installs on this Mac — the possible sources to copy missing mods from.
    var otherEnvironments: [GameEnvironment] {
        environments.filter { $0.id != activeEnvironment?.id }
    }

    /// UUIDs the last applied profile wanted but couldn't find installed here. Kept so the sync sheet
    /// can offer exactly the mods that order was missing.
    @Published private(set) var lastMissingUUIDs: Set<String> = []

    /// Scan another install and list the mods it has that this one doesn't.
    ///
    /// Matching is by module UUID, not filename: the same mod can sit under different filenames in
    /// the two installs, and copying it twice would put two paks with one UUID in the Mods folder.
    func loadSyncCandidates(from env: GameEnvironment) async {
        isScanningSync = true
        defer { isScanningSync = false }
        syncSource = env
        statusMessage = "Scanning \(env.label)…"

        let sourceMods = await Task.detached { ModRepository(environment: env).loadMods() }.value
        let installedUUIDs = Set(mods.compactMap { $0.meta?.uuid.lowercased() })
        let installedFiles = Set(mods.map { $0.fileURL.lastPathComponent.lowercased() })

        syncCandidates = sourceMods.filter { mod in
            if let uuid = mod.meta?.uuid.lowercased() { return !installedUUIDs.contains(uuid) }
            // No readable meta means no UUID to compare, so fall back to the filename.
            return !installedFiles.contains(mod.fileURL.lastPathComponent.lowercased())
        }
        statusMessage = syncCandidates.isEmpty
            ? "\(env.label) has nothing that isn't already installed here."
            : "\(syncCandidates.count) mod\(syncCandidates.count == 1 ? "" : "s") in \(env.label) aren't installed here."
    }

    /// Copy mods from the scanned source install into the active one.
    ///
    /// `install` brings split parts along, so a mod like Clothing arrives whole rather than as a
    /// 4 GiB fragment the game can't read.
    func copyMods(_ selection: [Mod]) {
        guard let repo else { statusMessage = "Pick a BG3 install first."; return }
        guard !selection.isEmpty else { return }

        var copied = 0
        var bytes: Int64 = 0
        var failed: [String] = []
        for mod in selection {
            do {
                try repo.install(pakAt: mod.fileURL)
                bytes += ModRepository.totalSize(of: mod.allFiles)
                copied += 1
            } catch {
                failed.append(mod.displayName)
            }
        }

        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        var message = "Copied \(copied) mod\(copied == 1 ? "" : "s") (\(size)) into \(activeEnvironment?.label ?? "this install")"
        if !failed.isEmpty { message += " · \(failed.count) failed" }
        statusMessage = message + ". They're installed but not enabled — apply a profile or turn them on."
        syncCandidates.removeAll { copied > 0 && selection.contains($0) }
        refresh()
    }

    /// Whether copying this mod into the active install would bring something that can't run there.
    /// Script Extender mods only work under CrossOver, so they are dead weight on the native build.
    /// True when the active install can't run Script Extender mods at all, so the sheet should offer
    /// to leave them behind.
    var wouldNeedScriptExtenderApply: Bool { !(activeEnvironment?.supportsScriptExtender ?? false) }

    func wouldNeedScriptExtender(_ mod: Mod) -> Bool {
        (mod.meta?.requiresScriptExtender ?? false) && !(activeEnvironment?.supportsScriptExtender ?? false)
    }

    // MARK: Save games

    private var saveRepo: SaveRepository? {
        activeEnvironment.map { SaveRepository(environment: $0) }
    }

    var savesTotalBytes: Int64 { saves.reduce(0) { $0 + $1.bytes } }
    var savesTotalSizeText: String {
        ByteCountFormatter.string(fromByteCount: savesTotalBytes, countStyle: .file)
    }

    /// Read the save folder for the active install. Sizing hundreds of folders touches the disk, so
    /// it runs off the main actor like the mod scan does.
    func loadSaves() async {
        guard let env = activeEnvironment else { saves = []; return }
        isLoadingSaves = true
        defer { isLoadingSaves = false }
        let loaded = await Task.detached { SaveRepository(environment: env).loadSaves() }.value
        saves = loaded
        statusMessage = loaded.isEmpty
            ? "No saves found in \(env.label)."
            : "\(loaded.count) save\(loaded.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: loaded.reduce(0) { $0 + $1.bytes }, countStyle: .file)) in \(env.label)."
    }

    /// Copy saves into another install on this Mac.
    ///
    /// The save format is the same in both builds, so this is a plain folder copy. What does *not*
    /// travel is the mod list — a save made with mods the target install lacks may refuse to load,
    /// which is why the sheet says so before you commit.
    func copySaves(_ selection: [SaveGame], to destination: GameEnvironment, overwrite: Bool) async {
        guard !selection.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }

        let repo = SaveRepository(environment: destination)
        var copied = 0
        var skipped: [String] = []
        var bytes: Int64 = 0
        for save in selection {
            do {
                try repo.receive(save, overwrite: overwrite)
                copied += 1
                bytes += save.bytes
            } catch {
                skipped.append(save.displayName)
            }
        }

        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        var message = "Copied \(copied) save\(copied == 1 ? "" : "s") (\(size)) to \(destination.label)"
        if !skipped.isEmpty {
            message += " · \(skipped.count) skipped\(overwrite ? "" : " (already there — tick Overwrite to replace)")"
        }
        statusMessage = message + "."
    }

    /// Copy saves to a staging folder, for moving to another machine.
    func exportSaves(_ selection: [SaveGame], to directory: URL, overwrite: Bool) async {
        guard let repo = saveRepo, !selection.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        saveExportPath = directory.path
        do {
            let result = try repo.export(selection, to: directory, overwrite: overwrite)
            let size = ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file)
            var message = "Exported \(result.copied) save\(result.copied == 1 ? "" : "s") (\(size)) to \(directory.lastPathComponent), with a manifest"
            if !result.skipped.isEmpty { message += " · \(result.skipped.count) skipped" }
            statusMessage = message + "."
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Delete saves, to the Trash where the volume allows it.
    func deleteSaves(_ selection: [SaveGame]) async {
        guard let repo = saveRepo, !selection.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }

        var trashed = 0, erased = 0
        var failed: [String] = []
        var bytes: Int64 = 0
        for save in selection {
            let result = repo.remove(save)
            if result.trashed { trashed += 1; bytes += save.bytes }
            else if result.removed { erased += 1; bytes += save.bytes }
            else { failed.append(save.displayName) }
        }

        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        var message = "Deleted \(trashed + erased) save\(trashed + erased == 1 ? "" : "s") (\(size))"
        if trashed > 0 { message += " · \(trashed) moved to the Trash" }
        if erased > 0 { message += " · \(erased) erased (couldn't be trashed)" }
        if !failed.isEmpty { message += " · \(failed.count) couldn't be removed" }
        statusMessage = message + "."
        await loadSaves()
    }

    // MARK: Bulk actions

    /// Total bytes of every installed pak, split parts included. Shown before deleting so the size
    /// of what's about to go is concrete rather than abstract.
    var installedBytes: Int64 { ModRepository.totalSize(of: mods.flatMap(\.allFiles)) }

    var installedSizeText: String {
        ByteCountFormatter.string(fromByteCount: installedBytes, countStyle: .file)
    }

    /// Turn off every mod in the load order, leaving the paks on disk.
    ///
    /// The order itself is the part that's expensive to recreate — a hand-tuned sequence of hundreds
    /// of mods — so it is saved as a profile first. Re-enabling is then one click in the Profiles
    /// menu rather than a rebuild from memory.
    /// A base-game module (GustavDev, GustavX, Honour, …) that bulk actions must
    /// never disable or delete — matched by the mod's meta UUID and name.
    static func isBaseGameMod(_ mod: Mod) -> Bool {
        BaseGameModules.isBaseGame(uuid: mod.meta?.uuid ?? mod.moduleUUID ?? "",
                                   name: mod.meta?.name ?? mod.displayName)
    }

    func deactivateAllMods() {
        guard !isScanningMods else {
            statusMessage = "Still scanning the Mods folder. Wait for the scan to finish."
            return
        }
        let count = enabledMods.count
        guard count > 0 else { statusMessage = "No mods are enabled."; return }

        var skipped = LoadOrderProfile.Skipped()
        let stamp = Self.snapshotFormatter.string(from: Date())
        let snapshot = LoadOrderProfile(name: "Before disable all · \(stamp)",
                                        environmentID: activeEnvironment?.id,
                                        mods: enabledMods,
                                        skipped: &skipped)
        if !snapshot.entries.isEmpty {
            profiles.append(snapshot)
            ProfileStore.save(profiles)
        }

        // Never disable base-game modules (GustavDev, GustavX, Honour, …). They
        // are not mods; disabling GustavDev in particular strips the main
        // campaign, and dependent mods (e.g. ruleset mods that modify Honour
        // mode) then silently fail to register. "Disable all" means "all MODS".
        var protectedCount = 0
        for index in mods.indices {
            if Self.isBaseGameMod(mods[index]) {
                protectedCount += 1
                continue
            }
            mods[index].isEnabled = false
        }
        applyOrder()

        let disabled = count - protectedCount
        let kept = protectedCount > 0 ? " (kept \(protectedCount) base-game module\(protectedCount == 1 ? "" : "s"))" : ""
        statusMessage = snapshot.entries.isEmpty
            ? "Disabled \(disabled) mod\(disabled == 1 ? "" : "s")\(kept). The paks are still installed."
            : "Disabled \(disabled) mod\(disabled == 1 ? "" : "s")\(kept) · saved “\(snapshot.name)” so you can put the order back."
    }

    /// Delete every installed pak.
    ///
    /// Files go to the Trash rather than being erased, because this can be tens of gigabytes and a
    /// misfire is otherwise unrecoverable. A volume that refuses to trash falls back to a permanent
    /// delete, and the summary says how many went each way.
    func deleteAllMods() {
        guard let repo else { statusMessage = "Pick a BG3 install first."; return }
        guard !isScanningMods else {
            statusMessage = "Still scanning the Mods folder. Wait for the scan to finish."
            return
        }
        // Exclude base-game modules from a bulk delete for the same reason as
        // "disable all" — they are the game, not mods. (Base modules are almost
        // never .pak files in the Mods folder, but if one is, do not trash it.)
        let targets = mods.filter { !Self.isBaseGameMod($0) }
        guard !targets.isEmpty else { statusMessage = "There are no mods to delete."; return }

        let freed = installedBytes
        var trashed = 0, erased = 0
        var failures: [String] = []

        for mod in targets {
            for file in mod.allFiles {
                if repo.trashPak(file) {
                    trashed += 1
                } else if (try? repo.deletePak(file)) != nil {
                    erased += 1
                } else {
                    failures.append(file.lastPathComponent)
                }
            }
            installRecords.removeValue(forKey: mod.noteKey)
        }
        saveRecords()

        // The load order still names the deleted mods; keep only the base
        // modules that were never deleted, and re-write the order from those.
        mods = mods.filter { Self.isBaseGameMod($0) }
        do { try repo.applyLoadOrder(mods) }
        catch { statusMessage = "Deleted the paks, but couldn't clear the load order: \(error.localizedDescription)" }

        let size = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
        var message = "Deleted \(targets.count) mod\(targets.count == 1 ? "" : "s") (\(size))"
        if trashed > 0 { message += " · \(trashed) file\(trashed == 1 ? "" : "s") moved to the Trash" }
        if erased > 0 { message += " · \(erased) erased (couldn't be trashed)" }
        if !failures.isEmpty { message += " · \(failures.count) couldn't be removed" }
        statusMessage = message + "."
        refresh()
    }

    private static let snapshotFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f
    }()

    // MARK: Install provenance / updates

    func record(for mod: Mod) -> InstallRecord? { installRecords[mod.noteKey] }

    /// When this mod was installed. The exact timestamp when the manager installed it; otherwise the
    /// pak's own creation date, which is a proxy — copying paks between folders resets it.
    func installedAt(for mod: Mod) -> (date: Date, isExact: Bool)? {
        if let exact = installRecords[mod.noteKey]?.installedAt { return (exact, true) }
        if let created = mod.fileCreatedAt { return (created, false) }
        return nil
    }

    func updateAvailable(for mod: Mod) -> Bool { installRecords[mod.noteKey]?.updateAvailable ?? false }

    var modsWithUpdates: [Mod] { mods.filter { updateAvailable(for: $0) } }

    var linkedModCount: Int { mods.filter { installRecords[$0.noteKey]?.isLinked ?? false }.count }

    private func saveRecords() { InstallRecordStore.save(installRecords) }

    /// File provenance recorded during an install under the mod's real key, now that the refresh has
    /// parsed its meta and we know its UUID.
    private func adoptPendingProvenance(into loaded: [Mod]) {
        guard !pendingProvenance.isEmpty else { return }
        var changed = false
        for mod in loaded {
            guard let pending = pendingProvenance.removeValue(forKey: mod.fileURL.lastPathComponent) else { continue }
            var record = pending
            if record.installedAt == nil { record.installedAt = Date() }
            installRecords[mod.noteKey] = record
            changed = true
        }
        pendingProvenance.removeAll()   // anything left didn't survive the install; don't accumulate
        if changed { saveRecords() }
    }

    /// Work out which upstream mod each installed pak is, by hashing it. See `UpdateChecker`.
    func identifyInstalledMods() async {
        guard !mods.isEmpty else { statusMessage = "No mods to identify."; return }
        guard !nexusAPIKey.isEmpty || !modioAPIKey.isEmpty else {
            statusMessage = "Add a Nexus or mod.io API key in Settings first."
            return
        }
        isCheckingUpdates = true; defer { isCheckingUpdates = false }
        let outcome = await UpdateChecker.backfillLinks(
            mods: mods,
            records: installRecords,
            nexusAPIKey: nexusAPIKey,
            modioAPIKey: modioAPIKey,
            progress: { [weak self] message in self?.statusMessage = message })
        installRecords = outcome.records
        saveRecords()
        statusMessage = outcome.message
    }

    /// Ask Nexus and mod.io what the newest version of each linked mod is.
    func checkForUpdates() async {
        guard !mods.isEmpty else { return }
        isCheckingUpdates = true; defer { isCheckingUpdates = false }
        let outcome = await UpdateChecker.checkForUpdates(
            mods: mods,
            records: installRecords,
            nexusAPIKey: nexusAPIKey,
            modioAPIKey: modioAPIKey,
            progress: { [weak self] message in self?.statusMessage = message })
        installRecords = outcome.records
        saveRecords()
        statusMessage = outcome.message
    }

    /// Download the newest upstream file for a mod and replace the pak on disk.
    ///
    /// The load order survives on its own: modsettings.lsx keys on the module UUID, which almost
    /// always carries across versions. The superseded pak is deleted only when the new release
    /// renamed the file, since leaving both behind would put two copies of the same UUID in the
    /// Mods folder and let the game load either one.
    func updateMod(_ mod: Mod) async {
        guard let repo else { statusMessage = "Pick a BG3 install first."; return }
        guard let record = installRecords[mod.noteKey], let modID = record.modID, let source = record.source else {
            statusMessage = "\(mod.displayName) isn't linked to Nexus or mod.io yet."
            return
        }
        isBusy = true; defer { isBusy = false }
        do {
            let url: URL
            var newFileID = record.latestFileID
            var newVersion = record.latestVersion
            var suggested = record.latestFileName ?? mod.displayName

            switch source {
            case .modio:
                let file = try await ModIOClient(apiKey: modioAPIKey).primaryFile(modID: modID)
                url = file.url
                newFileID = file.fileID
                newVersion = file.version
                suggested = file.filename ?? suggested
            case .nexus:
                let nexus = NexusClient(apiKey: nexusAPIKey)
                let files = try await nexus.files(modID: modID)
                guard let main = files.first(where: { $0.isMain }) ?? files.last else {
                    statusMessage = "Nexus has no downloadable file for \(mod.displayName)."
                    return
                }
                newFileID = main.file_id
                newVersion = main.version
                suggested = main.name
                url = try await nexus.downloadLink(modID: modID, fileID: main.file_id)
            }

            let paks = try await Downloader.fetchPaks(from: url, suggestedName: suggested)
            guard !paks.isEmpty else { statusMessage = "The download contained no .pak."; return }

            var updated = record
            updated.fileID = newFileID
            updated.version = newVersion
            updated.latestFileID = newFileID
            updated.latestVersion = newVersion
            updated.installedAt = Date()
            updated.md5 = nil               // the file changed; the cached hash is stale
            updated.link = .installedHere
            updated.lastCheckedAt = Date()

            let previousURL = mod.fileURL
            var installedNames: [String] = []
            for pak in paks {
                let dest = try repo.install(pakAt: pak)
                installedNames.append(dest.lastPathComponent)
                pendingProvenance[dest.lastPathComponent] = updated
            }

            if !installedNames.contains(previousURL.lastPathComponent) {
                try? repo.deletePak(previousURL)
                installRecords.removeValue(forKey: mod.noteKey)
            } else {
                installRecords[mod.noteKey] = updated
            }
            saveRecords()

            let version = newVersion.map { " to \($0)" } ?? ""
            statusMessage = "Updated \(mod.displayName)\(version)."
            refresh()
        } catch {
            statusMessage = "Update failed: \(error.localizedDescription)"
        }
    }

    /// Link a mod to an upstream page by hand, for paks the hash lookup couldn't identify.
    ///
    /// Whatever is upstream right now becomes the baseline, i.e. linking asserts "what I have is
    /// current". Anything published after this point then registers as an update.
    func linkMod(_ mod: Mod, to remote: RemoteMod) async {
        var record = installRecords[mod.noteKey] ?? InstallRecord()
        record.source = remote.source
        record.modID = remote.modID
        record.link = .manual
        record.lastCheckedAt = Date()

        switch remote.source {
        case .modio:
            if let file = try? await ModIOClient(apiKey: modioAPIKey).primaryFile(modID: remote.modID) {
                record.fileID = file.fileID
                record.version = file.version
                record.latestFileID = file.fileID
                record.latestVersion = file.version
                record.latestFileName = file.filename
            }
        case .nexus:
            if let files = try? await NexusClient(apiKey: nexusAPIKey).files(modID: remote.modID),
               let main = files.first(where: { $0.isMain }) ?? files.last {
                record.fileID = main.file_id
                record.version = main.version
                record.latestFileID = main.file_id
                record.latestVersion = main.version
                record.latestFileName = main.name
            }
        }
        installRecords[mod.noteKey] = record
        saveRecords()
        statusMessage = "Linked \(mod.displayName) to \(remote.name) on \(remote.source.rawValue)."
    }

    /// The upstream page for a linked mod, for "Open Mod Page".
    func modPageURL(for mod: Mod) -> URL? {
        guard let record = installRecords[mod.noteKey], let id = record.modID else { return nil }
        switch record.source {
        case .nexus: return URL(string: "https://www.nexusmods.com/baldursgate3/mods/\(id)")
        case .modio: return URL(string: "https://mod.io/g/baldursgate3/m/\(id)")
        case .none:  return nil
        }
    }

    /// " 1.2 -> 1.3" style suffix for buttons and tooltips, empty when versions aren't known.
    func latestVersionText(for mod: Mod) -> String {
        guard let record = installRecords[mod.noteKey], let latest = record.latestVersion else { return "" }
        if let current = record.version, current != latest { return " (\(current) → \(latest))" }
        return " (\(latest))"
    }

    func unlinkMod(_ mod: Mod) {
        guard installRecords[mod.noteKey] != nil else { return }
        var record = installRecords[mod.noteKey]!
        let installedAt = record.installedAt
        record = InstallRecord()
        record.installedAt = installedAt      // keep the install date; only the upstream link is dropped
        installRecords[mod.noteKey] = record
        saveRecords()
        statusMessage = "Unlinked \(mod.displayName)."
    }

    // MARK: Auto-sort by dependencies

    /// Reorder the enabled mods so each loads after its declared dependencies, then persist.
    func autoSortByDependencies() {
        guard repo != nil else { return }
        let result = LoadOrderSorter.sort(enabledMods)
        guard result.changed || !result.missingDependencies.isEmpty else {
            statusMessage = "Load order already satisfies all declared dependencies. ✅"
            return
        }
        mods = result.ordered + disabledMods
        applyOrder()

        var parts: [String] = []
        if result.changed { parts.append("Reordered by dependencies") } else { parts.append("Order unchanged") }
        if !result.cycleUUIDs.isEmpty { parts.append("\(result.cycleUUIDs.count) in a dependency cycle") }
        if !result.missingDependencies.isEmpty {
            let names = Set(result.missingDependencies.map { $0.mod.displayName })
            parts.append("\(names.count) mod\(names.count == 1 ? "" : "s") missing a required dependency")
        }
        statusMessage = parts.joined(separator: " · ")
    }

    // MARK: Health issue one-click fixes

    /// Apply the suggested resolution for a Health issue.
    func resolve(_ issue: HealthChecker.Issue) {
        switch issue.resolution {
        case .none:
            break
        case .autoSort:
            autoSortByDependencies()
        case .enableDependency(let uuid):
            enableMod(uuid: uuid, thenAutoSort: true)
        case .disableThisMod(let modID):
            setEnabled(modID: modID, false)
        case .copyUUID(let uuid):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(uuid, forType: .string)
            statusMessage = "Copied dependency UUID — search Nexus/mod.io for it."
        }
    }

    /// Apply every automatic fix (enable disabled deps, re-sort, disable SE-incompatible mods) until
    /// none remain. Issues that need manual action (missing deps) are left for you.
    func fixAllAutoResolvable() {
        var attempted = Set<String>()   // avoid oscillation (e.g. disable-SE vs re-enable-as-dependency)
        var guardCount = 0
        while let issue = healthReport.issues.first(where: { $0.resolution.isAutomatic && !attempted.contains($0.id) }),
              guardCount < 50 {
            attempted.insert(issue.id)
            resolve(issue)
            guardCount += 1
        }
        statusMessage = healthReport.isHealthy
            ? "Fixed all auto-resolvable issues. ✅"
            : "Applied automatic fixes — \(healthReport.issues.count) issue\(healthReport.issues.count == 1 ? "" : "s") still need manual action."
    }

    /// Enable the installed mod with this UUID; optionally re-sort so it lands before its dependents.
    func enableMod(uuid: String, thenAutoSort: Bool) {
        guard let mod = mods.first(where: { $0.meta?.uuid.lowercased() == uuid.lowercased() }) else {
            statusMessage = "That dependency isn't installed."
            return
        }
        toggle(mod, on: true)            // writes order + refreshes
        if thenAutoSort { autoSortByDependencies() }
    }

    func setEnabled(modID: String, _ on: Bool) {
        guard let mod = mods.first(where: { $0.id == modID }) else { return }
        toggle(mod, on: on)
    }

    // MARK: Profiles

    func saveProfile(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Saving mid-scan would snapshot a stale — or, just after launch, empty — mod list and
        // report that as the count.
        guard !isScanningMods else {
            statusMessage = "Still scanning the Mods folder. Wait for the scan to finish, then save."
            return
        }

        var skipped = LoadOrderProfile.Skipped()
        let profile = LoadOrderProfile(name: trimmed,
                                       environmentID: activeEnvironment?.id,
                                       mods: enabledMods,
                                       skipped: &skipped)
        profiles.append(profile)
        ProfileStore.save(profiles)

        var message = "Saved profile “\(trimmed)” (\(profile.entries.count) mod\(profile.entries.count == 1 ? "" : "s"))"
        if !skipped.noMeta.isEmpty {
            message += " · \(skipped.noMeta.count) skipped with no readable meta.lsx"
        }
        if !skipped.duplicates.isEmpty {
            message += " · \(skipped.duplicates.count) skipped as duplicate UUIDs"
        }
        statusMessage = message + "."
    }

    func deleteProfile(_ profile: LoadOrderProfile) {
        profiles.removeAll { $0.id == profile.id }
        ProfileStore.save(profiles)
        statusMessage = "Deleted profile “\(profile.name)”."
    }

    func exportProfile(_ profile: LoadOrderProfile, to url: URL) {
        do {
            try ProfileStore.exportProfile(profile, to: url)
            statusMessage = "Exported “\(profile.name)” to \(url.lastPathComponent)."
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    func importProfile(from url: URL) {
        do {
            var imported = try ProfileStore.importProfile(from: url)
            imported.id = UUID()   // fresh id so it never collides with an existing profile
            profiles.append(imported)
            ProfileStore.save(profiles)
            statusMessage = "Imported profile “\(imported.name)” (\(imported.entries.count) mods). Apply it from the Profiles menu."
        } catch {
            statusMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    // MARK: Backup / restore (load order + notes + profiles in one file)

    private func currentBackup() -> AppBackup {
        AppBackup(
            schema: AppBackup.currentSchema,
            createdAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            environmentLabel: activeEnvironment?.label,
            loadOrder: LoadOrderProfile(name: "Backup load order",
                                        environmentID: activeEnvironment?.id,
                                        mods: enabledMods),
            notes: notes,
            profiles: profiles
        )
    }

    /// One-click backup: snapshot the load order, notes, and profiles to a timestamped file.
    @discardableResult
    func backupNow() -> URL? {
        let backup = currentBackup()
        do {
            let url = try BackupStore.write(backup)
            statusMessage = "Backed up \(backup.loadOrder.entries.count) mods · \(notes.count) note\(notes.count == 1 ? "" : "s") · \(profiles.count) profile\(profiles.count == 1 ? "" : "s") → \(url.lastPathComponent)"
            return url
        } catch {
            statusMessage = "Backup failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Save a backup to a location the user picks (for sharing / moving machines).
    func exportBackup(to url: URL) {
        do {
            try BackupStore.export(currentBackup(), to: url)
            statusMessage = "Exported backup to \(url.lastPathComponent)."
        } catch {
            statusMessage = "Backup export failed: \(error.localizedDescription)"
        }
    }

    /// Restore a backup: merge its notes and profiles, then apply its saved load order to installed mods.
    func importBackup(from url: URL) {
        let backup: AppBackup
        do { backup = try BackupStore.read(from: url) }
        catch { statusMessage = "Couldn't read that backup: \(error.localizedDescription)"; return }

        // Notes: backup entries win; keep any local notes the backup doesn't mention.
        for (key, text) in backup.notes { notes[key] = text }
        NotesStore.save(notes)

        // Profiles: add any not already present (by id), so re-importing the same file won't duplicate.
        let existingIDs = Set(profiles.map { $0.id })
        let addedProfiles = backup.profiles.filter { !existingIDs.contains($0.id) }
        profiles.append(contentsOf: addedProfiles)
        ProfileStore.save(profiles)

        // Load order: enable + order the backed-up mods that are installed here (applyProfile reports
        // its own count and triggers a refresh; we prime a summary first for the no-install case).
        statusMessage = "Restored backup · \(backup.notes.count) note\(backup.notes.count == 1 ? "" : "s") merged · \(addedProfiles.count) new profile\(addedProfiles.count == 1 ? "" : "s")."
        if repo != nil { applyProfile(backup.loadOrder) }
    }

    /// Enable + order exactly the mods named in a profile (those present on disk), disable the rest.
    func applyProfile(_ profile: LoadOrderProfile) {
        guard repo != nil else { statusMessage = "Pick a BG3 install first."; return }
        let byUUID: [String: Mod] = Dictionary(
            mods.compactMap { mod in mod.meta.map { ($0.uuid.lowercased(), mod) } },
            uniquingKeysWith: { a, _ in a }
        )

        var enabled: [Mod] = []
        var missing = 0
        var missingUUIDs = Set<String>()
        for entry in profile.entries {
            if var mod = byUUID[entry.uuid.lowercased()] {
                mod.isEnabled = true
                enabled.append(mod)
            } else {
                missing += 1
                missingUUIDs.insert(entry.uuid.lowercased())
            }
        }
        lastMissingUUIDs = missingUUIDs
        let enabledIDs = Set(enabled.map { $0.id })
        let disabled = mods
            .filter { !enabledIDs.contains($0.id) }
            .map { m -> Mod in var x = m; x.isEnabled = false; return x }

        mods = enabled + disabled
        applyOrder()
        statusMessage = missing == 0
            ? "Applied “\(profile.name)” — \(enabled.count) mods enabled."
            : "Applied “\(profile.name)” — \(enabled.count) enabled, \(missing) not installed. Use “Copy from Install…” to bring them over from another install."
    }

    // MARK: Conflict detection

    /// Scan the currently-enabled load order for mods that ship the same in-game files.
    /// File reading happens off the main actor so the UI stays responsive.
    func scanConflicts() async {
        let ordered = enabledMods
        guard !ordered.isEmpty else {
            conflictReport = ConflictDetector.Report(fileConflicts: [], pairs: [], scannedModCount: 0)
            statusMessage = "No enabled mods to scan."
            return
        }
        isScanningConflicts = true
        let report = await Task.detached(priority: .userInitiated) {
            ConflictDetector.scan(ordered)
        }.value
        conflictReport = report
        isScanningConflicts = false
        statusMessage = report.isEmpty
            ? "No file conflicts across \(report.scannedModCount) enabled mods. ✅"
            : "\(report.fileConflicts.count) conflicting file\(report.fileConflicts.count == 1 ? "" : "s") across \(report.scannedModCount) mods."
    }

    // MARK: nxm:// deep links (Nexus "Mod Manager Download" button)

    /// Handle an `nxm://` URL handed off by the Nexus website. Resolves the token-authenticated
    /// download link (works for free accounts), downloads, unpacks and installs the pak.
    func handleNXM(_ url: URL) async {
        guard let link = NXMLink(url) else {
            statusMessage = "Ignored a link that wasn't a valid nxm:// download."
            return
        }
        guard link.isBaldursGate3 else {
            statusMessage = "Ignored an nxm link for \(link.gameDomain) — this manager only handles Baldur's Gate 3."
            return
        }
        guard repo != nil else { statusMessage = "Pick a BG3 install before downloading."; return }
        guard !nexusAPIKey.isEmpty else { statusMessage = "Add your Nexus API key in Settings to use nxm links."; return }

        isBusy = true; defer { isBusy = false }
        do {
            let nexus = NexusClient(apiKey: nexusAPIKey)
            let downloadURL = try await nexus.downloadLink(
                modID: link.modID, fileID: link.fileID, key: link.key, expires: link.expires)
            // Best-effort nice filename from the file metadata.
            let fetchedName = (try? await nexus.files(modID: link.modID)
                .first(where: { $0.file_id == link.fileID })?.name) ?? nil
            let name = fetchedName ?? "nexus-\(link.modID)-\(link.fileID)"
            var provenance = InstallRecord()
            provenance.source = .nexus
            provenance.modID = link.modID
            provenance.fileID = link.fileID
            provenance.latestFileID = link.fileID
            provenance.link = .installedHere
            provenance.installedAt = Date()
            provenance.lastCheckedAt = Date()

            let paks = try await Downloader.fetchPaks(from: downloadURL, suggestedName: name)
            for pak in paks { installLocalPak(pak, provenance: provenance) }
            statusMessage = "Installed \(name) from Nexus (\(paks.count) pak\(paks.count == 1 ? "" : "s"))."
        } catch {
            statusMessage = "nxm download failed: \(error.localizedDescription)"
        }
    }

    // MARK: Validation helpers

    func validateNexus() async {
        do {
            let name = try await NexusClient(apiKey: nexusAPIKey).validate()
            statusMessage = "Nexus key valid — signed in as \(name)."
        } catch {
            statusMessage = "Nexus key check failed: \(error.localizedDescription)"
        }
    }

    // MARK: Mac shader-compatibility fix

    static var shaderFixBackupDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BG3ModManagerMac/ShaderFixBackups", isDirectory: true)
    }

    private var baseMaterialsPak: URL? {
        guard let app = ScriptExtenderRelease.discoverGameApp() else { return nil }
        let pak = app.appendingPathComponent("Contents/Data/Materials.pak")
        return FileManager.default.fileExists(atPath: pak.path) ? pak : nil
    }

    func scanShaderCompat() {
        guard let env = activeEnvironment, !isScanningShaders else { return }
        let folder = env.modsFolder
        let materials = baseMaterialsPak
        let backupDir = Self.shaderFixBackupDir
        isScanningShaders = true
        shaderScanProgress = "Scanning…"
        shaderScanResults = []
        Task.detached(priority: .userInitiated) {
            let results = ShaderCompatFixer.scanFolder(folder, materialsPak: materials) { done, total in
                Task { @MainActor in self.shaderScanProgress = "Scanning \(done)/\(total)…" }
            }
            let fixed = Set(results.map(\.pakURL.path).filter {
                ShaderCompatFixer.backupExists(for: URL(fileURLWithPath: $0), backupDir: backupDir)
            })
            await MainActor.run {
                self.shaderScanResults = results
                self.fixedShaderPaks = fixed
                self.isScanningShaders = false
                self.shaderScanRan = true
                let broken = results.filter(\.affected).count
                self.shaderScanProgress = broken == 0
                    ? "No Windows-only shader mods found."
                    : "\(broken) mod\(broken == 1 ? "" : "s") with Windows-only shaders."
                if materials == nil {
                    self.shaderScanProgress += " (Base game not found — fix availability unknown.)"
                }
            }
        }
    }


    /// After a pak is rewritten (fixed or restored), bring its modsettings MD5
    /// back in line with the file on disk so the game trusts the entry.
    nonisolated private static func syncModSettingsMD5(pakURL: URL, modSettings: URL?) {
        guard let modSettings else { return }
        guard let metaData = try? PakReader.extractMetaLSX(from: pakURL),
              let meta = MetaParser.parse(metaData),
              let data = try? Data(contentsOf: pakURL) else { return }
        let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02hhx", $0) }.joined()
        ModSettings.syncMD5(moduleUUID: meta.uuid, md5: md5, in: modSettings)
    }

    func fixShaderCompat(_ result: ShaderCompatFixer.ScanResult) {
        guard result.fixable || result.partiallyFixable,
              let materialsPak = baseMaterialsPak else { return }
        let settingsFile = activeEnvironment?.modSettingsFile
        let backupDir = Self.shaderFixBackupDir
        let materials = baseMaterialsPak
        isBusy = true
        Task.detached(priority: .userInitiated) {
            var message: String
            var rescanned: ShaderCompatFixer.ScanResult? = nil
            do {
                try ShaderCompatFixer.fix(result, backupDir: backupDir, materialsPak: materialsPak)
                Self.syncModSettingsMD5(pakURL: result.pakURL, modSettings: settingsFile)
                rescanned = ShaderCompatFixer.scan(pakURL: result.pakURL, materialsPak: materials)
                message = "Fixed \(result.displayName) — original backed up."
            } catch {
                message = "Fix failed for \(result.displayName): \(error.localizedDescription)"
            }
            await MainActor.run {
                if let rescanned {
                    if !rescanned.affected || rescanned.brokenMaterials.allSatisfy({ !$0.repairable }) {
                        self.fixedShaderPaks.insert(result.pakURL.path)
                    }
                    if let i = self.shaderScanResults.firstIndex(where: { $0.id == result.id }) {
                        self.shaderScanResults[i] = rescanned
                    }
                }
                self.statusMessage = message
                self.isBusy = false
            }
        }
    }

    func fixAllShaderCompat() {
        let targets = shaderScanResults.filter {
            ($0.fixable || $0.partiallyFixable) && !fixedShaderPaks.contains($0.pakURL.path)
        }
        guard !targets.isEmpty, let materialsPak = baseMaterialsPak else { return }
        let settingsFile = activeEnvironment?.modSettingsFile
        let backupDir = Self.shaderFixBackupDir
        let materials = baseMaterialsPak
        isBusy = true
        statusMessage = "Fixing \(targets.count) mods…"
        Task.detached(priority: .userInitiated) {
            var fixedCount = 0, failed: [String] = []
            var updates: [ShaderCompatFixer.ScanResult] = []
            for t in targets {
                do {
                    try ShaderCompatFixer.fix(t, backupDir: backupDir, materialsPak: materialsPak)
                    Self.syncModSettingsMD5(pakURL: t.pakURL, modSettings: settingsFile)
                    if let r = ShaderCompatFixer.scan(pakURL: t.pakURL, materialsPak: materials) {
                        updates.append(r)
                        if !r.affected || r.brokenMaterials.allSatisfy({ !$0.repairable }) { fixedCount += 1 }
                    }
                } catch { failed.append(t.displayName) }
            }
            let failedNames = failed
            let fixedTotal = fixedCount
            await MainActor.run {
                for r in updates {
                    if !r.affected || r.brokenMaterials.allSatisfy({ !$0.repairable }) {
                        self.fixedShaderPaks.insert(r.pakURL.path)
                    }
                    if let i = self.shaderScanResults.firstIndex(where: { $0.id == r.id }) {
                        self.shaderScanResults[i] = r
                    }
                }
                self.statusMessage = failedNames.isEmpty
                    ? "Fixed \(fixedTotal) mods — originals backed up."
                    : "Fixed \(fixedTotal); failed: \(failedNames.joined(separator: ", "))"
                self.isBusy = false
            }
        }
    }

    func restoreShaderFix(_ result: ShaderCompatFixer.ScanResult) {
        let settingsFile = activeEnvironment?.modSettingsFile
        let backupDir = Self.shaderFixBackupDir
        let materials = baseMaterialsPak
        isBusy = true
        Task.detached(priority: .userInitiated) {
            var message: String
            var rescanned: ShaderCompatFixer.ScanResult? = nil
            do {
                try ShaderCompatFixer.restore(pakURL: result.pakURL, backupDir: backupDir)
                Self.syncModSettingsMD5(pakURL: result.pakURL, modSettings: settingsFile)
                rescanned = ShaderCompatFixer.scan(pakURL: result.pakURL, materialsPak: materials)
                message = "Restored original \(result.displayName)."
            } catch {
                message = "Restore failed for \(result.displayName): \(error.localizedDescription)"
            }
            await MainActor.run {
                self.fixedShaderPaks.remove(result.pakURL.path)
                if let rescanned, let i = self.shaderScanResults.firstIndex(where: { $0.id == result.id }) {
                    self.shaderScanResults[i] = rescanned
                }
                self.statusMessage = message
                self.isBusy = false
            }
        }
    }
}
