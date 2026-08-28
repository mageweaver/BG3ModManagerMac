import Foundation

/// Script Extender support for the **CrossOver / Wine** route.
///
/// Inside a CrossOver bottle you are running the *Windows* build of BG3, so the *Windows* Script
/// Extender works — the same way it does under Proton on a Steam Deck. The loader is a `DWrite.dll`
/// proxy dropped next to `bg3.exe`, plus a Wine DLL override so the bottle loads the native (mod)
/// DWrite instead of the system one. This type handles that setup.
///
/// The native Mac build is handled separately by `ScriptExtenderMac` (BG3SE-macOS), which builds a
/// dylib and hooks it in through Steam's launch options rather than by injecting a DLL.
enum ScriptExtender {

    /// True if a pak ships Script Extender assets (a `ScriptExtender` folder / config inside it).
    static func pakReferencesScriptExtender(_ pak: URL) -> Bool {
        PakReader.fileNames(from: pak).contains { name in
            let n = name.lowercased()
            return n.contains("scriptextender") || n.contains("script extender")
                || n.hasSuffix("scriptextenderconfig.json")
        }
    }

    /// Official BG3 Script Extender (Norbyte) release page. The app opens this for the user to grab
    /// the loader; we deliberately do not hard-code a binary URL that could go stale or be spoofed.
    static let releasesPage = URL(string: "https://github.com/Norbyte/bg3se/releases")!

    enum SEError: LocalizedError {
        case notCrossOver
        case noGameBin
        case loaderMissing
        var errorDescription: String? {
            switch self {
            case .notCrossOver: return "Script Extender can only be installed into a CrossOver/Wine bottle."
            case .noGameBin:    return "Couldn't locate the BG3 game 'bin' folder inside this bottle. Set it in Settings."
            case .loaderMissing: return "The chosen file isn't a Script Extender loader (expected DWrite.dll)."
            }
        }
    }

    /// Install the SE loader (a user-provided `DWrite.dll` from the official release) into the bottle's
    /// game bin folder. Returns the destination path. Caller is still responsible for adding the Wine
    /// DLL override `dwrite=native,builtin` (see `wineOverrideInstructions`).
    @discardableResult
    static func installLoader(_ loader: URL, into env: GameEnvironment) throws -> URL {
        guard env.kind == .crossOver else { throw SEError.notCrossOver }
        guard let bin = env.gameBinFolder else { throw SEError.noGameBin }
        guard loader.lastPathComponent.lowercased() == "dwrite.dll" else { throw SEError.loaderMissing }

        let fm = FileManager.default
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let dest = bin.appendingPathComponent("DWrite.dll")
        if fm.fileExists(atPath: dest.path) {
            let backup = bin.appendingPathComponent("DWrite.dll.bak")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: dest, to: backup)
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: loader, to: dest)
        return dest
    }

    static let wineOverrideInstructions = """
    To finish enabling the Script Extender in CrossOver:
    1. Open CrossOver → select this bottle → Run Command / Wine Configuration (winecfg).
    2. Go to the Libraries tab and add a new override for "dwrite".
    3. Set it to "Native (Windows), then Built-in" and apply.
    4. Launch BG3 from inside the bottle. The Script Extender console confirms it loaded.

    Without this override Wine uses its own dwrite and the Script Extender will not start.
    """
}
