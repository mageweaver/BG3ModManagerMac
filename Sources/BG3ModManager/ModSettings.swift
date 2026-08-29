import Foundation

/// Reads and writes `modsettings.lsx`, the file BG3 consults for the active load order.
/// The order of `<node id="ModuleShortDesc">` entries inside `<node id="Mods">` IS the load order.
enum ModSettings {

    /// Base-game modules. Patch 8 lists GustavX (the campaign), Honour and
    /// HonourX in modsettings; GustavDev is implicit and the GAME REMOVES any
    /// GustavDev entry on boot — writing one guarantees the in-game "load
    /// order has been reset" message. So GustavDev stays in `baseUUIDs` (never
    /// treated as a user mod, protected from bulk actions) but is NOT written.
    /// The Version64/MD5 values below are the game's own canonical entries for
    /// build 4.1.1.7398727, used only as a fallback: `write` prefers the
    /// entries the game last wrote to the file itself, so a game patch that
    /// changes them self-heals on the next write.
    static let gustavDevUUID = "28ac9ce2-2aba-8cda-b3b5-6e922f71b6b8"
    static let gustavX = ModMeta(
        name: "GustavX", folder: "GustavX",
        uuid: "cb555efe-2d9e-131f-8195-a89329d218ea",
        md5: "ef3fcba3f3684b3088ad1f9874d4957c",
        version64: "145241946983300916", author: "Larian",
        dependencies: [], conflicts: [], requiresScriptExtender: false
    )
    static let honour = ModMeta(
        name: "Honour", folder: "Honour",
        uuid: "b77b6210-ac50-4cb1-a3d5-5702fb9c744c",
        md5: "931dacd8b5fd7a7f39330e72432517d2",
        version64: "36028797026107188", author: "Larian",
        dependencies: [], conflicts: [], requiresScriptExtender: false
    )
    static let honourX = ModMeta(
        name: "HonourX", folder: "HonourX",
        uuid: "767d0062-d82c-279c-e16b-dfee7fe94cdd",
        md5: "a7986aa127818dab105e831b095419ef",
        version64: "36028797026107188", author: "Larian",
        dependencies: [], conflicts: [], requiresScriptExtender: false
    )
    static let writtenBaseModules = [gustavX, honour, honourX]
    static let baseUUIDs: Set<String> =
        Set(writtenBaseModules.map(\.uuid) + [gustavDevUUID])

    // MARK: Read

    /// Returns the ordered list of (folder, uuid) currently enabled, excluding the GustavDev base.
    static func readOrder(at url: URL) -> [(folder: String, uuid: String)] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let reader = OrderReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.entries
            .filter { !baseUUIDs.contains($0.uuid.lowercased()) }
            .map { (folder: $0.folder, uuid: $0.uuid) }
    }

    /// All entries as the game last wrote them, base modules included.
    static func readRawEntries(at url: URL)
        -> [(folder: String, uuid: String, md5: String, version64: String)] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let reader = OrderReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.entries
    }

    // MARK: Write

    /// Write a new modsettings.lsx for the given ordered enabled mods. Backs up the previous file.
    static func write(order mods: [ModMeta], to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: url.path) {
            let backup = url.deletingPathExtension()
                .appendingPathExtension("backup-\(Int(Date().timeIntervalSince1970)).lsx")
            try? FileManager.default.copyItem(at: url, to: backup)
        }

        // Drop the base module (re-added first) and de-duplicate by UUID, keeping the first occurrence —
        // two different paks can declare the same module UUID, and BG3 must not see it listed twice.
        // Prefer the base-module entries the game itself last wrote (real
        // Version64/MD5 for the running patch); fall back to our snapshot.
        let existing = readRawEntries(at: url)
        let base = writtenBaseModules.map { fallback in
            existing.first { $0.uuid.lowercased() == fallback.uuid }
                .map { fallback.replacingIdentity(folder: $0.folder, md5: $0.md5,
                                                  version64: $0.version64) }
                ?? fallback
        }
        var seen = Set<String>()
        let deduped = mods.filter { m in
            let key = m.uuid.lowercased()
            guard !baseUUIDs.contains(key), !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
        let ordered = base + deduped
        let xml = render(ordered)
        try xml.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    private static func render(_ mods: [ModMeta]) -> String {
        var nodes = ""
        for m in mods {
            nodes += """
                        <node id="ModuleShortDesc">
                          <attribute id="Folder" type="LSString" value="\(esc(m.folder))"/>
                          <attribute id="MD5" type="LSString" value="\(esc(m.md5))"/>
                          <attribute id="Name" type="LSString" value="\(esc(m.name))"/>
                          <attribute id="PublishHandle" type="uint64" value="0"/>
                          <attribute id="UUID" type="guid" value="\(esc(m.uuid))"/>
                          <attribute id="Version64" type="int64" value="\(m.version64.isEmpty ? "36028797018963968" : m.version64)"/>
                        </node>

            """
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <save>
          <version major="4" minor="8" revision="0" build="100"/>
          <region id="ModuleSettings">
            <node id="root">
              <children>
                <node id="Mods">
                  <children>
        \(nodes)          </children>
                </node>
              </children>
            </node>
          </region>
        </save>
        """
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private final class OrderReader: NSObject, XMLParserDelegate {
    var entries: [(folder: String, uuid: String, md5: String, version64: String)] = []
    private var inMods = false
    private var nodeStack: [String] = []
    private var curFolder = ""
    private var curUUID = ""
    private var curMD5 = ""
    private var curVersion64 = ""

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes attr: [String: String]) {
        if element == "node" {
            let id = attr["id"] ?? ""
            nodeStack.append(id)
            if id == "Mods" { inMods = true }
            if id == "ModuleShortDesc" { curFolder = ""; curUUID = ""; curMD5 = ""; curVersion64 = "" }
        } else if element == "attribute", inMods, nodeStack.last == "ModuleShortDesc" {
            let id = attr["id"] ?? ""
            let value = attr["value"] ?? ""
            if id == "Folder" { curFolder = value }
            if id == "UUID" { curUUID = value }
            if id == "MD5" { curMD5 = value }
            if id == "Version64" { curVersion64 = value }
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                qualifiedName: String?) {
        if element == "node" {
            let id = nodeStack.popLast() ?? ""
            if id == "ModuleShortDesc", inMods, !curUUID.isEmpty {
                entries.append((curFolder, curUUID, curMD5, curVersion64))
            }
            if id == "Mods" { inMods = false }
        }
    }
}
