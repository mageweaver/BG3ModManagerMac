import XCTest
@testable import BG3ModManagerMac

final class CkHairShaderTest: XCTestCase {
    func testInstalledCkHairGetsCloneNamedMetalShaders() throws {
        let fm = FileManager.default
        // The ORIGINAL broken pak: the installed one is repaired in place, so
        // the durable fixture is the Mac Fix backup.
        let pak = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BG3ModManagerMac/ShaderFixBackups/ck_hair_collection_b5c10147-99-2czd.pak")
        guard fm.fileExists(atPath: pak.path),
              let app = ScriptExtenderRelease.discoverGameApp() else { throw XCTSkip("fixtures absent") }
        let materials = app.appendingPathComponent("Contents/Data/Materials.pak")

        // The installed pak has repaired materials but no clone-named Metal
        // shaders — the freeze the user just reproduced. Must scan affected.
        let r = try XCTUnwrap(ShaderCompatFixer.scan(pakURL: pak, materialsPak: materials))
        print("CK: affected=\(r.affected) missingMetal=\(r.missingMetalShaders.count) brokenMats=\(r.brokenMaterials.count)")
        XCTAssertTrue(r.affected, "clone-named DX shaders without Metal must count as broken")
        XCTAssertGreaterThan(r.missingMetalShaders.count, 10)

        // Fix a copy and verify the injected shaders resolve every stem.
        let work = fm.temporaryDirectory.appendingPathComponent("ck-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let copy = work.appendingPathComponent(pak.lastPathComponent)
        try fm.copyItem(at: pak, to: copy)
        let rc = try XCTUnwrap(ShaderCompatFixer.scan(pakURL: copy, materialsPak: materials))
        try ShaderCompatFixer.fix(rc, backupDir: work.appendingPathComponent("bk"), materialsPak: materials)

        let names = PakReader.fileNames(from: copy)
        for miss in rc.missingMetalShaders {
            let expected = (miss.dir.isEmpty ? "" : miss.dir + "/") + miss.stem + "_Metal.bshd"
            XCTAssertTrue(names.contains(expected), "missing injected \(expected)")
        }
        let after = try XCTUnwrap(ShaderCompatFixer.scan(pakURL: copy, materialsPak: materials))
        print("CK after: affected=\(after.affected) missingMetal=\(after.missingMetalShaders.count)")
        XCTAssertFalse(after.affected)
        // Injected payloads are real Metal shaders (BSHD magic).
        let sample = rc.missingMetalShaders[0]
        let d = try PakReader.extractFile(from: copy) {
            $0.hasSuffix("\(sample.stem.lowercased())_metal.bshd")
        }
        XCTAssertEqual(d.prefix(4), Data("BSHD".utf8))
    }
}
