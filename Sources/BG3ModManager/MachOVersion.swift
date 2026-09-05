import Foundation

/// Reads the version a dylib carries in its own header — the `current version`
/// of its `LC_ID_DYLIB` load command, the field `otool -L` prints.
///
/// BG3SE-macOS stamps `BG3SE_VERSION` there (builds after v0.47.2), so the
/// Script Extender tab can say which build is installed without launching the game,
/// and without shelling out to `otool` — that needs the Xcode command-line
/// tools, which most people who install a mod manager do not have.
///
/// Only the header and load commands are read; a 7 MB dylib costs one small
/// read. Universal (fat) files are walked slice by slice and the first slice
/// that carries a version wins — every slice of one build carries the same.
enum MachOVersion {

    /// The dylib's `LC_ID_DYLIB` current version as "X.Y.Z", or nil when the
    /// file is not a Mach-O dylib, or its version is the linker default 0.0.0.
    static func read(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Fat header + arch table, or a thin header + all load commands, both
        // sit well inside the first 64 KB.
        guard let head = try? handle.read(upToCount: 64 * 1024), !head.isEmpty else { return nil }

        if let slices = fatSlices(in: head) {
            for slice in slices {
                guard (try? handle.seek(toOffset: slice.offset)) != nil,
                      let data = try? handle.read(upToCount: Int(min(slice.size, 64 * 1024))),
                      let version = read(thin: data) else { continue }
                return version
            }
            return nil
        }
        return read(thin: head)
    }

    /// Parse a thin (single-architecture) Mach-O image held in `data`.
    static func read(thin data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count >= 32 else { return nil }

        // Magic decides endianness and header size. The game and the extender
        // are 64-bit only, but the 32-bit header costs nothing to accept.
        let magic = u32(bytes, 0, bigEndian: false)
        let is64: Bool
        let bigEndian: Bool
        switch magic {
        case 0xfeedfacf: is64 = true;  bigEndian = false   // MH_MAGIC_64
        case 0xcffaedfe: is64 = true;  bigEndian = true    // MH_CIGAM_64
        case 0xfeedface: is64 = false; bigEndian = false   // MH_MAGIC
        case 0xcefaedfe: is64 = false; bigEndian = true    // MH_CIGAM
        default: return nil
        }

        let ncmds = Int(u32(bytes, 16, bigEndian: bigEndian))
        var cursor = is64 ? 32 : 28
        for _ in 0..<ncmds {
            guard cursor + 8 <= bytes.count else { return nil }
            let cmd = u32(bytes, cursor, bigEndian: bigEndian)
            let cmdsize = Int(u32(bytes, cursor + 4, bigEndian: bigEndian))
            guard cmdsize >= 8 else { return nil }
            if cmd == 0x0d {                                // LC_ID_DYLIB
                // struct dylib_command { cmd, cmdsize, dylib { name(4), timestamp(4),
                //                        current_version(4), compatibility_version(4) } }
                guard cursor + 24 <= bytes.count else { return nil }
                let packed = u32(bytes, cursor + 16, bigEndian: bigEndian)
                return format(packed)
            }
            cursor += cmdsize
        }
        return nil
    }

    /// `X.Y.Z` from the packed `xxxx.yy.zz` form, nil for the unset 0.0.0.
    static func format(_ packed: UInt32) -> String? {
        guard packed != 0 else { return nil }
        return "\(packed >> 16).\((packed >> 8) & 0xff).\(packed & 0xff)"
    }

    // MARK: Fat files

    struct Slice { var offset: UInt64; var size: UInt64 }

    /// The slices of a universal file, or nil when `data` is not a fat header.
    /// Fat headers are always big-endian.
    static func fatSlices(in data: Data) -> [Slice]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { return nil }
        let magic = u32(bytes, 0, bigEndian: true)
        let wide: Bool
        switch magic {
        case 0xcafebabe: wide = false   // FAT_MAGIC: 32-bit offsets
        case 0xcafebabf: wide = true    // FAT_MAGIC_64
        default: return nil
        }
        let count = Int(u32(bytes, 4, bigEndian: true))
        // A Java class file starts with the same magic; its "arch count" is a
        // version number in the thousands. Real fat files have a handful.
        guard count > 0, count <= 16 else { return nil }

        let entry = wide ? 32 : 20
        var slices: [Slice] = []
        for i in 0..<count {
            let base = 8 + i * entry
            guard base + entry <= bytes.count else { return nil }
            if wide {
                slices.append(Slice(offset: u64(bytes, base + 8), size: u64(bytes, base + 16)))
            } else {
                slices.append(Slice(offset: UInt64(u32(bytes, base + 8, bigEndian: true)),
                                    size: UInt64(u32(bytes, base + 12, bigEndian: true))))
            }
        }
        return slices
    }

    // MARK: Byte readers (bounds are checked by the callers)

    private static func u32(_ b: [UInt8], _ at: Int, bigEndian: Bool) -> UInt32 {
        let v = UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
        return bigEndian ? v.byteSwapped : v
    }

    private static func u64(_ b: [UInt8], _ at: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(b[at + i]) }   // big-endian, fat headers only
        return v
    }
}
