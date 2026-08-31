import XCTest
@testable import BG3ModManagerMac

final class SyncMD5Tests: XCTestCase {
    private let fixture = """
    <?xml version="1.0" encoding="UTF-8"?>
    <save>
        <region id="ModuleSettings">
            <node id="root"><children><node id="Mods"><children>
                        <node id="ModuleShortDesc">
                            <attribute id="Folder" type="LSString" value="GustavX"/>
                            <attribute id="MD5" type="LSString" value="aaaa"/>
                            <attribute id="Name" type="LSString" value="GustavX"/>
                            <attribute id="UUID" type="guid" value="cb555efe-2d9e-131f-8195-a89329d218ea"/>
                        </node>
                        <node id="ModuleShortDesc">
                            <attribute id="Folder" type="LSString" value="SomeMod"/>
                            <attribute id="MD5" type="LSString" value="oldmd5"/>
                            <attribute id="Name" type="LSString" value="Some Mod"/>
                            <attribute id="UUID" type="guid" value="11111111-2222-3333-4444-555555555555"/>
                        </node>
            </children></node></children></node>
        </region>
    </save>
    """

    func testSyncTargetsOnlyTheMatchingEntry() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("syncmd5-\(UUID().uuidString).lsx")
        try fixture.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(ModSettings.syncMD5(moduleUUID: "11111111-2222-3333-4444-555555555555",
                                          md5: "newmd5value", in: url))
        let out = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(out.contains("value=\"newmd5value\""))
        XCTAssertFalse(out.contains("oldmd5"))
        XCTAssertTrue(out.contains("value=\"aaaa\""), "other entries untouched")
        // idempotent + unknown uuid refused
        XCTAssertTrue(ModSettings.syncMD5(moduleUUID: "11111111-2222-3333-4444-555555555555",
                                          md5: "newmd5value", in: url))
        XCTAssertFalse(ModSettings.syncMD5(moduleUUID: "99999999-0000-0000-0000-000000000000",
                                           md5: "x", in: url))
    }
}
