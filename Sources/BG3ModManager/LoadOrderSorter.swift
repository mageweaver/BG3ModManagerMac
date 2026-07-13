import Foundation

/// Reorders a load order so every mod loads *after* the dependencies it declares in `meta.lsx`.
///
/// BG3 loads mods top-to-bottom, and a mod that patches another must come after it. This does a
/// stable topological sort over the declared dependency graph: dependencies are pulled earlier, and
/// mods with no ordering relationship keep their current relative position (so a hand-tuned order is
/// disturbed as little as possible). Dependencies that aren't installed are ignored, and dependency
/// cycles are reported rather than silently mangled.
enum LoadOrderSorter {

    struct Result {
        var ordered: [Mod]
        /// UUIDs involved in a dependency cycle (left in their original relative order).
        var cycleUUIDs: [String]
        /// (mod, missing dependency UUID) pairs — declared deps that aren't installed.
        var missingDependencies: [(mod: Mod, dependencyUUID: String)]
        var changed: Bool
    }

    static func sort(_ mods: [Mod]) -> Result {
        // Only mods with a known UUID can participate in the graph.
        let indexed = mods.enumerated().map { ($0.offset, $0.element) }
        let uuidToIndex: [String: Int] = Dictionary(
            indexed.compactMap { idx, mod in mod.meta.map { ($0.uuid.lowercased(), idx) } },
            uniquingKeysWith: { a, _ in a }
        )

        let n = mods.count
        var adjacency = Array(repeating: [Int](), count: n)   // dependency -> dependents
        var indegree = Array(repeating: 0, count: n)
        var missing: [(mod: Mod, dependencyUUID: String)] = []

        for (idx, mod) in indexed {
            guard let deps = mod.meta?.dependencyUUIDs else { continue }
            for depRaw in deps {
                let dep = depRaw.lowercased()
                // Base game / self deps don't constrain ordering.
                if dep == ModSettings.gustavDev.uuid || dep == mod.meta?.uuid.lowercased() { continue }
                guard let depIdx = uuidToIndex[dep] else {
                    missing.append((mod, depRaw))
                    continue
                }
                adjacency[depIdx].append(idx)   // edge: dependency must come before dependent
                indegree[idx] += 1
            }
        }

        // Kahn's algorithm with a stable tiebreaker: always emit the available node with the
        // smallest *original* index, preserving the user's existing order where unconstrained.
        var available = (0..<n).filter { indegree[$0] == 0 }.sorted()
        var orderIndices: [Int] = []
        orderIndices.reserveCapacity(n)

        while !available.isEmpty {
            let node = available.removeFirst()
            orderIndices.append(node)
            var newlyFreed: [Int] = []
            for dependent in adjacency[node] {
                indegree[dependent] -= 1
                if indegree[dependent] == 0 { newlyFreed.append(dependent) }
            }
            // Merge while keeping `available` sorted by original index.
            available = (available + newlyFreed).sorted()
        }

        // Any nodes left have indegree > 0 → they're in a cycle. Append them in original order.
        var cycleUUIDs: [String] = []
        if orderIndices.count < n {
            let placed = Set(orderIndices)
            let leftovers = (0..<n).filter { !placed.contains($0) }
            for i in leftovers {
                orderIndices.append(i)
                if let uuid = mods[i].meta?.uuid { cycleUUIDs.append(uuid) }
            }
        }

        let ordered = orderIndices.map { mods[$0] }
        let changed = orderIndices != Array(0..<n)
        return Result(ordered: ordered, cycleUUIDs: cycleUUIDs,
                      missingDependencies: missing, changed: changed)
    }
}
