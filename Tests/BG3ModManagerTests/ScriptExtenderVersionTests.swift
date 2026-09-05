import XCTest
@testable import BG3ModManagerMac

/// The Script Extender tab's version line: reading `LC_ID_DYLIB` out of a
/// dylib, comparing release tags, and the install record for older releases.
final class ScriptExtenderVersionTests: XCTestCase {

    // MARK: Mach-O fixtures

    private func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24)] }
    private func be32(_ v: UInt32) -> [UInt8] { le32(v).reversed() }

    /// A 64-bit dylib header whose only load command is LC_ID_DYLIB.
    private func thinDylib(currentVersion: UInt32, leadingCommands: Int = 0) -> Data {
        var cmds: [UInt8] = []
        // Some unrelated commands first (LC_UUID-shaped, 24 bytes) to prove we walk, not peek.
        for _ in 0..<leadingCommands {
            cmds += le32(0x1b) + le32(24) + [UInt8](repeating: 0xab, count: 16)
        }
        let name: [UInt8] = Array("@rpath/libbg3se.dylib".utf8) + [0]
        let padded = name + [UInt8](repeating: 0, count: (8 - name.count % 8) % 8)
        let idSize = UInt32(24 + padded.count)
        cmds += le32(0x0d) + le32(idSize) + le32(24) + le32(2) + le32(currentVersion) + le32(0) + padded

        var header: [UInt8] = []
        header += le32(0xfeedfacf)          // MH_MAGIC_64
        header += le32(0x0100000c)          // CPU_TYPE_ARM64
        header += le32(0)                   // cpusubtype
        header += le32(6)                   // MH_DYLIB
        header += le32(UInt32(leadingCommands + 1))
        header += le32(UInt32(cmds.count))
        header += le32(0)                   // flags
        header += le32(0)                   // reserved
        return Data(header + cmds)
    }

    private func fat(_ slices: [Data]) -> Data {
        let entry = 20
        var offset = 8 + entry * slices.count
        offset = (offset + 0x3fff) & ~0x3fff              // page-align like lipo does
        var header = be32(0xcafebabe) + be32(UInt32(slices.count))
        var body: [UInt8] = []
        var cursor = offset
        for slice in slices {
            header += be32(0x01000007) + be32(3) + be32(UInt32(cursor)) + be32(UInt32(slice.count)) + be32(14)
            body += [UInt8](slice) + [UInt8](repeating: 0, count: (0x4000 - slice.count % 0x4000) % 0x4000)
            cursor += slice.count + (0x4000 - slice.count % 0x4000) % 0x4000
        }
        let pad = [UInt8](repeating: 0, count: offset - header.count)
        return Data(header + pad + body)
    }

    private func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macho-\(UUID().uuidString)")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: LC_ID_DYLIB

    func testReadsStampedVersionFromThinDylib() throws {
        let packed: UInt32 = 0 << 16 | 47 << 8 | 2
        XCTAssertEqual(MachOVersion.read(at: try write(thinDylib(currentVersion: packed))), "0.47.2")
        XCTAssertEqual(MachOVersion.read(at: try write(thinDylib(currentVersion: packed, leadingCommands: 3))), "0.47.2")
    }

    func testUnstampedDylibReadsAsUnknown() throws {
        XCTAssertNil(MachOVersion.read(at: try write(thinDylib(currentVersion: 0))),
                     "the linker default 0.0.0 says nothing about the build")
    }

    func testWalksFatSlices() throws {
        let packed: UInt32 = 1 << 16 | 2 << 8 | 3
        let universal = fat([thinDylib(currentVersion: packed), thinDylib(currentVersion: packed)])
        XCTAssertEqual(MachOVersion.read(at: try write(universal)), "1.2.3")

        // A first slice with nothing to say must not hide the second.
        let mixed = fat([thinDylib(currentVersion: 0), thinDylib(currentVersion: packed)])
        XCTAssertEqual(MachOVersion.read(at: try write(mixed)), "1.2.3")
    }

    func testRejectsThingsThatAreNotMachO() throws {
        XCTAssertNil(MachOVersion.read(at: try write(Data("not a dylib at all".utf8))))
        XCTAssertNil(MachOVersion.read(at: try write(Data())))
        XCTAssertNil(MachOVersion.read(at: try write(Data(thinDylib(currentVersion: 0x2f02).prefix(40)))),
                     "a header truncated inside its load commands is not a version")
        // A Java class file shares the fat magic; its "arch count" is a version in the thousands.
        XCTAssertNil(MachOVersion.read(at: try write(Data(be32(0xcafebabe) + be32(0) + be32(65)))))
        XCTAssertNil(MachOVersion.read(at: URL(fileURLWithPath: "/nonexistent/libbg3se.dylib")))
    }

    func testPackedFormat() {
        XCTAssertEqual(MachOVersion.format(0x00002f02), "0.47.2")
        XCTAssertEqual(MachOVersion.format(0x00010000), "1.0.0")
        XCTAssertEqual(MachOVersion.format(0x0400ffff), "1024.255.255")
        XCTAssertNil(MachOVersion.format(0))
    }

    /// The real thing, when this machine has it: whatever is in the game
    /// bundle either says nothing (a release before the stamp) or a version.
    func testInstalledExtenderReportsAWellFormedVersionIfAny() throws {
        guard let app = ScriptExtenderRelease.discoverGameApp(),
              FileManager.default.fileExists(atPath: ScriptExtenderRelease.dylibDestination(in: app).path)
        else { throw XCTSkip("no native game / extender on this machine") }
        if let v = MachOVersion.read(at: ScriptExtenderRelease.dylibDestination(in: app)) {
            XCTAssertNotNil(v.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression), v)
        }
    }

    // MARK: Tags and comparison

    func testTagsNormalise() {
        XCTAssertEqual(ScriptExtenderRelease.version(fromTag: "v0.47.2"), "0.47.2")
        XCTAssertEqual(ScriptExtenderRelease.version(fromTag: "0.47.2"), "0.47.2")
        XCTAssertEqual(ScriptExtenderRelease.version(fromTag: " V1.0.0\n"), "1.0.0")
    }

    func testNewerIsNumericNotLexical() {
        XCTAssertTrue(ScriptExtenderRelease.isNewer("v0.47.3", than: "0.47.2"))
        XCTAssertTrue(ScriptExtenderRelease.isNewer("0.47.10", than: "0.47.9"))
        XCTAssertTrue(ScriptExtenderRelease.isNewer("v0.48", than: "0.47.9"), "missing components read as 0")
        XCTAssertTrue(ScriptExtenderRelease.isNewer("1.0.0", than: "0.99.99"))
        XCTAssertFalse(ScriptExtenderRelease.isNewer("v0.47.2", than: "0.47.2"))
        XCTAssertFalse(ScriptExtenderRelease.isNewer("0.47.1", than: "0.47.2"))
        XCTAssertFalse(ScriptExtenderRelease.isNewer("v0.47.3-rc1", than: "0.47.2"), "malformed tags never nag")
        XCTAssertFalse(ScriptExtenderRelease.isNewer("latest", than: "0.47.2"))
    }

    // MARK: Install record

    func testInstallRecordMatchesOnlyTheFileItDescribes() {
        let now = Date()
        let record = ScriptExtenderRelease.InstallRecord(version: "0.47.2", bytes: 7_277_072, modifiedAt: now)
        XCTAssertTrue(record.matches(bytes: 7_277_072, modifiedAt: now.addingTimeInterval(0.4)),
                      "sub-second drift from filesystem timestamp granularity is the same file")
        XCTAssertFalse(record.matches(bytes: 7_277_072, modifiedAt: now.addingTimeInterval(120)),
                       "a rewritten file is not the release we installed")
        XCTAssertFalse(record.matches(bytes: 7_307_376, modifiedAt: now))
        XCTAssertFalse(ScriptExtenderRelease.InstallRecord(version: "0.47.2", bytes: 0, modifiedAt: now)
                        .matches(bytes: 0, modifiedAt: now), "an empty record never matches")
    }

    func testInstallRecordRoundTripsThroughDefaults() {
        let suite = "ScriptExtenderVersionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(ScriptExtenderRelease.InstallRecord.load(from: defaults))

        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        ScriptExtenderRelease.InstallRecord(version: "0.47.2", bytes: 42, modifiedAt: stamp).save(to: defaults)
        XCTAssertEqual(ScriptExtenderRelease.InstallRecord.load(from: defaults),
                       ScriptExtenderRelease.InstallRecord(version: "0.47.2", bytes: 42, modifiedAt: stamp))

        ScriptExtenderRelease.InstallRecord.clear(from: defaults)
        XCTAssertNil(ScriptExtenderRelease.InstallRecord.load(from: defaults))
    }
}
