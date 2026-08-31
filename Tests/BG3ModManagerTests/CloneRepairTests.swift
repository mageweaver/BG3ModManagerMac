import XCTest
@testable import BG3ModManagerMac

/// v1.3.0 semantics against real paks: reference-aware scanning and clone
/// repair with MaterialID re-stamping. Skip cleanly when fixtures are absent.
final class CloneRepairTests: XCTestCase {
    private var materialsPak: URL? {
        guard let app = ScriptExtenderRelease.discoverGameApp() else { return nil }
        let pak = app.appendingPathComponent("Contents/Data/Materials.pak")
        return FileManager.default.fileExists(atPath: pak.path) ? pak : nil
    }
    private func modsPak(_ name: String) -> URL? {
        let u = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Larian Studios/Baldur's Gate 3/Mods/\(name)")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func testFacesOfFaerunIgnoresUnreferencedAndFixes() throws {
        guard let pak = modsPak("aloija_new_heads_8c611d4b-75d9-2n1j.pak"),
              let materials = materialsPak else { throw XCTSkip("fixtures absent") }
        let r = try XCTUnwrap(ShaderCompatFixer.scan(pakURL: pak, materialsPak: materials))
        print("FOF: affected=\(r.affected) fixable=\(r.fixable) broken=\(r.brokenMaterials.map(\.baseName))")
        XCTAssertTrue(r.affected)
        XCTAssertEqual(r.brokenMaterials.count, 1, "unreferenced clone must be ignored")
        XCTAssertTrue(r.fixable)

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("clonerepair-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let copy = work.appendingPathComponent(pak.lastPathComponent)
        try fm.copyItem(at: pak, to: copy)
        let rc = try XCTUnwrap(ShaderCompatFixer.scan(pakURL: copy, materialsPak: materials))
        try ShaderCompatFixer.fix(rc, backupDir: work.appendingPathComponent("bk"), materialsPak: materials)
        let after = try XCTUnwrap(ShaderCompatFixer.scan(pakURL: copy, materialsPak: materials))
        XCTAssertFalse(after.affected, "fixed pak must scan clean")
    }

    func testZ4hr4ClonesRepairWithIdRestamp() throws {
        guard let pak = modsPak("Z4hr4_HeadPresets_837ce349-37f4-17cb-615e-6d87de019833.pak"),
              let materials = materialsPak else { throw XCTSkip("fixtures absent") }
        let r = try XCTUnwrap(ShaderCompatFixer.scan(pakURL: pak, materialsPak: materials))
        print("Z4HR4: affected=\(r.affected) fixable=\(r.fixable) partial=\(r.partiallyFixable) broken=\(r.brokenMaterials.count) custom=\(r.customMaterialCount)")
        XCTAssertTrue(r.affected)
        XCTAssertTrue(r.fixable || r.partiallyFixable)
        XCTAssertGreaterThan(r.brokenMaterials.filter { $0.cloneOfBasePath != nil }.count, 30)

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("clonerepair-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let copy = work.appendingPathComponent(pak.lastPathComponent)
        try fm.copyItem(at: pak, to: copy)
        let rc = try XCTUnwrap(ShaderCompatFixer.scan(pakURL: copy, materialsPak: materials))
        try ShaderCompatFixer.fix(rc, backupDir: work.appendingPathComponent("bk"), materialsPak: materials)

        // Every repaired clone: MetalReady AND still carries its own MaterialID.
        for m in rc.brokenMaterials where m.cloneOfBasePath != nil {
            let d = try PakReader.extractFile(from: copy) { $0 == m.path.lowercased() }
            XCTAssertNotNil(d.range(of: Data("MetalReady".utf8)), m.baseName)
            if let id = m.materialID {
                XCTAssertNotNil(d.range(of: Data(id.utf8)), "\(m.baseName) lost its MaterialID")
            }
        }
        let after = try XCTUnwrap(ShaderCompatFixer.scan(pakURL: copy, materialsPak: materials))
        print("Z4HR4 after: affected=\(after.affected) broken=\(after.brokenMaterials.count)")
        XCTAssertFalse(after.affected)
    }
}
