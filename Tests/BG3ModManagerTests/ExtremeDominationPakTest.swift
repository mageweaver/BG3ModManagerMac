import XCTest
@testable import BG3ModManagerMac

final class ExtremeDominationPakTest: XCTestCase {
    func testNewModParses() throws {
        let pak = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Larian Studios/Baldur's Gate 3/Mods/ExtremeDomination.pak")
        guard FileManager.default.fileExists(atPath: pak.path) else { throw XCTSkip("not installed") }
        XCTAssertTrue(PakReader.isArchive(pak))
        XCTAssertEqual(PakReader.partCount(of: pak), 1)
        let names = PakReader.fileNames(from: pak)
        XCTAssertEqual(names.count, 5)
        let metaData = try PakReader.extractMetaLSX(from: pak)
        let meta = try XCTUnwrap(MetaParser.parse(metaData))
        print("ED-PARSE: name=\(meta.name) uuid=\(meta.uuid) folder=\(meta.folder) v64=\(meta.version64) se=\(meta.requiresScriptExtender)")
        XCTAssertEqual(meta.name, "Extreme Domination")
        XCTAssertEqual(meta.folder, "ExtremeDomination")
        let lua = try PakReader.extractFile(from: pak) { $0.hasSuffix("bootstrapserver.lua") }
        XCTAssertTrue(String(decoding: lua, as: UTF8.self).contains("StatusApplied"))
    }
}
