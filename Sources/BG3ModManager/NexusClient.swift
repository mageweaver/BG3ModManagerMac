import Foundation

/// Thin client for the Nexus Mods public API (https://api.nexusmods.com).
///
/// Auth: a personal API key (Nexus → Account Settings → API Keys). Sent in the `apikey` header.
/// Note: the public API has no full-text search endpoint (that's website-only), so "browse" surfaces
/// the trending / latest-added / latest-updated feeds and direct lookups by mod ID. Generating a
/// download link requires Nexus Premium *or* an `nxm://` handoff from the website for free users.
struct NexusClient {
    enum Feed: String, CaseIterable { case trending, latestAdded = "latest_added", latestUpdated = "latest_updated" }

    enum NexusError: LocalizedError {
        case missingKey, http(Int), decode
        var errorDescription: String? {
            switch self {
            case .missingKey: return "Add your Nexus API key in Settings first."
            case .http(let c): return "Nexus API returned HTTP \(c)."
            case .decode:      return "Couldn't read the Nexus response."
            }
        }
    }

    var apiKey: String
    private let game = "baldursgate3"
    private let base = URL(string: "https://api.nexusmods.com/v1/")!

    private func request(_ path: String) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw NexusError.missingKey }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.setValue(apiKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("BG3ModManagerMac/1.0", forHTTPHeaderField: "Application-Name")
        return req
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(for: try request(path))
        guard let http = resp as? HTTPURLResponse else { throw NexusError.decode }
        guard (200..<300).contains(http.statusCode) else { throw NexusError.http(http.statusCode) }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw NexusError.decode }
    }

    /// Validate the key and return the account name.
    func validate() async throws -> String {
        struct User: Decodable { let name: String }
        return try await get("users/validate.json", as: User.self).name
    }

    /// Browse a feed (trending / latest). Returns the mods as `RemoteMod`s.
    func browse(_ feed: Feed) async throws -> [RemoteMod] {
        let raw = try await get("games/\(game)/mods/\(feed.rawValue).json", as: [NexusMod].self)
        return raw.map { $0.asRemoteMod }
    }

    /// Look up a single mod by its numeric ID.
    func mod(id: Int) async throws -> RemoteMod {
        let raw = try await get("games/\(game)/mods/\(id).json", as: NexusMod.self)
        return raw.asRemoteMod
    }

    /// Files attached to a mod (you usually want the MAIN category file).
    func files(modID: Int) async throws -> [NexusFile] {
        struct Wrapper: Decodable { let files: [NexusFile] }
        return try await get("games/\(game)/mods/\(modID)/files.json", as: Wrapper.self).files
    }

    /// Resolve a direct download URL. Works directly only for Premium accounts; for free accounts the
    /// `key`/`expires` pair from an `nxm://` link must be supplied.
    func downloadLink(modID: Int, fileID: Int, key: String? = nil, expires: Int? = nil) async throws -> URL {
        var path = "games/\(game)/mods/\(modID)/files/\(fileID)/download_link.json"
        if let key, let expires { path += "?key=\(key)&expires=\(expires)" }
        struct Link: Decodable { let URI: String }
        let links = try await get(path, as: [Link].self)
        guard let first = links.first, let url = URL(string: first.URI) else { throw NexusError.decode }
        return url
    }
}

// MARK: Nexus JSON shapes

struct NexusMod: Decodable {
    let mod_id: Int
    let name: String?
    let summary: String?
    let author: String?
    let picture_url: String?

    var asRemoteMod: RemoteMod {
        let summary = (self.summary ?? "").decodingHTMLEntities()
        return RemoteMod(
            id: "nexus:\(mod_id)",
            source: .nexus,
            modID: mod_id,
            name: name ?? "Mod \(mod_id)",
            summary: summary,
            author: author ?? "",
            thumbnailURL: picture_url.flatMap(URL.init(string:)),
            pageURL: URL(string: "https://www.nexusmods.com/baldursgate3/mods/\(mod_id)"),
            mentionsScriptExtender: ((name ?? "") + " " + summary).lowercased().contains("script extender")
        )
    }
}

struct NexusFile: Decodable, Identifiable {
    let file_id: Int
    let name: String
    let category_name: String?
    let version: String?
    let size_kb: Int?
    var id: Int { file_id }
    var isMain: Bool { (category_name ?? "").uppercased() == "MAIN" }
}

extension String {
    /// Very small HTML-entity / tag cleanup for summaries (Nexus returns light HTML).
    func decodingHTMLEntities() -> String {
        replacingOccurrences(of: "<br />", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
