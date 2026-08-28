import Foundation

/// The game's own modules, which mods declare as dependencies but which are never `.pak` files in
/// the Mods folder.
///
/// Nearly every mod depends on at least `GustavDev`, and post-Patch-8 mods add `GustavX`; UI mods
/// pull in `MainUI`, `ModBrowser` and the dice sets. None of these can ever "resolve" to something
/// installed, so treating them like mod dependencies reports a missing dependency on almost every
/// mod in the list and buries the one or two that are real.
///
/// Matched by UUID first — the reliable key — and by module name as a backstop, so a base module
/// this table hasn't seen (a new dice set, say) still isn't mistaken for a missing mod.
enum BaseGameModules {

    /// UUIDs observed in the wild across a 782-mod library. All of these are Larian modules.
    static let uuids: Set<String> = [
        "28ac9ce2-2aba-8cda-b3b5-6e922f71b6b8",   // GustavDev
        "cb555efe-2d9e-131f-8195-a89329d218ea",   // GustavX      (Patch 8)
        "991c9c7a-fb80-40cb-8f0d-b92d4e80e9b1",   // Gustav
        "3d0c5ff8-c95d-c907-ff3e-34b204f1c630",   // SharedDev
        "9dff4c3b-fda7-43de-a763-ce1383039999",   // Engine
        "630daa32-70f8-3da5-41b9-154fe8410236",   // MainUI
        "ee5a55ff-eb38-0b27-c5b0-f358dc306d34",   // ModBrowser
        "55ef175c-59e3-b44b-3fb2-8f86acc5d550",   // PhotoMode
        "e1ce736b-52e6-e713-e9e7-e6abbb15a198",   // CrossplayUI
        "b77b6210-ac50-4cb1-a3d5-5702fb9c744c",   // Honour
        "767d0062-d82c-279c-e16b-dfee7fe94cdd",   // HonourX
        "e842840a-2449-588c-b0c4-22122cfce31b",   // DiceSet_01
        "b176a0ac-d79f-ed9d-5a87-5c2c80874e10",   // DiceSet_02
        "e0a4d990-7b9b-8fa9-d7c6-04017c6cf5b1",   // DiceSet_03
        "ee4989eb-aab8-968f-8674-812ea2f4bfd7",   // DiceSet_06
    ]

    /// Module names Larian ships. Used when a dependency's UUID isn't in the table above — the dice
    /// sets in particular come and go between patches.
    private static let names: Set<String> = [
        "gustav", "gustavdev", "gustavx", "shared", "shareddev", "engine",
        "mainui", "modbrowser", "photomode", "crossplayui", "honour", "honourx",
    ]

    /// True when this dependency is part of the game rather than a mod that needs installing.
    static func isBaseGame(uuid: String, name: String = "") -> Bool {
        if uuids.contains(uuid.lowercased()) { return true }
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        if names.contains(n) { return true }
        // DiceSet_01 … DiceSet_NN, and any future numbered sibling.
        if n.hasPrefix("diceset") { return true }
        return false
    }

    static func isBaseGame(_ dependency: ModDependency) -> Bool {
        isBaseGame(uuid: dependency.uuid, name: dependency.name)
    }
}
