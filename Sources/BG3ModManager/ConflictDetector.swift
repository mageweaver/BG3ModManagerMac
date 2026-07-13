import Foundation

/// Detects file-level conflicts: two or more loaded mods that ship the *same* in-game file path.
/// When that happens, BG3 uses the version from whichever mod is **later** in the load order, so the
/// earlier mod's version of that file is silently overridden. This finds those overlaps and tells you
/// which mod wins.
enum ConflictDetector {

    /// A single overlapping file across mods, listed in load order (last = the one that wins).
    struct FileConflict: Identifiable, Hashable {
        let path: String
        let mods: [Mod]              // ordered by load order
        var id: String { path }
        var winner: Mod? { mods.last }
        var losers: [Mod] { mods.count > 1 ? Array(mods.dropLast()) : [] }
    }

    /// A pairwise summary: how many files mod A and mod B both contain.
    struct PairOverlap: Identifiable, Hashable {
        let a: Mod
        let b: Mod
        let count: Int
        var id: String { "\(a.id)|\(b.id)" }
    }

    struct Report {
        var fileConflicts: [FileConflict]
        var pairs: [PairOverlap]
        var scannedModCount: Int
        var isEmpty: Bool { fileConflicts.isEmpty }
    }

    /// File paths that virtually every mod contains and which don't represent a real asset conflict.
    private static let ignoredSuffixes = ["meta.lsx", "/", "scriptextenderconfig.json"]
    private static func isNoise(_ path: String) -> Bool {
        let p = path.lowercased()
        if p.isEmpty { return true }
        return ignoredSuffixes.contains { p == $0 || p.hasSuffix($0) }
    }

    /// Scan the given mods (intended to be the *enabled* ones, in load order) for overlapping files.
    /// `fileLister` is injectable for testing; defaults to the real LSPK reader.
    static func scan(_ mods: [Mod],
                     fileLister: (URL) -> [String] = PakReader.fileNames) -> Report {
        // path -> ordered list of mod indices that contain it
        var owners: [String: [Int]] = [:]

        for (index, mod) in mods.enumerated() {
            // De-dupe within a single pak.
            var seen = Set<String>()
            for raw in fileLister(mod.fileURL) {
                let path = raw.lowercased()
                if isNoise(path) || seen.contains(path) { continue }
                seen.insert(path)
                owners[path, default: []].append(index)
            }
        }

        var fileConflicts: [FileConflict] = []
        var pairCounts: [String: (a: Int, b: Int, n: Int)] = [:]

        for (path, idxs) in owners where idxs.count > 1 {
            let conflictMods = idxs.map { mods[$0] }
            fileConflicts.append(FileConflict(path: path, mods: conflictMods))

            // Tally every pair that shares this file.
            for i in 0..<idxs.count {
                for j in (i + 1)..<idxs.count {
                    let key = "\(idxs[i])-\(idxs[j])"
                    pairCounts[key, default: (idxs[i], idxs[j], 0)].n += 1
                }
            }
        }

        let pairs = pairCounts.values
            .map { PairOverlap(a: mods[$0.a], b: mods[$0.b], count: $0.n) }
            .sorted { $0.count > $1.count }

        fileConflicts.sort { $0.path < $1.path }
        return Report(fileConflicts: fileConflicts, pairs: pairs, scannedModCount: mods.count)
    }
}
