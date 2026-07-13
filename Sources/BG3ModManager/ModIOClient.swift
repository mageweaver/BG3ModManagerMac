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

    /// Resolve the primary downloadable file URL for a mod.io mod.
    func downloadURL(modID: Int) async throws -> URL {
        let mod = try await get("games/@\(gameNameID)/mods/\(modID)", query: [], as: ModIOMod.self)
        guard let binary = mod.modfile?.download?.binary_url, let url = URL(string: binary) else {
            throw ModIOError.noFile
        }
        return url
    }
}

// MARK: mod.io JSON shapes

struct ModIOPage: Decodable { let data: [ModIOMod] }

struct ModIOMod: Decodable {
    struct Logo: Decodable { let thumb_320x180: String? }
    struct SubmittedBy: Decodable { let username: String? }
    struct Download: Decodable { let binary_url: String? }
    struct ModFile: Decodable { let download: Download? }

    let id: Int
    let name: String?
    let summary: String?
    let profile_url: String?
    let logo: Logo?
    let submitted_by: SubmittedBy?
    let modfile: ModFile?

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
