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
    private var dependencies: [ModDependency] = []
    private var conflicts: [ModDependency] = []
    /// Attributes of the ModuleShortDesc currently being read; flushed when the node closes.
    private var pendingDependency: [String: String] = [:]
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
            || p.dependencies.contains { $0.name.lowercased().contains("scriptextender") }
            || name.lowercased().contains("script extender")

        return ModMeta(
            name: name.isEmpty ? folder : name,
            folder: folder.isEmpty ? name : folder,
            uuid: uuid,
            md5: p.info["MD5"] ?? "",
            version64: p.info["Version64"] ?? p.info["Version"] ?? "",
            author: p.info["Author"] ?? "",
            dependencies: p.dependencies,
            conflicts: p.conflicts,
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
            } else if inDependency {
                pendingDependency[id] = value
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        guard element == "node", !nodeStack.isEmpty else { return }
        if nodeStack.last == "ModuleShortDesc" {
            // meta.lsx uses ModuleShortDesc for two different relationships — <Dependencies> and
            // <Conflicts> — so the enclosing section decides what this entry means. Reading them
            // interchangeably turns "don't install this alongside me" into "install this first",
            // and then reports the conflict as a missing dependency.
            let section = nodeStack.dropLast().last ?? ""
            if let uuid = pendingDependency["UUID"], !uuid.isEmpty {
                let entry = ModDependency(uuid: uuid,
                                          name: pendingDependency["Name"] ?? "",
                                          folder: pendingDependency["Folder"] ?? "")
                switch section {
                case "Dependencies": dependencies.append(entry)
                case "Conflicts":    conflicts.append(entry)
                default:             break
                }
            }
            pendingDependency.removeAll()
        }
        nodeStack.removeLast()
    }
}
