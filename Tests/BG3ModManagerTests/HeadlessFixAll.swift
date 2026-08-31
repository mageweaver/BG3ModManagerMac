import XCTest
@testable import BG3ModManagerMac

/// One-shot headless Fix All against the real Mods folder. Guarded by env var
/// so it never runs as part of the normal suite.
final class HeadlessFixAll: XCTestCase {
    func testFixAllFixable() throws {
        guard ProcessInfo.processInfo.environment["RUN_FIX_ALL"] == "1" else {
            throw XCTSkip("set RUN_FIX_ALL=1 to run")
        }
        let mods = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Larian Studios/Baldur's Gate 3/Mods")
        let app = try XCTUnwrap(ScriptExtenderRelease.discoverGameApp())
        let materials = app.appendingPathComponent("Contents/Data/Materials.pak")
        let backups = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BG3ModManagerMac/ShaderFixBackups", isDirectory: true)

        let results = ShaderCompatFixer.scanFolder(mods, materialsPak: materials)
        for r in results where r.affected {
            if r.fixable {
                do {
                    try ShaderCompatFixer.fix(r, backupDir: backups, materialsPak: materials)
                    print("FIXALL: FIXED \(r.displayName)")
                } catch {
                    print("FIXALL: FAILED \(r.displayName): \(error.localizedDescription)")
                }
            } else {
                print("FIXALL: FLAGGED \(r.displayName) (custom materials: \(r.customMaterialCount))")
            }
        }
    }
}
