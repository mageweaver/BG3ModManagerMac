import XCTest
@testable import BG3ModManagerMac

/// Validates the shader-compat scanner and the LSPK v18 writer against real
/// paks on this machine. Fixture-dependent tests skip cleanly when the fixture
/// (a real mod pak or the base game) is absent, so the suite is safe anywhere.
final class ShaderCompatFixerTests: XCTestCase {

    private var materialsPak: URL? {
        guard let app = ScriptExtenderRelease.discoverGameApp() else { return nil }
        let pak = app.appendingPathComponent("Contents/Data/Materials.pak")
        return FileManager.default.fileExists(atPath: pak.path) ? pak : nil
    }

    /// The pre-fix Bloodletter pak: 1836 files, 90 DX/Vulkan-only shaders, two
    /// material overrides both matching base-game MaterialIDs.
    private var bloodletterOriginal: URL? {
        let candidates = [
            FileManager.default.temporaryDirectory.appendingPathComponent("Veilyn_ORIGINAL_BACKUP.pak"),
            URL(fileURLWithPath: ProcessInfo.processInfo.environment["BLOODLETTER_FIXTURE"] ?? "/nonexistent"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func testScanFindsWindowsOnlyShaders() throws {
        guard let pak = bloodletterOriginal else { throw XCTSkip("fixture not present") }
        let result = try XCTUnwrap(ShaderCompatFixer.scan(pakURL: pak, materialsPak: materialsPak))
        XCTAssertEqual(result.shaderCount, 90)
        XCTAssertEqual(result.platforms, ["DX11", "DX12", "Vulkan"])
        XCTAssertTrue(result.affected)
        XCTAssertEqual(result.materials.count, 2)
    }

    func testScanClassifiesBaseOverridesAsFixable() throws {
        guard let pak = bloodletterOriginal else { throw XCTSkip("fixture not present") }
        guard materialsPak != nil else { throw XCTSkip("base game not present") }
        let result = try XCTUnwrap(ShaderCompatFixer.scan(pakURL: pak, materialsPak: materialsPak))
        for m in result.materials {
            XCTAssertNotNil(m.materialID, "\(m.baseName) should yield a MaterialID")
            XCTAssertTrue(m.overridesBaseGame, "\(m.baseName) should match its base-game UUID")
        }
        XCTAssertTrue(result.fixable)
    }

    func testFixRewritesAValidPak() throws {
        guard let pak = bloodletterOriginal else { throw XCTSkip("fixture not present") }
        guard materialsPak != nil else { throw XCTSkip("base game not present") }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("shaderfix-test-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // Fix a scratch copy, never the fixture.
        let copy = work.appendingPathComponent(pak.lastPathComponent)
        try fm.copyItem(at: pak, to: copy)
        let result = try XCTUnwrap(ShaderCompatFixer.scan(pakURL: copy, materialsPak: materialsPak))
        let backupDir = work.appendingPathComponent("backups")
        try ShaderCompatFixer.fix(result, backupDir: backupDir)

        // The rewritten pak parses, lost exactly the shader set, and kept its identity.
        let names = PakReader.fileNames(from: copy)
        XCTAssertEqual(names.count, 1836 - 92)
        XCTAssertFalse(names.contains { $0.hasSuffix(".bshd") })
        XCTAssertFalse(names.contains { $0.hasSuffix("CHAR_Hair.lsf") })
        let meta = try PakReader.extractMetaLSX(from: copy)
        XCTAssertTrue(String(decoding: meta, as: UTF8.self)
            .contains("9c2fcd63-823c-0dcb-71ff-cb60e9ff00f7"))

        // Every surviving payload is still byte-identical: spot-check story.div.osi.
        let story = try PakReader.extractFile(from: copy) { $0.hasSuffix("story.div.osi") }
        XCTAssertEqual(story.count, 33_059_447)

        // The backup is the untouched original.
        let backup = backupDir.appendingPathComponent(pak.lastPathComponent)
        XCTAssertEqual(try fm.attributesOfItem(atPath: backup.path)[.size] as? Int,
                       try fm.attributesOfItem(atPath: pak.path)[.size] as? Int)

        // And a fixed pak scans as no longer affected.
        let rescanned = try XCTUnwrap(ShaderCompatFixer.scan(pakURL: copy, materialsPak: materialsPak))
        XCTAssertFalse(rescanned.affected)

        // Restore puts the original back.
        try ShaderCompatFixer.restore(pakURL: copy, backupDir: backupDir)
        XCTAssertEqual(PakReader.fileNames(from: copy).count, 1836)
    }
}

/// Full-folder scan against the real Mods directory on this machine —
/// validates parity with the reference Python scan (54 affected mods,
/// 2026-08-29) and reports fixability. Skips when the folder is absent.
final class ShaderCompatFolderScanTests: XCTestCase {
    func testRealFolderScanParity() throws {
        let mods = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Larian Studios/Baldur's Gate 3/Mods")
        guard FileManager.default.fileExists(atPath: mods.path) else { throw XCTSkip("no Mods folder") }
        guard let app = ScriptExtenderRelease.discoverGameApp() else { throw XCTSkip("no game") }
        let materials = app.appendingPathComponent("Contents/Data/Materials.pak")

        let results = ShaderCompatFixer.scanFolder(mods, materialsPak: materials)
        let affected = results.filter(\.affected)
        let fixable = affected.filter(\.fixable)
        print("SCAN-PARITY: affected=\(affected.count) fixable=\(fixable.count)")
        for r in affected {
            let mark = r.fixable ? "FIXABLE" : "flagged(custom:\(r.customMaterialCount))"
            print("SCAN-PARITY:   \(r.displayName) [\(r.shaderCount)sh/\(r.materials.count)mat] \(mark)")
        }
        // The Bloodletter pak was already fixed in place, so it no longer counts.
        XCTAssertGreaterThanOrEqual(affected.count, 50)
        XCTAssertLessThanOrEqual(affected.count, 54)
    }
}
