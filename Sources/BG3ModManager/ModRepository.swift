import Foundation

/// Disk-facing operations: scan the Mods folder, read each pak's meta, reconcile with the active
/// load order, and install/remove pak files.
struct ModRepository {
    let environment: GameEnvironment

    /// Build the full mod list: every .pak on disk, enriched with meta + enabled state + load order.
    func loadMods() -> [Mod] {
        let fm = FileManager.default
        let modsFolder = environment.modsFolder
        let paks = (try? fm.contentsOfDirectory(at: modsFolder,
                                                includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles])) ?? []
            .filter { $0.pathExtension.lowercased() == "pak" }

        let order = ModSettings.readOrder(at: environment.modSettingsFile)
        // A real modsettings.lsx can list the same UUID more than once (duplicate/older mod versions).
        // Dictionary(uniqueKeysWithValues:) TRAPS on duplicate keys — keep the first (earliest) position.
        let orderIndex: [String: Int] = Dictionary(
            order.enumerated().map { ($1.uuid.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var mods: [Mod] = paks.map { url in
            let meta = readMeta(url)
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
                       compatibility: compat)
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
    @discardableResult
    func install(pakAt source: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: environment.modsFolder, withIntermediateDirectories: true)
        let dest = environment.modsFolder.appendingPathComponent(source.lastPathComponent)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: source, to: dest)
        return dest
    }

    /// Delete a pak from disk (does not touch the load order).
    func deletePak(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    /// Persist the given ordered, enabled mods to modsettings.lsx.
    func applyLoadOrder(_ enabled: [Mod]) throws {
        let metas = enabled.compactMap { $0.meta }
        try ModSettings.write(order: metas, to: environment.modSettingsFile)
    }
}
