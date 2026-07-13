import Foundation

/// Parses a BG3 `meta.lsx` (XML) into a `ModMeta`.
///
/// meta.lsx looks like:
///   <save><region id="Config"><node id="root"><children>
///     <node id="Dependencies"><children>
///        <node id="ModuleShortDesc"><attribute id="UUID" value="..."/> ... </node>
///     </children></node>
///     <node id="ModuleInfo">
///        <attribute id="Name" value="..."/><attribute id="UUID" value="..."/>
///        <attribute id="Folder" value="..."/><attribute id="Version64" value="..."/> ...
///     </node>
///   </children></node></region></save>
final class MetaParser: NSObject, XMLParserDelegate {

    private var nodeStack: [String] = []          // stack of node @id values
    private var info: [String: String] = [:]      // ModuleInfo attributes
    private var dependencyUUIDs: [String] = []
    private var sawScriptExtenderNode = false

    static func parse(_ data: Data) -> ModMeta? {
        let p = MetaParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        guard parser.parse() else { return nil }

        let name = p.info["Name"] ?? ""
        let folder = p.info["Folder"] ?? ""
        let uuid = p.info["UUID"] ?? ""
        guard !uuid.isEmpty || !folder.isEmpty else { return nil }

        let dependsOnSE = p.sawScriptExtenderNode
            || p.dependencyUUIDs.contains { $0.lowercased().contains("scriptextender") }
            || name.lowercased().contains("script extender")

        return ModMeta(
            name: name.isEmpty ? folder : name,
            folder: folder.isEmpty ? name : folder,
            uuid: uuid,
            md5: p.info["MD5"] ?? "",
            version64: p.info["Version64"] ?? p.info["Version"] ?? "",
            author: p.info["Author"] ?? "",
            dependencyUUIDs: p.dependencyUUIDs,
            requiresScriptExtender: dependsOnSE
        )
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attr: [String: String]) {
        switch element {
        case "node":
            let id = attr["id"] ?? ""
            nodeStack.append(id)
            if id == "ScriptExtenderConfig" || id == "ScriptExtender" { sawScriptExtenderNode = true }
        case "attribute":
            guard let id = attr["id"] else { return }
            let value = attr["value"] ?? attr["handle"] ?? ""
            let inModuleInfo = nodeStack.last == "ModuleInfo"
            let inDependency = nodeStack.last == "ModuleShortDesc"
            if inModuleInfo {
                info[id] = value
            } else if inDependency, id == "UUID" {
                dependencyUUIDs.append(value)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        if element == "node", !nodeStack.isEmpty { nodeStack.removeLast() }
    }
}
