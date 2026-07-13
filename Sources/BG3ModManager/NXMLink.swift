import Foundation

/// A parsed `nxm://` deep link, as emitted by the "Mod Manager Download" button on the Nexus website.
///
/// Format:
///   nxm://<game-domain>/mods/<modID>/files/<fileID>?key=<key>&expires=<unix>&user_id=<id>
///
/// The `key`/`expires` pair is a short-lived token that lets *free* Nexus accounts resolve a direct
/// download link (Premium accounts don't need it). That's exactly why supporting nxm:// matters — it's
/// the only way non-Premium users can download through a manager instead of the browser.
struct NXMLink {
    var gameDomain: String
    var modID: Int
    var fileID: Int
    var key: String?
    var expires: Int?

    /// Returns nil if the URL isn't a well-formed nxm mod link.
    init?(_ url: URL) {
        guard url.scheme?.lowercased() == "nxm" else { return nil }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        // host is the game domain; path is /mods/<id>/files/<id>
        guard let host = comps.host, !host.isEmpty else { return nil }
        let parts = comps.path.split(separator: "/").map(String.init)   // ["mods","388","files","1234"]
        guard parts.count >= 4,
              parts[0].lowercased() == "mods", parts[2].lowercased() == "files",
              let mod = Int(parts[1]), let file = Int(parts[3]) else { return nil }

        gameDomain = host
        modID = mod
        fileID = file

        let items = comps.queryItems ?? []
        key = items.first(where: { $0.name == "key" })?.value
        expires = items.first(where: { $0.name == "expires" }).flatMap { $0.value.flatMap(Int.init) }
    }

    /// nxm links are game-specific; we only act on Baldur's Gate 3 links.
    var isBaldursGate3: Bool { gameDomain.lowercased() == "baldursgate3" }
}
