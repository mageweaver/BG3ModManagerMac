import Foundation

/// Downloads a mod archive and extracts the `.pak` file(s) inside it.
/// Mods on Nexus/mod.io arrive either as a bare `.pak` or as a `.zip` containing one.
enum Downloader {
    enum DownloadError: LocalizedError {
        case http(Int), noPak, unsupportedArchive(String)
        var errorDescription: String? {
            switch self {
            case .http(let c):              return "Download failed (HTTP \(c))."
            case .noPak:                    return "No .pak file was found in the download."
            case .unsupportedArchive(let e): return "Can't auto-extract .\(e) archives. Unpack it manually, then add the .pak."
            }
        }
    }

    /// Download `url`, returning the local `.pak` file URLs (in a temp folder the caller can install from).
    static func fetchPaks(from url: URL, suggestedName: String) async throws -> [URL] {
        let (tempFile, resp) = try await URLSession.shared.download(from: url)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DownloadError.http(http.statusCode)
        }

        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BG3MM-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        // Decide the type from the response filename / suggested name.
        let ext = (resp.suggestedFilename ?? suggestedName).split(separator: ".").last.map(String.init)?.lowercased() ?? ""

        switch ext {
        case "pak":
            let dest = work.appendingPathComponent(sanitized(suggestedName, fallback: "mod.pak", ext: "pak"))
            try FileManager.default.moveItem(at: tempFile, to: dest)
            return [dest]
        case "zip":
            let zip = work.appendingPathComponent("archive.zip")
            try FileManager.default.moveItem(at: tempFile, to: zip)
            return try extractZip(zip, into: work)
        case "rar", "7z":
            throw DownloadError.unsupportedArchive(ext)
        default:
            // Unknown extension: try treating the bytes as a zip, else as a raw pak.
            let zip = work.appendingPathComponent("archive.zip")
            try FileManager.default.moveItem(at: tempFile, to: zip)
            if let paks = try? extractZip(zip, into: work), !paks.isEmpty { return paks }
            let dest = work.appendingPathComponent(sanitized(suggestedName, fallback: "mod.pak", ext: "pak"))
            try? FileManager.default.moveItem(at: zip, to: dest)
            return FileManager.default.fileExists(atPath: dest.path) ? [dest] : []
        }
    }

    private static func extractZip(_ zip: URL, into dir: URL) throws -> [URL] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-o", "-q", zip.path, "-d", dir.path]
        try proc.run()
        proc.waitUntilExit()

        // Collect every .pak anywhere in the extracted tree.
        var paks: [URL] = []
        if let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let f as URL in e where f.pathExtension.lowercased() == "pak" { paks.append(f) }
        }
        guard !paks.isEmpty else { throw DownloadError.noPak }
        return paks
    }

    private static func sanitized(_ name: String, fallback: String, ext: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bad = CharacterSet(charactersIn: "/\\:")
        let clean = trimmed.components(separatedBy: bad).joined(separator: "-")
        if clean.isEmpty { return fallback }
        return clean.lowercased().hasSuffix(".\(ext)") ? clean : "\(clean).\(ext)"
    }
}
