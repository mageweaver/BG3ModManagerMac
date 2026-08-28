import Foundation
import Compression

/// Minimal reader for Larian's LSPK (.pak) archive format.
///
/// We only need one thing out of a pak: `mods/<Folder>/meta.lsx`, which carries the mod's UUID,
/// name, version and dependencies. So this reader parses the file list, finds the meta entry, and
/// decompresses just that one file. It supports LSPK v15/v16/v18 (the versions BG3 ships).
enum PakReader {

    enum PakError: Error { case notLSPK, unsupportedVersion(UInt32), corrupt, metaNotFound, fileNotFound }

    /// Random-access view over a .pak on disk. We never map or read the whole archive — the file list
    /// lives near the end and each payload sits at a known offset, so extracting `meta.lsx` costs a
    /// handful of small reads (header + file list + one payload) regardless of pak size. That's the
    /// difference between touching a few KB and reading a 400 MB pak just to find its meta.
    private struct PakFile {
        let handle: FileHandle
        let size: Int

        init(_ url: URL) throws {
            handle = try FileHandle(forReadingFrom: url)
            size = Int(try handle.seekToEnd())
        }

        /// Read exactly `count` bytes at `offset`, or throw `.corrupt` if that range isn't fully present.
        func read(at offset: Int, count: Int) throws -> Data {
            guard count >= 0, offset >= 0, offset + count <= size else { throw PakError.corrupt }
            guard count > 0 else { return Data() }
            try handle.seek(toOffset: UInt64(offset))
            guard let d = try handle.read(upToCount: count), d.count == count else { throw PakError.corrupt }
            return d
        }

        func close() { try? handle.close() }
    }

    /// Read and return the raw bytes of `meta.lsx` from a pak, or throw.
    static func extractMetaLSX(from pakURL: URL) throws -> Data {
        try extractFile(from: pakURL) { $0.hasSuffix("/meta.lsx") || $0 == "meta.lsx" }
    }

    /// Read one file out of an LSPK archive, chosen by its path.
    ///
    /// Savegames (`.lsv`) are LSPK archives too, so the same reader that pulls a mod's `meta.lsx`
    /// pulls a save's `SaveInfo.json` — no separate format handling needed.
    static func extractFile(from pakURL: URL, matching: (String) -> Bool) throws -> Data {
        let file = try PakFile(pakURL)
        defer { file.close() }
        guard file.size > 8 else { throw PakError.corrupt }

        // Magic "LSPK" + version.
        let header = try file.read(at: 0, count: 8)
        guard header[0] == 0x4C, header[1] == 0x53, header[2] == 0x50, header[3] == 0x4B else {
            throw PakError.notLSPK
        }
        let version = header.readU32(at: 4)
        switch version {
        case 18: return try extractV18(file, matching: matching)
        case 15, 16: return try extractV15or16(file, version: version, matching: matching)
        default: throw PakError.unsupportedVersion(version)
        }
    }

    /// Whether this file is a real archive rather than a continuation part.
    ///
    /// Larian splits a pak once it passes 4 GiB. Only the first file gets a header; the rest are raw
    /// payload named `Name_1.pak`, `Name_2.pak`, … so they fail every check a pak reader makes. They
    /// are not mods and must not be listed as such, but the game does need them in the Mods folder.
    static func isArchive(_ pakURL: URL) -> Bool {
        guard let file = try? PakFile(pakURL), file.size >= 8 else { return false }
        defer { file.close() }
        guard let header = try? file.read(at: 0, count: 4) else { return false }
        return header[0] == 0x4C && header[1] == 0x53 && header[2] == 0x50 && header[3] == 0x4B
    }

    /// How many files this archive is split across, from its own header — 1 when it isn't split.
    ///
    /// This is why a missing part can be reported precisely rather than guessed at: the pak states
    /// how many pieces it expects. v15 predates the field, so it always reads as unsplit.
    static func partCount(of pakURL: URL) -> Int {
        guard let file = try? PakFile(pakURL), file.size >= 40 else { return 1 }
        defer { file.close() }
        guard let header = try? file.read(at: 0, count: 40),
              header[0] == 0x4C, header[1] == 0x53, header[2] == 0x50, header[3] == 0x4B else { return 1 }
        let version = header.readU32(at: 4)
        guard version == 16 || version == 18 else { return 1 }
        return max(1, Int(header.readU16(at: 38)))
    }

    /// List every file path inside a pak (best-effort; supports v18, the format BG3 mods ship in).
    /// Used to detect Script Extender assets without fully unpacking.
    static func fileNames(from pakURL: URL) -> [String] {
        guard let file = try? PakFile(pakURL), file.size > 8 else { return [] }
        defer { file.close() }
        guard let header = try? file.read(at: 0, count: 8),
              header[0] == 0x4C, header[1] == 0x53, header[2] == 0x50, header[3] == 0x4B,
              header.readU32(at: 4) == 18,
              let table = try? readFileTable(file, entryStride: 272) else { return [] }

        let numFiles = table.count / 272
        return (0..<numFiles).map { table.readCString(at: $0 * 272, maxLen: 256) }
    }

    // MARK: file-list table

    /// Seek to the file-list header (`fileListOffset` U64 at byte 8 for every LSPK version we support),
    /// read the LZ4-compressed entry table, and decompress it to `numFiles * entryStride` bytes.
    private static func readFileTable(_ file: PakFile, entryStride: Int) throws -> Data {
        let listPtr = try file.read(at: 8, count: 8)
        let fileListOffset = Int(listPtr.readU64(at: 0))

        let counts = try file.read(at: fileListOffset, count: 8)
        let numFiles = Int(counts.readU32(at: 0))
        let compressedSize = Int(counts.readU32(at: 4))
        let listStart = fileListOffset + 8
        guard numFiles >= 0, compressedSize >= 0 else { throw PakError.corrupt }

        let compressed = try file.read(at: listStart, count: min(compressedSize, file.size - listStart))
        let decompressedSize = numFiles * entryStride
        let table = try lz4BlockDecompress(compressed, expectedSize: decompressedSize)
        guard table.count >= decompressedSize else { throw PakError.corrupt }
        return table
    }

    // MARK: v18 (current BG3)

    // Header (after magic+version): fileListOffset U64, fileListSize U32, flags U8, priority U8,
    // md5[16], numParts U16.
    private static func extractV18(_ file: PakFile, matching: (String) -> Bool) throws -> Data {
        let entryStride = 256 + 4 + 2 + 1 + 1 + 4 + 4   // = 272 bytes (FileEntry18)
        let table = try readFileTable(file, entryStride: entryStride)
        let numFiles = table.count / entryStride

        for i in 0..<numFiles {
            let base = i * entryStride
            let name = table.readCString(at: base, maxLen: 256)
            guard matching(name.lowercased()) else { continue }

            let offset1 = UInt64(table.readU32(at: base + 256))
            let offset2 = UInt64(table.readU16(at: base + 260))
            // base + 262 is ArchivePart (multi-part paks); BG3 mod paks are single-part, so part == 0.
            let realOffset = Int(offset1 | (offset2 << 32))
            let flags   = table[base + 263]
            let sizeOnDisk = Int(table.readU32(at: base + 264))
            let uncompressed = Int(table.readU32(at: base + 268))

            // On-disk footprint is SizeOnDisk when set; some stored entries leave it 0 and put the
            // real length in UncompressedSize. Compressed entries always use SizeOnDisk.
            let bytesOnDisk = sizeOnDisk != 0 ? sizeOnDisk : uncompressed
            let raw = try file.read(at: realOffset, count: bytesOnDisk)
            return try decompressPayload(raw, uncompressed: uncompressed, flags: flags)
        }
        throw PakError.metaNotFound
    }

    // MARK: v15 / v16 (older). Layout differs slightly; entry is 292 bytes with a 256-byte name.
    private static func extractV15or16(_ file: PakFile, version: UInt32, matching: (String) -> Bool) throws -> Data {
        // FileEntry15/16: Name[256], OffsetInFile U64, SizeOnDisk U64, UncompressedSize U64, ArchivePart U32, Flags U32, Crc U32
        let entryStride = 256 + 8 + 8 + 8 + 4 + 4 + 4   // = 292
        let table = try readFileTable(file, entryStride: entryStride)

        let numFiles = table.count / entryStride
        for i in 0..<numFiles {
            let base = i * entryStride
            guard base + entryStride <= table.count else { break }
            let name = table.readCString(at: base, maxLen: 256)
            guard matching(name.lowercased()) else { continue }
            let offset = Int(table.readU64(at: base + 256))
            let sizeOnDisk = Int(table.readU64(at: base + 264))
            let uncompressed = Int(table.readU64(at: base + 272))
            let flags = UInt8(table.readU32(at: base + 284) & 0xFF)
            let bytesOnDisk = sizeOnDisk != 0 ? sizeOnDisk : uncompressed
            let raw = try file.read(at: offset, count: bytesOnDisk)
            return try decompressPayload(raw, uncompressed: uncompressed, flags: flags)
        }
        throw PakError.metaNotFound
    }

    // MARK: payload decompression

    private static func decompressPayload(_ raw: Data, uncompressed: Int, flags: UInt8) throws -> Data {
        let method = flags & 0x0F        // 0 = none, 1 = zlib, 2 = lz4
        switch method {
        case 0:
            return raw
        case 1:
            return try zlibDecompress(raw, expectedSize: uncompressed)
        case 2:
            return try lz4BlockDecompress(raw, expectedSize: uncompressed)
        default:
            // Unknown: assume stored.
            return raw
        }
    }

    // MARK: compression helpers (Apple Compression framework)

    /// Raw LZ4 *block* format — exactly what LSPK uses. Apple's COMPRESSION_LZ4_RAW matches this.
    static func lz4BlockDecompress(_ input: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        return try decode(input, expectedSize: expectedSize, algorithm: COMPRESSION_LZ4_RAW)
    }

    /// Raw DEFLATE (zlib without header) — COMPRESSION_ZLIB is raw deflate in Apple's framework.
    static func zlibDecompress(_ input: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        // LSPK zlib entries include the 2-byte zlib header; strip it for COMPRESSION_ZLIB (raw deflate).
        let body = (input.count > 2 && input[0] == 0x78) ? input.subdata(in: 2 ..< input.count) : input
        return try decode(body, expectedSize: expectedSize, algorithm: COMPRESSION_ZLIB)
    }

    private static func decode(_ input: Data, expectedSize: Int,
                               algorithm: compression_algorithm) throws -> Data {
        var result = Data(count: expectedSize)
        let written = result.withUnsafeMutableBytes { dst -> Int in
            input.withUnsafeBytes { src -> Int in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, algorithm)
            }
        }
        guard written > 0 else { throw PakError.corrupt }
        if written != expectedSize { result.removeSubrange(written ..< result.count) }
        return result
    }
}

// MARK: - Little-endian reads

extension Data {
    func readU16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }
    func readU32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16) | (UInt32(self[offset + 3]) << 24)
    }
    func readU64(at offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(self[offset + i]) << (8 * i) }
        return v
    }
    func readCString(at offset: Int, maxLen: Int) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(maxLen)
        for i in 0..<maxLen {
            let b = self[offset + i]
            if b == 0 { break }
            bytes.append(b)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
