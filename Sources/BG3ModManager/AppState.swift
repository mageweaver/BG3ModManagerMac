import Foundation
import SwiftUI
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

    // Remote browsing.
    @Published var remoteResults: [RemoteMod] = []
    @Published var remoteSource: RemoteMod.Source = .modio

    // Conflict detection.
    @Published var conflictReport: ConflictDetector.Report?
    @Published var isScanningConflicts = false

    // Saved load-order profiles.
    @Published var profiles: [LoadOrderProfile] = []

    // Dependency / compatibility health of the current load order (recomputed on every refresh).
    @Published var healthReport = HealthChecker.Report(issues: [], checkedCount: 0)

    // Settings (persisted).
    @AppStorage("nexusAPIKey") var nexusAPIKey = ""
    @AppStorage("modioAPIKey") var modioAPIKey = ""
    @AppStorage("customDocumentsPath") private var customDocumentsPath = ""
    @AppStorage("customGameBinPath") private var customGameBinPath = ""

    private var repo: ModRepository? {
        activeEnvironment.map { ModRepository(environment: $0) }
    }

    // MARK: Discovery / refresh

    func bootstrap() {
        profiles = ProfileStore.load()
        var envs = EnvironmentLocator.discover()
        if !customDocumentsPath.isEmpty {
            let base = URL(fileURLWithPath: customDocumentsPath)
            let bin = customGameBinPath.isEmpty ? nil : URL(fileURLWithPath: customGameBinPath)
            envs.append(EnvironmentLocator.custom(at: base, gameBin: bin))
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
        guard let repo else { mods = []; return }
        // Scanning the Mods folder means memory-mapping and parsing every .pak (potentially thousands
        // of files / many GB). That must never run on the main actor or the window can't even paint —
        // so do the disk work in a detached task and publish the result back on the main actor.
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isBusy = true
        statusMessage = "Scanning mods in \(activeEnvironment?.label ?? "")…"
        Task { [repo] in
            let loaded = await Task.detached { repo.loadMods() }.value
            guard generation == self.refreshGeneration else { return } // a newer refresh superseded us
            self.mods = loaded
            self.healthReport = HealthChecker.check(enabled: loaded.filter { $0.isEnabled }, all: loaded)
            let enabled = loaded.filter { $0.isEnabled }.count
            self.statusMessage = "\(loaded.count) mod\(loaded.count == 1 ? "" : "s") · \(enabled) enabled · \(self.activeEnvironment?.label ?? "")"
            self.isBusy = false
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
            refresh()
        } catch {
            statusMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    func installLocalPak(_ url: URL) {
        guard let repo else { return }
        do {
            try repo.install(pakAt: url)
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
            switch source {
            case .nexus:
                remoteResults = try await NexusClient(apiKey: nexusAPIKey).browse(.trending)
            case .modio:
                remoteResults = try await ModIOClient(apiKey: modioAPIKey).search(query)
            }
            statusMessage = "\(remoteResults.count) result\(remoteResults.count == 1 ? "" : "s") from \(source.rawValue)."
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
            switch remote.source {
            case .modio:
                url = try await ModIOClient(apiKey: modioAPIKey).downloadURL(modID: remote.modID)
            case .nexus:
                let nexus = NexusClient(apiKey: nexusAPIKey)
                let files = try await nexus.files(modID: remote.modID)
                guard let main = files.first(where: { $0.isMain }) ?? files.first else {
                    statusMessage = "No file found for \(remote.name)."; return
                }
                url = try await nexus.downloadLink(modID: remote.modID, fileID: main.file_id)
            }
            let paks = try await Downloader.fetchPaks(from: url, suggestedName: remote.name)
            for pak in paks { installLocalPak(pak) }
            statusMessage = "Downloaded \(remote.name) (\(paks.count) pak\(paks.count == 1 ? "" : "s"))."
        } catch {
            statusMessage = "Download failed: \(error.localizedDescription)"
        }
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
        let profile = LoadOrderProfile(name: trimmed,
                                       environmentID: activeEnvironment?.id,
                                       mods: enabledMods)
        profiles.append(profile)
        ProfileStore.save(profiles)
        statusMessage = "Saved profile “\(trimmed)” (\(profile.entries.count) mods)."
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

    /// Enable + order exactly the mods named in a profile (those present on disk), disable the rest.
    func applyProfile(_ profile: LoadOrderProfile) {
        guard repo != nil else { statusMessage = "Pick a BG3 install first."; return }
        let byUUID: [String: Mod] = Dictionary(
            mods.compactMap { mod in mod.meta.map { ($0.uuid.lowercased(), mod) } },
            uniquingKeysWith: { a, _ in a }
        )

        var enabled: [Mod] = []
        var missing = 0
        for entry in profile.entries {
            if var mod = byUUID[entry.uuid.lowercased()] {
                mod.isEnabled = true
                enabled.append(mod)
            } else {
                missing += 1
            }
        }
        let enabledIDs = Set(enabled.map { $0.id })
        let disabled = mods
            .filter { !enabledIDs.contains($0.id) }
            .map { m -> Mod in var x = m; x.isEnabled = false; return x }

        mods = enabled + disabled
        applyOrder()
        statusMessage = missing == 0
            ? "Applied “\(profile.name)” — \(enabled.count) mods enabled."
            : "Applied “\(profile.name)” — \(enabled.count) enabled, \(missing) not installed (skipped)."
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
            let paks = try await Downloader.fetchPaks(from: downloadURL, suggestedName: name)
            for pak in paks { installLocalPak(pak) }
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
}
