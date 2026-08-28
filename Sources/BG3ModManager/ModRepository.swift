import Foundation

/// Disk-facing operations: scan the Mods folder, read each pak's meta, reconcile with the active
/// load order, and install/remove pak files.
struct ModRepository {
    let environment: GameEnvironment

    /// Build the full mod list: every .pak on disk, enriched with meta + enabled state + load order.
    func loadMods() -> [Mod] {
        let fm = FileManager.default
        let modsFolder = environment.modsFolder
        // Parenthesised deliberately: `(try? …) ?? [].filter { … }` parses as
        // `(try? …) ?? ([].filter { … })`, which applies the filter to the empty fallback and lets
        // every non-pak file in the folder through as a mod.
        let contents = (try? fm.contentsOfDirectory(
            at: modsFolder,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        let paks = contents.filter { $0.pathExtension.lowercased() == "pak" }

        let order = ModSettings.readOrder(at: environment.modSettingsFile)
        // A real modsettings.lsx can list the same UUID more than once (duplicate/older mod versions).
        // Dictionary(uniqueKeysWithValues:) TRAPS on duplicate keys — keep the first (earliest) position.
        let orderIndex: [String: Int] = Dictionary(
            order.enumerated().map { ($1.uuid.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // A pak over 4 GiB is split, and only the first file has a header — the rest are raw payload
        // named `Name_1.pak`, `Name_2.pak`. Listing those as mods would show them as broken (no meta
        // to read) and invite deleting them, which quietly breaks the mod they belong to. Attach them
        // to their parent instead.
        var partsByParent: [String: [URL]] = [:]
        var archives: [URL] = []
        let pakNames = Set(paks.map { $0.lastPathComponent })
        for url in paks {
            if let parent = Self.parentOfPart(url), pakNames.contains(parent), !PakReader.isArchive(url) {
                partsByParent[parent, default: []].append(url)
            } else {
                archives.append(url)
            }
        }

        var mods: [Mod] = archives.map { url in
            let meta = readMeta(url)
            let parts = (partsByParent[url.lastPathComponent] ?? [])
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let stem = url.deletingPathExtension().lastPathComponent
            let expected = PakReader.partCount(of: url)
            let present = Set(parts.map { $0.lastPathComponent })
            let missing = (1..<max(1, expected)).map { "\(stem)_\($0).pak" }.filter { !present.contains($0) }
            let enabledIndex = meta.flatMap { orderIndex[$0.uuid.lowercased()] }
            let compat: Mod.Compatibility
            if meta == nil {
                compat = .unreadableMeta
            } else if meta!.requiresScriptExtender && !environment.supportsScriptExtender {
                compat = .needsScriptExtender
            } else {
                compat = .ok
            }
            return Mod(fileURL: url,
                       meta: meta,
                       isEnabled: enabledIndex != nil,
                       loadOrderIndex: enabledIndex,
                       compatibility: compat,
                       parts: parts,
                       missingParts: missing,
                       fileCreatedAt: Self.createdAt(url))
        }

        // Enabled mods sorted by their load-order position; disabled mods after, alphabetical.
        mods.sort { a, b in
            switch (a.loadOrderIndex, b.loadOrderIndex) {
            case let (ia?, ib?): return ia < ib
            case (_?, nil):      return true
            case (nil, _?):      return false
            default:             return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            }
        }
        return mods
    }

    /// `Clothing_1.pak` -> `Clothing.pak`. Nil when the name isn't of that shape.
    ///
    /// The name alone isn't proof — a mod may legitimately be called `Something_1.pak` — so callers
    /// also check that the file has no LSPK header of its own.
    static func parentOfPart(_ url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let underscore = stem.lastIndex(of: "_") else { return nil }
        let suffix = stem[stem.index(after: underscore)...]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return nil }
        let base = String(stem[stem.startIndex..<underscore])
        guard !base.isEmpty else { return nil }
        return base + ".pak"
    }

    /// When the pak arrived in the Mods folder. Creation date is the better signal; some volumes
    /// (and some copy tools) don't set one, so modification date is the fallback.
    private static func createdAt(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }

    private func readMeta(_ pak: URL) -> ModMeta? {
        guard let lsx = try? PakReader.extractMetaLSX(from: pak) else { return nil }
        var meta = MetaParser.parse(lsx)
        // Second SE signal: pak ships a ScriptExtender config file.
        if meta != nil, !meta!.requiresScriptExtender,
           ScriptExtender.pakReferencesScriptExtender(pak) {
            meta!.requiresScriptExtender = true
        }
        return meta
    }

    /// Copy a downloaded .pak into the Mods folder. Returns the destination URL.
    ///
    /// Split parts sitting beside the source are copied too — a mod big enough to be split does not
    /// load at all without them, and they are easy to leave behind because they look like junk.
    @discardableResult
    func install(pakAt source: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: environment.modsFolder, withIntermediateDirectories: true)
        let dest = environment.modsFolder.appendingPathComponent(source.lastPathComponent)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: source, to: dest)
        try installParts(alongside: source)
        return dest
    }

    /// Copy any `Name_1.pak`, `Name_2.pak` … found next to `source` into the Mods folder.
    private func installParts(alongside source: URL) throws {
        let fm = FileManager.default
        let dir = source.deletingLastPathComponent()
        let siblings = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for sibling in siblings where sibling.pathExtension.lowercased() == "pak" {
            guard Self.parentOfPart(sibling) == source.lastPathComponent else { continue }
            let dest = environment.modsFolder.appendingPathComponent(sibling.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: sibling, to: dest)
        }
    }

    /// Delete a pak from disk (does not touch the load order).
    func deletePak(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    /// Move a pak to the Trash instead of erasing it. Used for bulk deletion, where the amount at
    /// stake makes recoverability worth more than reclaiming the space immediately.
    /// Returns false if the volume can't trash it, so the caller can decide what to do rather than
    /// silently destroying a file the user expected to be able to get back.
    func trashPak(_ url: URL) -> Bool {
        (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil
    }

    /// Total size on disk of the given files, for reporting before a destructive action.
    static func totalSize(of urls: [URL]) -> Int64 {
        urls.reduce(into: Int64(0)) { sum, url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            sum += Int64(values?.fileSize ?? 0)
        }
    }

    /// Persist the given ordered, enabled mods to modsettings.lsx.
    func applyLoadOrder(_ enabled: [Mod]) throws {
        let metas = enabled.compactMap { $0.meta }
        try ModSettings.write(order: metas, to: environment.modSettingsFile)
    }
}
