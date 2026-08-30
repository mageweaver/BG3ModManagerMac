import Foundation
import Compression

/// Detects and repairs mods that ship Windows-only compiled shaders.
///
/// BG3 on macOS renders with Metal, but the Windows modding toolkit compiles a
/// mod's custom materials only for DX11/DX12/Vulkan. When such a material is a
/// re-export of a base-game material it carries the SAME MaterialID as the
/// original, and the mod's registration shadows the base game's Metal-complete
/// one. The first time the game builds a visual that uses it, shader/pipeline
/// creation spins forever on a shader that has no Metal build — the "spinner
/// never finishes, game at 300% CPU" hang (diagnosed live on The Bloodletter,
/// 2026-08-29; 54 of 782 installed mods showed the same pattern).
///
/// The fix: strip the overriding material definitions and their shader blobs
/// from the pak. The base game's own material — same UUID, full Metal shader
/// set — then takes over, and the modded meshes render with standard shaders.
/// Only materials whose MaterialID matches a same-named base-game material are
/// stripped (a wholly custom material has no base fallback, so a mod carrying
/// one is flagged but not auto-fixed). The original pak is backed up first and
/// the rewritten pak is re-validated before it replaces anything.
enum ShaderCompatFixer {

    // MARK: - Results

    struct MaterialInfo: Identifiable {
        var id: String { path }
        let path: String            // full path inside the pak
        let baseName: String        // e.g. CHAR_Hair.lsf
        let materialID: String?     // UUID extracted from the LSF, if found
        let overridesBaseGame: Bool // base game has a same-named material with the same UUID
    }

    struct ScanResult: Identifiable {
        var id: String { pakURL.path }
        let pakURL: URL
        let displayName: String
        let shaderCount: Int
        let platforms: Set<String>
        let materials: [MaterialInfo]

        /// Ships compiled shaders but no Metal build of them.
        var affected: Bool { shaderCount > 0 && !platforms.contains("Metal") }
        /// Every material is a base-game override, so stripping is a clean fallback.
        var fixable: Bool {
            affected && !materials.isEmpty && materials.allSatisfy(\.overridesBaseGame)
        }
        var customMaterialCount: Int { materials.filter { !$0.overridesBaseGame }.count }
    }

    enum FixError: LocalizedError {
        case multiPart, notV18, corrupt, verifyFailed(String), noBackupDir, lz4Failed

        var errorDescription: String? {
            switch self {
            case .multiPart:     return "split archives (multi-part paks) can't be rewritten"
            case .notV18:        return "only LSPK v18 paks are supported"
            case .corrupt:       return "the pak could not be parsed"
            case .verifyFailed(let why): return "rewritten pak failed validation: \(why)"
            case .noBackupDir:   return "could not create the backup folder"
            case .lz4Failed:     return "could not compress the rewritten file table"
            }
        }
    }

    // MARK: - Scan

    /// Base-game material index: basename -> full path inside Materials.pak.
    /// Built once per scan; the pak has ~16k entries and listing it is cheap.
    private static func baseMaterialIndex(materialsPak: URL) -> [String: String] {
        var index: [String: String] = [:]
        for name in PakReader.fileNames(from: materialsPak) where name.hasSuffix(".lsf") {
            let base = (name as NSString).lastPathComponent
            if index[base] == nil { index[base] = name }
        }
        return index
    }

    /// The MaterialID lives in the binary LSF as an ASCII UUID near the
    /// "MaterialID" attribute name. Byte-scanning is deliberate: a full LSF
    /// parser is not needed to answer "which material is this."
    private static func extractMaterialID(fromLSF data: Data) -> String? {
        let uuidPattern = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
        guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
        if let marker = text.range(of: "MaterialID") {
            let tail = text[marker.upperBound...].prefix(300)
            if let m = tail.range(of: uuidPattern, options: .regularExpression) {
                return String(tail[m])
            }
        }
        if let m = text.range(of: uuidPattern, options: .regularExpression) {
            return String(text[m])
        }
        return nil
    }

    /// Scan one mod pak. Returns nil for unreadable/non-v18/split paks.
    static func scan(pakURL: URL, materialsPak: URL?,
                     baseIndex: [String: String]? = nil) -> ScanResult? {
        guard PakReader.isArchive(pakURL), PakReader.partCount(of: pakURL) == 1 else { return nil }
        let names = PakReader.fileNames(from: pakURL)
        guard !names.isEmpty else { return nil }

        var platforms: Set<String> = []
        var shaderCount = 0
        var materialPaths: [String] = []
        for n in names {
            if n.hasSuffix(".bshd") {
                shaderCount += 1
                for p in ["DX11", "DX12", "Vulkan", "Metal"] where n.hasSuffix("_\(p).bshd") {
                    platforms.insert(p)
                }
            } else if n.hasSuffix(".lsf"), n.contains("/Materials/") {
                materialPaths.append(n)
            }
        }

        var materials: [MaterialInfo] = []
        if shaderCount > 0 && !platforms.contains("Metal"), let materialsPak {
            let index = baseIndex ?? baseMaterialIndex(materialsPak: materialsPak)
            for path in materialPaths {
                let base = (path as NSString).lastPathComponent
                var overrides = false
                var modID: String? = nil
                if let basePath = index[base],
                   let modData = try? PakReader.extractFile(from: pakURL,
                                                            matching: { $0 == path.lowercased() }),
                   let baseData = try? PakReader.extractFile(from: materialsPak,
                                                              matching: { $0 == basePath.lowercased() }) {
                    modID = extractMaterialID(fromLSF: modData)
                    let baseID = extractMaterialID(fromLSF: baseData)
                    overrides = (modID != nil && modID == baseID)
                }
                materials.append(MaterialInfo(path: path, baseName: base,
                                              materialID: modID, overridesBaseGame: overrides))
            }
        }

        return ScanResult(pakURL: pakURL,
                          displayName: pakURL.deletingPathExtension().lastPathComponent,
                          shaderCount: shaderCount,
                          platforms: platforms,
                          materials: materials)
    }

    /// Scan every pak in a folder. `materialsPak` is the base game's
    /// Data/Materials.pak; without it, affected mods are found but none are
    /// classified fixable (no override check is possible).
    static func scanFolder(_ modsFolder: URL, materialsPak: URL?,
                           progress: ((Int, Int) -> Void)? = nil) -> [ScanResult] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: modsFolder,
                                                        includingPropertiesForKeys: nil) else { return [] }
        let paks = entries.filter { $0.pathExtension.lowercased() == "pak" }
        let index = materialsPak.map { baseMaterialIndex(materialsPak: $0) }
        var results: [ScanResult] = []
        for (i, pak) in paks.enumerated() {
            progress?(i + 1, paks.count)
            if let r = scan(pakURL: pak, materialsPak: materialsPak, baseIndex: index),
               r.affected {
                results.append(r)
            }
        }
        return results.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // MARK: - Fix

    /// Strip the Windows-only shader set from a fixable pak, in place, after
    /// backing up the original. Returns the backup location.
    @discardableResult
    static func fix(_ result: ScanResult, backupDir: URL) throws -> URL {
        precondition(result.fixable, "fix() requires a fixable scan result")
        let fm = FileManager.default
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let strippedMaterials = Set(result.materials.map { $0.path.lowercased() })
        let tmp = result.pakURL.deletingLastPathComponent()
            .appendingPathComponent(".\(result.pakURL.lastPathComponent).macfix.tmp")
        defer { try? fm.removeItem(at: tmp) }

        let dropped = try rewrite(src: result.pakURL, dst: tmp) { name in
            let lower = name.lowercased()
            if lower.hasSuffix(".bshd") { return true }
            return strippedMaterials.contains(lower)
        }

        // Validate the rewrite before touching the original: parseable, the
        // dropped files are gone, and the mod's identity (meta.lsx) survived.
        let newNames = PakReader.fileNames(from: tmp)
        guard !newNames.isEmpty else { throw FixError.verifyFailed("empty file table") }
        if newNames.contains(where: { $0.hasSuffix(".bshd") }) {
            throw FixError.verifyFailed("shader files remain")
        }
        let hadMeta = (try? PakReader.extractMetaLSX(from: result.pakURL)) != nil
        if hadMeta, (try? PakReader.extractMetaLSX(from: tmp)) == nil {
            throw FixError.verifyFailed("meta.lsx unreadable after rewrite")
        }
        guard dropped == result.shaderCount + result.materials.count else {
            throw FixError.verifyFailed("expected to drop \(result.shaderCount + result.materials.count) files, dropped \(dropped)")
        }

        let backup = backupDir.appendingPathComponent(result.pakURL.lastPathComponent)
        if !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: result.pakURL, to: backup)
        }
        _ = try fm.replaceItemAt(result.pakURL, withItemAt: tmp)
        return backup
    }

    /// Whether a backup exists for this pak (i.e. it has been fixed before).
    static func backupExists(for pakURL: URL, backupDir: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: backupDir.appendingPathComponent(pakURL.lastPathComponent).path)
    }

    /// Put the original pak back from its backup.
    static func restore(pakURL: URL, backupDir: URL) throws {
        let backup = backupDir.appendingPathComponent(pakURL.lastPathComponent)
        let fm = FileManager.default
        guard fm.fileExists(atPath: backup.path) else { throw FixError.corrupt }
        let tmp = pakURL.deletingLastPathComponent()
            .appendingPathComponent(".\(pakURL.lastPathComponent).restore.tmp")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: backup, to: tmp)
        _ = try fm.replaceItemAt(pakURL, withItemAt: tmp)
        try? fm.removeItem(at: backup)
    }

    // MARK: - LSPK v18 writer

    /// Rebuild an LSPK v18 pak without the entries `dropping` matches. Kept
    /// payloads are copied byte-for-byte (compression preserved); only the
    /// entry offsets and the header's file-list fields change. Returns how
    /// many entries were dropped.
    private static func rewrite(src: URL, dst: URL, dropping: (String) -> Bool) throws -> Int {
        let inHandle = try FileHandle(forReadingFrom: src)
        defer { try? inHandle.close() }
        let fileSize = Int(try inHandle.seekToEnd())

        func read(at offset: Int, count: Int) throws -> Data {
            guard offset >= 0, count >= 0, offset + count <= fileSize else { throw FixError.corrupt }
            try inHandle.seek(toOffset: UInt64(offset))
            guard let d = try inHandle.read(upToCount: count), d.count == count else {
                throw FixError.corrupt
            }
            return d
        }

        let header = try read(at: 0, count: 40)
        guard header[0] == 0x4C, header[1] == 0x53, header[2] == 0x50, header[3] == 0x4B else {
            throw FixError.corrupt
        }
        guard header.readU32(at: 4) == 18 else { throw FixError.notV18 }
        guard header.readU16(at: 38) <= 1 else { throw FixError.multiPart }

        let stride = 272
        let fileListOffset = Int(header.readU64(at: 8))
        let counts = try read(at: fileListOffset, count: 8)
        let numFiles = Int(counts.readU32(at: 0))
        let compressedSize = Int(counts.readU32(at: 4))
        let compressed = try read(at: fileListOffset + 8, count: compressedSize)
        let table = try PakReader.lz4BlockDecompress(compressed, expectedSize: numFiles * stride)
        guard table.count >= numFiles * stride else { throw FixError.corrupt }

        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let out = try FileHandle(forWritingTo: dst)
        defer { try? out.close() }
        try out.write(contentsOf: Data(count: 40))   // header placeholder

        var newTable = Data()
        newTable.reserveCapacity(table.count)
        var droppedCount = 0
        var writeOffset = 40

        for i in 0..<numFiles {
            let base = i * stride
            var entry = table.subdata(in: base ..< base + stride)
            let name = entry.readCString(at: 0, maxLen: 256)
            if dropping(name) { droppedCount += 1; continue }

            let oldOffset = Int(UInt64(entry.readU32(at: 256)) | (UInt64(entry.readU16(at: 260)) << 32))
            let sizeOnDisk = Int(entry.readU32(at: 264))
            let uncompressed = Int(entry.readU32(at: 268))
            let bytesOnDisk = sizeOnDisk != 0 ? sizeOnDisk : uncompressed

            let blob = try read(at: oldOffset, count: bytesOnDisk)
            try out.write(contentsOf: blob)

            entry.putU32(UInt32(writeOffset & 0xFFFF_FFFF), at: 256)
            entry.putU16(UInt16((writeOffset >> 32) & 0xFFFF), at: 260)
            newTable.append(entry)
            writeOffset += bytesOnDisk
        }

        let newCompressed = try lz4BlockCompress(newTable)
        var listSection = Data()
        listSection.appendU32(UInt32(newTable.count / stride))
        listSection.appendU32(UInt32(newCompressed.count))
        listSection.append(newCompressed)
        try out.write(contentsOf: listSection)

        // Header: keep flags/priority/md5/numParts, update the list fields.
        var newHeader = header
        newHeader.putU64(UInt64(writeOffset), at: 8)
        newHeader.putU32(UInt32(8 + newCompressed.count), at: 16)
        try out.seek(toOffset: 0)
        try out.write(contentsOf: newHeader)
        return droppedCount
    }

    private static func lz4BlockCompress(_ input: Data) throws -> Data {
        guard !input.isEmpty else { throw FixError.lz4Failed }
        let capacity = input.count + 4096
        var dst = Data(count: capacity)
        let written = dst.withUnsafeMutableBytes { d -> Int in
            input.withUnsafeBytes { s -> Int in
                compression_encode_buffer(
                    d.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    s.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_LZ4_RAW)
            }
        }
        guard written > 0 else { throw FixError.lz4Failed }
        dst.removeSubrange(written ..< dst.count)
        return dst
    }
}

// MARK: - Little-endian writes

extension Data {
    mutating func putU16(_ v: UInt16, at offset: Int) {
        self[offset] = UInt8(v & 0xFF); self[offset + 1] = UInt8(v >> 8)
    }
    mutating func putU32(_ v: UInt32, at offset: Int) {
        for i in 0..<4 { self[offset + i] = UInt8((v >> (8 * i)) & 0xFF) }
    }
    mutating func putU64(_ v: UInt64, at offset: Int) {
        for i in 0..<8 { self[offset + i] = UInt8((v >> (8 * i)) & 0xFF) }
    }
    mutating func appendU32(_ v: UInt32) {
        append(contentsOf: (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) })
    }
}
