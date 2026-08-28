import Foundation

/// Script Extender support for the **native macOS** build, via BG3SE-macOS.
///
/// This is a different mechanism from the Windows SE the app installs into a CrossOver bottle. There
/// is no DLL and nothing is copied into the game folder: BG3SE-macOS builds `libbg3se.dylib` from
/// source and loads it by wrapping the game's launch command, which is set in Steam's launch options
/// as `…/scripts/bg3w.sh %command%`. Nothing to install into the Mods folder, and nothing this app
/// can copy into place — so its job here is to find the checkout, report exactly which of the three
/// steps (cloned / built / wired into Steam) is done, and hand over the command to finish it.
///
/// Project: https://github.com/mageweaver/bg3se-macos
enum ScriptExtenderMac {

    static let repository = URL(string: "https://github.com/mageweaver/bg3se-macos")!

    /// A BG3SE-macOS checkout and how far along its setup is.
    struct Installation: Equatable {
        var root: URL
        /// `scripts/bg3w.sh` — the launcher Steam has to be pointed at.
        var launchScript: URL?
        /// `build/lib/libbg3se.dylib` — present only once the project has been built.
        var dylib: URL?
        var dylibBuiltAt: Date?
        var dylibBytes: Int64 = 0
        var isUniversal = false
        /// True when Steam's stored launch options already reference the launcher.
        var wiredIntoSteam = false

        var isBuilt: Bool { dylib != nil }
        var isReady: Bool { isBuilt && launchScript != nil && wiredIntoSteam }

        /// What the user pastes into Steam → BG3 → Properties → Launch Options.
        var launchOptions: String? {
            launchScript.map { "\($0.path) %command%" }
        }

        var stage: Stage {
            if !isBuilt { return .notBuilt }
            if !wiredIntoSteam { return .notWired }
            return .ready
        }

        enum Stage { case notBuilt, notWired, ready }
    }

    // MARK: Finding a checkout

    /// Places a checkout commonly ends up, tried in order. A path set in Settings always wins.
    private static var searchRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["bg3se-macos", "src/bg3se-macos", "src/BG3SE/macos-port", "Developer/bg3se-macos",
                "Documents/bg3se-macos", "code/bg3se-macos", "projects/bg3se-macos",
                "Claude/Projects/bg3se-macos"]
            .map { home.appendingPathComponent($0) }
    }

    /// Locate a usable checkout: the configured path first, then the usual spots.
    static func discover(configuredPath: String) -> Installation? {
        if !configuredPath.isEmpty, let found = inspect(URL(fileURLWithPath: configuredPath)) {
            return found
        }
        for root in searchRoots {
            if let found = inspect(root) { return found }
        }
        return nil
    }

    /// Read the state of a folder claimed to be a BG3SE-macOS checkout. Returns nil if it plainly
    /// isn't one — the launcher script and CMakeLists together are a good enough signature.
    static func inspect(_ root: URL) -> Installation? {
        let fm = FileManager.default
        let script = root.appendingPathComponent("scripts/bg3w.sh")
        let cmake = root.appendingPathComponent("CMakeLists.txt")
        guard fm.fileExists(atPath: script.path) || fm.fileExists(atPath: cmake.path) else { return nil }

        var install = Installation(root: root)
        if fm.fileExists(atPath: script.path) { install.launchScript = script }

        let dylib = root.appendingPathComponent("build/lib/libbg3se.dylib")
        if fm.fileExists(atPath: dylib.path) {
            install.dylib = dylib
            let values = try? dylib.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            install.dylibBuiltAt = values?.contentModificationDate
            install.dylibBytes = Int64(values?.fileSize ?? 0)
            install.isUniversal = isUniversalBinary(dylib)
        }
        install.wiredIntoSteam = steamLaunchOptionsReferenceLauncher()
        return install
    }

    // MARK: Steam wiring

    /// Whether any Steam account's stored launch options mention the BG3SE launcher.
    ///
    /// Steam keeps launch options in `localconfig.vdf`. Rather than parse VDF — a format with no
    /// stable schema across Steam versions — this looks for the launcher's filename, which appears
    /// nowhere else. It answers "did you paste it in", which is the step people forget.
    static func steamLaunchOptionsReferenceLauncher() -> Bool {
        for config in steamLocalConfigs() {
            if let text = try? String(contentsOf: config, encoding: .utf8), text.contains("bg3w.sh") {
                return true
            }
        }
        return false
    }

    private static func steamLocalConfigs() -> [URL] {
        let fm = FileManager.default
        let userdata = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam/userdata")
        guard let accounts = try? fm.contentsOfDirectory(at: userdata,
                                                         includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles]) else { return [] }
        return accounts.map { $0.appendingPathComponent("config/localconfig.vdf") }
                       .filter { fm.fileExists(atPath: $0.path) }
    }

    // MARK: Build guidance

    /// The commands that produce the dylib, ready to paste into Terminal.
    static func buildCommands(for root: URL) -> String {
        """
        cd \(root.path)
        git submodule update --init --recursive
        mkdir -p build && cd build
        cmake .. && cmake --build .
        """
    }

    /// Fat-header check, so the panel can say whether the build covers this Mac's architecture
    /// without shelling out to `file`.
    private static func isUniversalBinary(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic.count == 4 else { return false }
        // FAT_MAGIC / FAT_CIGAM, in either byte order.
        let bytes = [UInt8](magic)
        return bytes == [0xca, 0xfe, 0xba, 0xbe] || bytes == [0xbe, 0xba, 0xfe, 0xca]
    }
}
