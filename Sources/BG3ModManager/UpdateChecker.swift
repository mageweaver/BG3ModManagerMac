import Foundation

/// Links installed paks to their upstream pages, and works out which of them have a newer version.
///
/// Two jobs, deliberately kept apart because they cost very different things:
///
/// * **Backfill** answers "which mod is this pak?" for files that were already on disk when the
///   manager first saw them. It hashes each pak and matches that hash upstream. Exact when it hits;
///   silent when upstream doesn't recognise the file. Expensive, so it runs in bounded passes.
/// * **Update sweep** answers "is there something newer?" for mods that are already linked. Cheap,
///   because both APIs can answer in bulk.
enum UpdateChecker {

    struct Outcome {
        var records: [String: InstallRecord]
        var hashed = 0
        var examined = 0
        var linked = 0
        var updatesFound = 0
        /// True when a budget or rate limit cut the pass short, so there is more to do next time.
        var stoppedEarly = false
        var message = ""
    }

    // MARK: Backfill — identify paks that were already on disk

    /// Identify unlinked mods by hashing them and matching the hash upstream.
    ///
    /// mod.io goes first because it can be matched offline: paging the catalog once yields every
    /// listing's file md5, so any number of local paks can be identified from that one index. Nexus
    /// has no bulk equivalent — each unknown pak costs a request — so it runs second, bounded by
    /// `nexusLookupBudget` and by whatever the account's hourly allowance has left.
    ///
    /// A pak that neither service recognises is marked `.noHashMatch` so it is never hashed or
    /// looked up again; mods shipped inside a `.zip` land here, because the indexed hash upstream is
    /// the archive's rather than the pak's.
    static func backfillLinks(
        mods: [Mod],
        records input: [String: InstallRecord],
        nexusAPIKey: String,
        modioAPIKey: String,
        nexusLookupBudget: Int = 80,
        modioPageCap: Int = 40,
        progress: @escaping @MainActor (String) -> Void = { _ in }
    ) async -> Outcome {
        var out = Outcome(records: input)

        // Only mods with no link and no previous verdict are worth touching.
        let candidates = mods.filter { mod in
            let r = out.records[mod.noteKey]
            return !(r?.isLinked ?? false) && (r?.link ?? .unlinked) != .noHashMatch
        }
        guard !candidates.isEmpty else {
            out.message = "Every installed mod has already been identified."
            return out
        }

        // 1. Hash each candidate once, caching the result.
        await progress("Hashing \(candidates.count) mod\(candidates.count == 1 ? "" : "s")…")
        var hashes: [String: String] = [:]        // noteKey -> md5
        for (i, mod) in candidates.enumerated() {
            if let cached = out.records[mod.noteKey]?.md5 {
                hashes[mod.noteKey] = cached
                continue
            }
            guard let md5 = PakHash.md5(ofFileAt: mod.fileURL) else { continue }
            hashes[mod.noteKey] = md5
            var record = out.records[mod.noteKey] ?? InstallRecord()
            record.md5 = md5
            out.records[mod.noteKey] = record
            out.hashed += 1
            if i % 25 == 0 { await progress("Hashing… \(i + 1) of \(candidates.count)") }
        }

        // 2. mod.io: build an md5 index from the catalog, then match locally.
        if !modioAPIKey.isEmpty {
            await progress("Indexing the mod.io catalogue…")
            let index = await modioHashIndex(client: ModIOClient(apiKey: modioAPIKey),
                                             pageCap: modioPageCap,
                                             progress: progress)
            if !index.isEmpty {
                for mod in candidates {
                    guard let md5 = hashes[mod.noteKey], let hit = index[md5] else { continue }
                    var record = out.records[mod.noteKey] ?? InstallRecord()
                    record.source = .modio
                    record.modID = hit.id
                    record.fileID = hit.modfile?.id
                    record.version = hit.modfile?.version
                    record.link = .matchedByHash
                    out.records[mod.noteKey] = record
                    out.linked += 1
                }
            }
        }

        // 3. Nexus: one lookup per still-unknown pak, within budget.
        var nexusSpent = 0
        if !nexusAPIKey.isEmpty {
            let client = NexusClient(apiKey: nexusAPIKey)
            let stillUnknown = candidates.filter { !(out.records[$0.noteKey]?.isLinked ?? false) }
            await progress("Asking Nexus about \(min(stillUnknown.count, nexusLookupBudget)) mod\(stillUnknown.count == 1 ? "" : "s")…")

            for mod in stillUnknown {
                guard nexusSpent < nexusLookupBudget else { out.stoppedEarly = true; break }
                guard await NexusRateLimit.shared.hasBudget else { out.stoppedEarly = true; break }
                guard let md5 = hashes[mod.noteKey] else { continue }

                nexusSpent += 1
                out.examined += 1
                await NexusRateLimit.shared.spend()

                do {
                    if let match = try await client.identify(md5: md5) {
                        var record = out.records[mod.noteKey] ?? InstallRecord()
                        record.source = .nexus
                        record.modID = match.mod.mod_id
                        record.fileID = match.file_details.file_id
                        record.version = match.file_details.version
                        record.link = .matchedByHash
                        out.records[mod.noteKey] = record
                        out.linked += 1
                    } else {
                        // Nexus has no such file. Record the verdict so this pak is never re-checked.
                        var record = out.records[mod.noteKey] ?? InstallRecord()
                        record.link = .noHashMatch
                        out.records[mod.noteKey] = record
                    }
                } catch {
                    // A transport or auth failure says nothing about this mod — leave it unlinked so
                    // the next pass retries it, and stop rather than burn the budget on more failures.
                    out.stoppedEarly = true
                    out.message = "Nexus lookup stopped: \(error.localizedDescription)"
                    break
                }
                if out.examined % 10 == 0 {
                    await progress("Nexus lookup \(out.examined) of \(min(stillUnknown.count, nexusLookupBudget))…")
                }
            }
        }

        if out.message.isEmpty {
            let remaining = mods.filter { mod in
                let r = out.records[mod.noteKey]
                return !(r?.isLinked ?? false) && (r?.link ?? .unlinked) != .noHashMatch
            }.count
            out.message = "Identified \(out.linked) mod\(out.linked == 1 ? "" : "s")"
                + (out.stoppedEarly ? " · \(remaining) still to check — run it again later" : "")
                + "."
        }
        return out
    }

    /// Page the mod.io catalogue into an md5 -> listing index. Stops at `pageCap` pages so an
    /// unexpectedly large catalogue can't turn into an unbounded crawl.
    private static func modioHashIndex(
        client: ModIOClient,
        pageCap: Int,
        progress: @escaping @MainActor (String) -> Void
    ) async -> [String: ModIOMod] {
        var index: [String: ModIOMod] = [:]
        var offset = 0
        for page in 0..<pageCap {
            do {
                let result = try await client.catalogPage(offset: offset)
                for mod in result.data {
                    if let md5 = mod.modfile?.filehash?.md5?.lowercased() { index[md5] = mod }
                }
                let total = result.result_total ?? 0
                offset += result.data.count
                if result.data.isEmpty || offset >= total { break }
                if page % 5 == 0 { await progress("Indexing mod.io… \(offset) of \(total)") }
            } catch {
                break   // partial index is still useful
            }
        }
        return index
    }

    // MARK: Update sweep — is there anything newer?

    /// Refresh the latest-known-upstream state for every linked mod.
    ///
    /// mod.io is answered entirely in bulk. Nexus is asked which mods changed recently — one request
    /// for the whole game — and only those, plus mods never checked before, cost a per-mod lookup.
    static func checkForUpdates(
        mods: [Mod],
        records input: [String: InstallRecord],
        nexusAPIKey: String,
        modioAPIKey: String,
        nexusLookupBudget: Int = 120,
        progress: @escaping @MainActor (String) -> Void = { _ in }
    ) async -> Outcome {
        var out = Outcome(records: input)
        let linked = mods.filter { out.records[$0.noteKey]?.isLinked ?? false }
        guard !linked.isEmpty else {
            out.message = "No mods are linked to Nexus or mod.io yet — run “Identify installed mods” first."
            return out
        }

        // mod.io, in bulk.
        let modioMods = linked.filter { out.records[$0.noteKey]?.source == .modio }
        if !modioMods.isEmpty, !modioAPIKey.isEmpty {
            await progress("Checking \(modioMods.count) mod.io mod\(modioMods.count == 1 ? "" : "s")…")
            let ids = modioMods.compactMap { out.records[$0.noteKey]?.modID }
            if let fetched = try? await ModIOClient(apiKey: modioAPIKey).mods(ids: Array(Set(ids))) {
                let byID = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                for mod in modioMods {
                    guard var record = out.records[mod.noteKey],
                          let id = record.modID, let upstream = byID[id] else { continue }
                    record.latestFileID = upstream.modfile?.id
                    record.latestVersion = upstream.modfile?.version
                    record.latestFileName = upstream.modfile?.filename
                    record.lastCheckedAt = Date()
                    out.records[mod.noteKey] = record
                    out.examined += 1
                }
            }
        }

        // Nexus: narrow to mods that actually changed, then look those up.
        let nexusMods = linked.filter { out.records[$0.noteKey]?.source == .nexus }
        if !nexusMods.isEmpty, !nexusAPIKey.isEmpty {
            let client = NexusClient(apiKey: nexusAPIKey)
            var changed: Set<Int>? = nil
            if let recent = try? await client.recentlyUpdated(period: "1m") {
                changed = Set(recent.map { $0.mod_id })
            }

            // A mod never checked before has no baseline, so it needs a lookup whatever the feed says.
            let needsLookup = nexusMods.filter { mod in
                guard let record = out.records[mod.noteKey], let id = record.modID else { return false }
                if record.lastCheckedAt == nil || record.latestFileID == nil { return true }
                guard let changed else { return true }
                return changed.contains(id)
            }
            await progress("Checking \(needsLookup.count) Nexus mod\(needsLookup.count == 1 ? "" : "s")…")

            var spent = 0
            for mod in needsLookup {
                guard spent < nexusLookupBudget else { out.stoppedEarly = true; break }
                guard await NexusRateLimit.shared.hasBudget else { out.stoppedEarly = true; break }
                guard var record = out.records[mod.noteKey], let id = record.modID else { continue }

                spent += 1
                await NexusRateLimit.shared.spend()
                guard let files = try? await client.files(modID: id) else { continue }
                guard let main = files.first(where: { $0.isMain }) ?? files.last else { continue }

                record.latestFileID = main.file_id
                record.latestVersion = main.version
                record.latestFileName = main.name
                record.lastCheckedAt = Date()
                out.records[mod.noteKey] = record
                out.examined += 1
            }
        }

        out.updatesFound = mods.filter { out.records[$0.noteKey]?.updateAvailable ?? false }.count
        out.message = out.updatesFound == 0
            ? "Checked \(out.examined) mod\(out.examined == 1 ? "" : "s") — everything is up to date."
            : "\(out.updatesFound) update\(out.updatesFound == 1 ? "" : "s") available."
        if out.stoppedEarly { out.message += " Ran out of Nexus requests — check again later for the rest." }
        return out
    }
}
