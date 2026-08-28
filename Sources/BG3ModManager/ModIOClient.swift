import Foundation

/// Thin client for the mod.io API (https://api.mod.io/v1) — the same backend BG3's in-game mod
/// manager uses. Read access only needs a public `api_key`. Full-text search IS supported via `_q`,
/// and most BG3 mods expose a directly downloadable `binary_url` on their primary modfile.
struct ModIOClient {
    enum ModIOError: LocalizedError {
        case missingKey, http(Int), decode, noFile
        var errorDescription: String? {
            switch self {
            case .missingKey: return "Add your mod.io API key in Settings first."
            case .http(let c): return "mod.io API returned HTTP \(c)."
            case .decode:      return "Couldn't read the mod.io response."
            case .noFile:      return "This mod.io entry has no downloadable file."
            }
        }
    }

    var apiKey: String
    /// BG3's name-id on mod.io. Using the `@name-id` form avoids hard-coding a numeric game ID.
    private let gameNameID = "baldursgate3"
    private let base = URL(string: "https://api.mod.io/v1/")!

    private func url(_ path: String, query: [URLQueryItem]) throws -> URL {
        guard !apiKey.isEmpty else { throw ModIOError.missingKey }
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = query + [URLQueryItem(name: "api_key", value: apiKey)]
        return comps.url!
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem], as: T.Type) async throws -> T {
        var req = URLRequest(url: try url(path, query: query))
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ModIOError.decode }
        guard (200..<300).contains(http.statusCode) else { throw ModIOError.http(http.statusCode) }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ModIOError.decode }
    }

    /// Full-text search across ALL BG3 mods on mod.io. `_q` matches the entire catalog server-side
    /// (not just a page); an empty query returns the most-popular sort. Limit 100 is mod.io's page max.
    func search(_ query: String) async throws -> [RemoteMod] {
        var q = [URLQueryItem(name: "_limit", value: "100"),
                 URLQueryItem(name: "_sort", value: "-popular")]
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            q.append(URLQueryItem(name: "_q", value: query))
        }
        let page = try await get("games/@\(gameNameID)/mods", query: q, as: ModIOPage.self)
        return page.data.map { $0.asRemoteMod }
    }

    /// Look up many mods in one request. mod.io caps a page at 100, so the caller chunks.
    ///
    /// Each result carries its current `modfile` — version, file id and md5 — which is everything an
    /// update check needs, so a few hundred linked mods cost a handful of requests rather than one each.
    func mods(ids: [Int]) async throws -> [ModIOMod] {
        guard !ids.isEmpty else { return [] }
        var out: [ModIOMod] = []
        for chunk in stride(from: 0, to: ids.count, by: 100).map({ Array(ids[$0..<min($0 + 100, ids.count)]) }) {
            let q = [URLQueryItem(name: "id-in", value: chunk.map(String.init).joined(separator: ",")),
                     URLQueryItem(name: "_limit", value: "100")]
            out += try await get("games/@\(gameNameID)/mods", query: q, as: ModIOPage.self).data
        }
        return out
    }

    /// One page of the whole BG3 catalog, newest first.
    ///
    /// Used to build a local md5 index: every mod.io listing exposes its file's md5, so paging the
    /// catalog once lets any number of local paks be identified offline. That is far cheaper than
    /// Nexus's per-file lookup, which has no bulk equivalent.
    func catalogPage(offset: Int, limit: Int = 100) async throws -> ModIOPage {
        let q = [URLQueryItem(name: "_limit", value: String(limit)),
                 URLQueryItem(name: "_offset", value: String(offset)),
                 URLQueryItem(name: "_sort", value: "-date_updated")]
        return try await get("games/@\(gameNameID)/mods", query: q, as: ModIOPage.self)
    }

    /// Resolve the primary downloadable file URL for a mod.io mod.
    func downloadURL(modID: Int) async throws -> URL {
        try await primaryFile(modID: modID).url
    }

    /// The mod's current file: where to get it, and which file it is. The identity matters as much as
    /// the URL — it is what a later check compares against to decide whether a newer file exists.
    func primaryFile(modID: Int) async throws -> (url: URL, fileID: Int?, version: String?, filename: String?) {
        let mod = try await get("games/@\(gameNameID)/mods/\(modID)", query: [], as: ModIOMod.self)
        guard let binary = mod.modfile?.download?.binary_url, let url = URL(string: binary) else {
            throw ModIOError.noFile
        }
        return (url, mod.modfile?.id, mod.modfile?.version, mod.modfile?.filename)
    }
}

// MARK: mod.io JSON shapes

struct ModIOPage: Decodable {
    let data: [ModIOMod]
    let result_count: Int?
    let result_offset: Int?
    let result_total: Int?
}

struct ModIOMod: Decodable {
    struct Logo: Decodable { let thumb_320x180: String? }
    struct SubmittedBy: Decodable { let username: String? }
    struct Download: Decodable { let binary_url: String? }
    struct FileHash: Decodable { let md5: String? }
    struct ModFile: Decodable {
        let id: Int?
        let version: String?
        let filename: String?
        let filehash: FileHash?
        let download: Download?
    }

    let id: Int
    let name: String?
    let summary: String?
    let profile_url: String?
    let logo: Logo?
    let submitted_by: SubmittedBy?
    let modfile: ModFile?
    let date_updated: Int?

    var asRemoteMod: RemoteMod {
        let text = ((name ?? "") + " " + (summary ?? "")).lowercased()
        return RemoteMod(
            id: "modio:\(id)",
            source: .modio,
            modID: id,
            name: name ?? "Mod \(id)",
            summary: summary ?? "",
            author: submitted_by?.username ?? "",
            thumbnailURL: logo?.thumb_320x180.flatMap(URL.init(string:)),
            pageURL: profile_url.flatMap(URL.init(string:)),
            mentionsScriptExtender: text.contains("script extender")
        )
    }
}
