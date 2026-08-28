import Foundation

/// Reads and writes `modsettings.lsx`, the file BG3 consults for the active load order.
/// The order of `<node id="ModuleShortDesc">` entries inside `<node id="Mods">` IS the load order.
enum ModSettings {

    /// The base-game module. Most load orders list it first; we always keep it at the top.
    static let gustavDev = ModMeta(
        name: "GustavDev", folder: "GustavDev",
        uuid: "28ac9ce2-2aba-8cda-b3b5-6e922f71b6b8",
        md5: "", version64: "36028797018963968", author: "Larian",
        dependencies: [], conflicts: [], requiresScriptExtender: false
    )

    // MARK: Read

    /// Returns the ordered list of (folder, uuid) currently enabled, excluding the GustavDev base.
    static func readOrder(at url: URL) -> [(folder: String, uuid: String)] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let reader = OrderReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.entries.filter { $0.uuid.lowercased() != gustavDev.uuid }
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
        var seen = Set<String>()
        let deduped = mods.filter { m in
            let key = m.uuid.lowercased()
            guard key != gustavDev.uuid, !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
        let ordered = [gustavDev] + deduped
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
    var entries: [(folder: String, uuid: String)] = []
    private var inMods = false
    private var nodeStack: [String] = []
    private var curFolder = ""
    private var curUUID = ""

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes attr: [String: String]) {
        if element == "node" {
            let id = attr["id"] ?? ""
            nodeStack.append(id)
            if id == "Mods" { inMods = true }
            if id == "ModuleShortDesc" { curFolder = ""; curUUID = "" }
        } else if element == "attribute", inMods, nodeStack.last == "ModuleShortDesc" {
            let id = attr["id"] ?? ""
            let value = attr["value"] ?? ""
            if id == "Folder" { curFolder = value }
            if id == "UUID" { curUUID = value }
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                qualifiedName: String?) {
        if element == "node" {
            let id = nodeStack.popLast() ?? ""
            if id == "ModuleShortDesc", inMods, !curUUID.isEmpty {
                entries.append((curFolder, curUUID))
            }
            if id == "Mods" { inMods = false }
        }
    }
}
