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
        let metalReady: Bool        // the material carries the MetalReady marker
        let basePath: String?       // base-game material path for a same-name override
        /// A MaterialBank actually loads this file (SourceFile). Unreferenced
        /// materials are toolkit export leftovers and are ignored entirely.
        let referenced: Bool
        /// The base material this is a clone of (its .lsf path in the base
        /// game), when the name is `<BaseName>_<suffix>`. Clones are repaired
        /// with the base payload, re-stamped with the clone's own MaterialID.
        let cloneOfBasePath: String?
        /// This material can be repaired: it is a same-name base override or a
        /// clone of a base material. Only referenced, non-MetalReady materials
        /// matter for fixing.
        var repairable: Bool { basePath != nil || cloneOfBasePath != nil }
        var broken: Bool { referenced && !metalReady }
    }

    struct MissingShader {
        let stem: String        // e.g. CHAR_Hair_<uuid>_STI_DEF
        let dir: String         // pak directory holding this shader family
        let baseStem: String    // base-game stem whose Metal build stands in
    }

    struct ScanResult: Identifiable {
        var id: String { pakURL.path }
        let pakURL: URL
        let displayName: String
        let shaderCount: Int
        let platforms: Set<String>
        let materials: [MaterialInfo]
        /// Shader families shipped DX-only whose names have no Metal build
        /// anywhere (in-pak or base game): the engine derives shader names
        /// from the registered material name, so clone-named materials need
        /// clone-named Metal shaders injected. Empty when nothing is missing.
        let missingMetalShaders: [MissingShader]

        /// Carries a REFERENCED material the Mac renderer will refuse:
        /// exported by the Windows toolkit (no MetalReady marker), typically
        /// alongside DX11/DX12/Vulkan-only compiled shaders. Unreferenced
        /// leftovers do not count.
        var affected: Bool {
            (shaderCount > 0 && !platforms.contains("Metal")
                && materials.contains(where: \.broken))
            || !missingMetalShaders.isEmpty
        }
        var brokenMaterials: [MaterialInfo] { materials.filter(\.broken) }
        /// Every broken material can be repaired (base override or clone).
        var fixable: Bool {
            affected && brokenMaterials.allSatisfy(\.repairable)
        }
        // missingMetalShaders are always fixable (base Metal bytecode stands in).
        /// Some broken materials are repairable, some are truly novel —
        /// fixing helps but the novel ones stay broken.
        var partiallyFixable: Bool {
            affected && !fixable && brokenMaterials.contains(where: \.repairable)
        }
        /// Truly novel broken materials: no base counterpart exists at all.
        var customMaterialCount: Int {
            brokenMaterials.filter { !$0.repairable }.count
        }
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

    /// Base-game indexes from Materials.pak: material basename -> path, and
    /// the set of shader stems that have a Metal build (plus their paths).
    struct BaseIndex {
        var materials: [String: String] = [:]      // basename.lsf -> path
        var metalShaders: [String: String] = [:]   // stem -> path of _Metal.bshd
    }

    private static func baseMaterialIndex(materialsPak: URL) -> BaseIndex {
        var index = BaseIndex()
        for name in PakReader.fileNames(from: materialsPak) {
            if name.hasSuffix(".lsf") {
                let base = (name as NSString).lastPathComponent
                if index.materials[base] == nil { index.materials[base] = name }
            } else if name.hasSuffix("_Metal.bshd") {
                let base = (name as NSString).lastPathComponent
                let stem = String(base.dropLast("_Metal.bshd".count))
                if index.metalShaders[stem] == nil { index.metalShaders[stem] = name }
            }
        }
        return index
    }

    /// Printable-ASCII runs in a binary blob (LSF string tables store plain bytes).
    private static func asciiStrings(in data: Data, minLength: Int = 10) -> [String] {
        var out: [String] = []
        var run: [UInt8] = []
        for b in data {
            if b >= 0x20 && b < 0x7F { run.append(b) }
            else {
                if run.count >= minLength { out.append(String(decoding: run, as: UTF8.self)) }
                run.removeAll(keepingCapacity: true)
            }
        }
        if run.count >= minLength { out.append(String(decoding: run, as: UTF8.self)) }
        return out
    }

    /// Material paths a pak's MaterialBanks actually load (SourceFile refs).
    /// Returned lowercased, both full paths and basenames.
    private static func referencedMaterials(pakURL: URL) -> Set<String> {
        let banks = PakReader.extractAll(from: pakURL) {
            $0.hasSuffix(".lsf") && $0.contains("/content/")
        }
        var refs: Set<String> = []
        let marker = Data("MaterialBank".utf8)
        for (_, d) in banks where d.range(of: marker) != nil {
            for str in asciiStrings(in: d) {
                let lower = str.lowercased()
                if lower.hasSuffix(".lsf"), lower.contains("/materials/") {
                    refs.insert(lower)
                    refs.insert((lower as NSString).lastPathComponent)
                }
            }
        }
        return refs
    }

    /// The base-game material this file is a clone of, when named
    /// `<BaseName>_<suffix>`. Longest base name wins so `CHAR_Skin_Head_v3`
    /// beats `CHAR_Skin_Head` for `CHAR_Skin_Head_v3_<uuid>`.
    private static func cloneBase(for baseName: String, in index: [String: String]) -> String? {
        let stem = (baseName as NSString).deletingPathExtension
        var best: (name: String, path: String)? = nil
        for (b, path) in index {
            let bstem = (b as NSString).deletingPathExtension
            guard stem.hasPrefix(bstem + "_") else { continue }
            if best == nil || bstem.count > ((best!.name as NSString).deletingPathExtension).count {
                best = (b, path)
            }
        }
        return best?.path
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
                     baseIndex: BaseIndex? = nil,
                     externalRefs: Set<String> = []) -> ScanResult? {
        guard PakReader.isArchive(pakURL), PakReader.partCount(of: pakURL) == 1 else { return nil }
        let names = PakReader.fileNames(from: pakURL)
        guard !names.isEmpty else { return nil }

        var platforms: Set<String> = []
        var shaderCount = 0
        var materialPaths: [String] = []
        var shaderStems: Set<String> = []      // name minus _<platform>.bshd
        var metalStems: Set<String> = []       // stems that have a Metal build in-pak
        var shaderDirs: [String: String] = [:] // stem -> directory in the pak
        for n in names {
            if n.hasSuffix(".bshd") {
                shaderCount += 1
                for p in ["DX11", "DX12", "Vulkan", "Metal"] where n.hasSuffix("_\(p).bshd") {
                    platforms.insert(p)
                    let base = (n as NSString).lastPathComponent
                    let stem = String(base.dropLast(p.count + 6))  // _<p>.bshd
                    shaderStems.insert(stem)
                    shaderDirs[stem] = (n as NSString).deletingLastPathComponent
                    if p == "Metal" { metalStems.insert(stem) }
                }
            } else if n.hasSuffix(".lsf"), n.contains("/Materials/") {
                materialPaths.append(n)
            }
        }

        var materials: [MaterialInfo] = []
        var missing: [MissingShader] = []
        let index = materialsPak.map { baseIndex ?? baseMaterialIndex(materialsPak: $0) }
        if let index {
            // The engine derives shader names from the registered material
            // name: a clone material `CHAR_Hair_<uuid>` requests
            // `CHAR_Hair_<uuid>_STI_DEF_Metal.bshd`, which exists nowhere —
            // proven live: repairing the material payload alone still froze.
            // Derive each clone's variant list from its own shipped DX
            // shaders and pair it with the base material's Metal build.
            for matPath in materialPaths {
                let matName = ((matPath as NSString).lastPathComponent as NSString)
                    .deletingPathExtension
                if index.materials[matName + ".lsf"] != nil { continue }  // base-named: base Metal covers it
                guard let basePath = cloneBase(for: matName + ".lsf", in: index.materials) else { continue }
                let baseName = (((basePath as NSString).lastPathComponent) as NSString)
                    .deletingPathExtension
                for stem in shaderStems where stem.hasPrefix(matName + "_") {
                    if metalStems.contains(stem) { continue }             // already injected
                    let variant = String(stem.dropFirst(matName.count))   // includes leading _
                    let donor = baseName + variant
                    if index.metalShaders[donor] != nil {
                        missing.append(MissingShader(stem: stem,
                                                     dir: shaderDirs[stem] ?? "",
                                                     baseStem: donor))
                    }
                    // No donor (e.g. _ST_BAKE editor variants): skip.
                }
            }
        }
        if shaderCount > 0 && !platforms.contains("Metal"), let materialsPak, let index {
            let refs = referencedMaterials(pakURL: pakURL).union(externalRefs)
            for path in materialPaths {
                let base = (path as NSString).lastPathComponent
                var overrides = false
                var modID: String? = nil
                var metalReady = false
                let basePath = index.materials[base]
                let referenced = refs.contains(path.lowercased())
                    || refs.contains(base.lowercased())
                if let modData = try? PakReader.extractFile(from: pakURL,
                                                            matching: { $0 == path.lowercased() }) {
                    metalReady = modData.range(of: Data("MetalReady".utf8)) != nil
                    modID = extractMaterialID(fromLSF: modData)
                    if let basePath,
                       let baseData = try? PakReader.extractFile(from: materialsPak,
                                                                  matching: { $0 == basePath.lowercased() }) {
                        let baseID = extractMaterialID(fromLSF: baseData)
                        overrides = (modID != nil && modID == baseID)
                    }
                }
                // Same-name file with a different UUID still repairs like an
                // override (base payload, re-stamped with the mod's own ID) —
                // handled through cloneOfBasePath when overrides is false.
                let clonePath: String? = basePath != nil && !overrides
                    ? basePath
                    : cloneBase(for: base, in: index.materials)
                materials.append(MaterialInfo(path: path, baseName: base,
                                              materialID: modID, overridesBaseGame: overrides,
                                              metalReady: metalReady,
                                              basePath: overrides ? basePath : nil,
                                              referenced: referenced,
                                              cloneOfBasePath: clonePath))
            }
        }

        // Editor bake variants never run at runtime; do not count them.
        missing.removeAll { $0.stem.hasSuffix("_ST_BAKE") }
        return ScanResult(pakURL: pakURL,
                          displayName: pakURL.deletingPathExtension().lastPathComponent,
                          shaderCount: shaderCount,
                          platforms: platforms,
                          materials: materials,
                          missingMetalShaders: missing)
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
        let index: BaseIndex? = materialsPak.map { baseMaterialIndex(materialsPak: $0) }
        // Materials are sometimes hosted in one pak (a shader/asset framework)
        // and referenced from another mod's banks, so references are collected
        // across the whole folder before any pak is judged.
        var allRefs: Set<String> = []
        for pak in paks {
            allRefs.formUnion(referencedMaterials(pakURL: pak))
        }
        var results: [ScanResult] = []
        for (i, pak) in paks.enumerated() {
            progress?(i + 1, paks.count)
            if let r = scan(pakURL: pak, materialsPak: materialsPak, baseIndex: index,
                            externalRefs: allRefs),
               r.affected {
                results.append(r)
            }
        }
        return results.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // MARK: - Fix

    /// Repair a pak in place. Every referenced, non-MetalReady material that
    /// has a base-game counterpart is replaced at its own path:
    ///   - same-name overrides get the base payload verbatim;
    ///   - clones (`<BaseName>_<suffix>.lsf`) get the base payload with the
    ///     clone's own MaterialID stamped back in (same-length ASCII GUID
    ///     substitution), so by-ID references keep resolving.
    /// Nothing is ever removed; truly novel materials are left untouched (a
    /// partial fix reduces the blast radius but cannot invent Metal shaders).
    /// The original pak is backed up first; the rewrite is validated before it
    /// replaces anything. Returns the backup location.
    @discardableResult
    static func fix(_ result: ScanResult, backupDir: URL, materialsPak: URL) throws -> URL {
        precondition(result.fixable || result.partiallyFixable,
                     "fix() needs at least one repairable material")
        let fm = FileManager.default
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let index = baseMaterialIndex(materialsPak: materialsPak)

        // Clone-named shader families need Metal builds under their own names;
        // the base game's Metal bytecode for the same family stands in (the
        // mods' DX copies are byte-identical recompiles of base).
        var additions: [(path: String, data: Data)] = []
        for miss in result.missingMetalShaders {
            guard let donorPath = index.metalShaders[miss.baseStem],
                  let payload = try? PakReader.extractFile(from: materialsPak,
                                                            matching: { $0 == donorPath.lowercased() })
            else {
                throw FixError.verifyFailed("no base Metal shader for \(miss.stem)")
            }
            let dir = miss.dir.isEmpty ? "" : miss.dir + "/"
            additions.append((path: "\(dir)\(miss.stem)_Metal.bshd", data: payload))
        }

        var replacements: [String: Data] = [:]   // lowercased pak path -> payload
        var stamped: [String: String] = [:]      // path -> MaterialID expected after fix
        for m in result.brokenMaterials where m.repairable {
            let sourceBase = m.basePath ?? m.cloneOfBasePath!
            guard var payload = try? PakReader.extractFile(from: materialsPak,
                                                            matching: { $0 == sourceBase.lowercased() }),
                  payload.range(of: Data("MetalReady".utf8)) != nil else {
                throw FixError.verifyFailed("no MetalReady base material for \(m.baseName)")
            }
            if m.basePath == nil {
                // Clone: keep the clone's identity so by-ID references hold.
                guard let cloneID = m.materialID,
                      let baseID = extractMaterialID(fromLSF: payload),
                      cloneID.count == baseID.count else {
                    throw FixError.verifyFailed("cannot re-stamp MaterialID for \(m.baseName)")
                }
                if cloneID != baseID {
                    payload = replacingASCII(in: payload, occurrencesOf: baseID, with: cloneID)
                    stamped[m.path.lowercased()] = cloneID
                }
            }
            replacements[m.path.lowercased()] = payload
        }
        guard !replacements.isEmpty || !additions.isEmpty else {
            throw FixError.verifyFailed("nothing repairable")
        }

        let tmp = result.pakURL.deletingLastPathComponent()
            .appendingPathComponent(".\(result.pakURL.lastPathComponent).macfix.tmp")
        defer { try? fm.removeItem(at: tmp) }

        try rewrite(src: result.pakURL, dst: tmp,
                    replacing: { replacements[$0.lowercased()] },
                    adding: additions)

        let newNames = PakReader.fileNames(from: tmp)
        guard newNames.count == PakReader.fileNames(from: result.pakURL).count + additions.count,
              !newNames.isEmpty else { throw FixError.verifyFailed("file table size mismatch") }
        for a in additions {
            guard newNames.contains(where: { $0 == a.path }) else {
                throw FixError.verifyFailed("injected shader missing: \(a.path)")
            }
        }
        let hadMeta = (try? PakReader.extractMetaLSX(from: result.pakURL)) != nil
        if hadMeta, (try? PakReader.extractMetaLSX(from: tmp)) == nil {
            throw FixError.verifyFailed("meta.lsx unreadable after rewrite")
        }
        for (path, _) in replacements {
            guard let d = try? PakReader.extractFile(from: tmp, matching: { $0 == path }),
                  d.range(of: Data("MetalReady".utf8)) != nil else {
                throw FixError.verifyFailed("replacement did not take for \(path)")
            }
            if let want = stamped[path],
               d.range(of: Data(want.utf8)) == nil {
                throw FixError.verifyFailed("MaterialID re-stamp missing for \(path)")
            }
        }

        let backup = backupDir.appendingPathComponent(result.pakURL.lastPathComponent)
        if !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: result.pakURL, to: backup)
        }
        _ = try fm.replaceItemAt(result.pakURL, withItemAt: tmp)
        return backup
    }

    /// Same-length ASCII substring substitution over binary data.
    private static func replacingASCII(in data: Data, occurrencesOf old: String,
                                       with new: String) -> Data {
        precondition(old.count == new.count)
        var out = data
        let oldB = Data(old.utf8), newB = Data(new.utf8)
        var searchStart = out.startIndex
        while let r = out.range(of: oldB, in: searchStart ..< out.endIndex) {
            out.replaceSubrange(r, with: newB)
            searchStart = r.upperBound
        }
        return out
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

    /// Rebuild an LSPK v18 pak, substituting the payload of any entry for
    /// which `replacing` returns data (stored uncompressed at the same path).
    /// All other payloads are copied byte-for-byte; only offsets, the sizes of
    /// replaced entries, and the header's file-list fields change.
    private static func rewrite(src: URL, dst: URL,
                                replacing: (String) -> Data?,
                                adding: [(path: String, data: Data)] = []) throws {
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
        try out.write(contentsOf: Data(count: 40))

        var newTable = Data()
        newTable.reserveCapacity(table.count)
        var writeOffset = 40

        for i in 0..<numFiles {
            let base = i * stride
            var entry = table.subdata(in: base ..< base + stride)
            let name = entry.readCString(at: 0, maxLen: 256)

            let blob: Data
            if let replacement = replacing(name) {
                blob = replacement
                entry[263] = 0                                   // stored
                entry.putU32(UInt32(replacement.count), at: 264) // size on disk
                entry.putU32(UInt32(replacement.count), at: 268) // uncompressed
            } else {
                let oldOffset = Int(UInt64(entry.readU32(at: 256)) | (UInt64(entry.readU16(at: 260)) << 32))
                let sizeOnDisk = Int(entry.readU32(at: 264))
                let uncompressed = Int(entry.readU32(at: 268))
                let bytesOnDisk = sizeOnDisk != 0 ? sizeOnDisk : uncompressed
                blob = try read(at: oldOffset, count: bytesOnDisk)
            }
            try out.write(contentsOf: blob)
            entry.putU32(UInt32(writeOffset & 0xFFFF_FFFF), at: 256)
            entry.putU16(UInt16((writeOffset >> 32) & 0xFFFF), at: 260)
            newTable.append(entry)
            writeOffset += blob.count
        }

        for add in adding {
            guard add.path.utf8.count <= 255 else { throw FixError.corrupt }
            try out.write(contentsOf: add.data)
            var entry = Data(count: 272)
            let nameBytes = Array(add.path.utf8)
            entry.replaceSubrange(0 ..< nameBytes.count, with: nameBytes)
            entry.putU32(UInt32(writeOffset & 0xFFFF_FFFF), at: 256)
            entry.putU16(UInt16((writeOffset >> 32) & 0xFFFF), at: 260)
            entry[263] = 0                                   // stored
            entry.putU32(UInt32(add.data.count), at: 264)
            entry.putU32(UInt32(add.data.count), at: 268)
            newTable.append(entry)
            writeOffset += add.data.count
        }

        let newCompressed = try lz4BlockCompress(newTable)
        var listSection = Data()
        listSection.appendU32(UInt32(numFiles + adding.count))
        listSection.appendU32(UInt32(newCompressed.count))
        listSection.append(newCompressed)
        try out.write(contentsOf: listSection)

        var newHeader = header
        newHeader.putU64(UInt64(writeOffset), at: 8)
        newHeader.putU32(UInt32(8 + newCompressed.count), at: 16)
        try out.seek(toOffset: 0)
        try out.write(contentsOf: newHeader)
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
