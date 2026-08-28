# BG3 Mod Manager for Mac

A native macOS (SwiftUI) mod manager for **Baldur's Gate 3** that works with both
**Nexus Mods** and **mod.io**, manages your load order by writing `modsettings.lsx`
directly, and — crucially — understands the difference between the **native Mac build**
and **BG3 running inside CrossOver**.

> **Script Extender — now on native macOS.** There's a native-macOS Script Extender,
> [**BG3SE-macOS**](https://github.com/mageweaver/bg3se-macos), and this app installs it
> for you with one click from its **Script Extender** tab — it downloads the pre-built
> `libbg3se.dylib` straight into the game, no Terminal and no building. (Running the
> **Windows** build of BG3 in **CrossOver**? The **Windows** Script Extender still works
> there too, and the app installs that as well.)

---

## What it does

- **Detects your installs automatically** — the native Mac build *and* any CrossOver/Wine
  bottles that contain BG3 — and lets you switch between them.
- **Reads each `.pak`** (Larian's LSPK format) to pull the mod's name, UUID, version and
  dependencies straight out of `meta.lsx`. No guessing from filenames.
- **Manages the load order** with drag-to-reorder, writing a correct `modsettings.lsx`
  (and backing up the previous one every time).
- **Browses & installs from mod.io** (search + one-click download) and **Nexus Mods**
  (trending/latest feeds + download), auto-extracting `.pak` files from `.zip` archives.
- **Flags Script Extender mods.** On the native Mac build they're marked clearly as
  incompatible instead of silently failing. In a CrossOver bottle, it offers to install the
  SE loader for you.
- **Detects file conflicts.** Scans your enabled load order for mods that ship the same in-game
  file and shows which mod wins (the one lower in the order) and which it overrides.
- **Auto-sorts by dependencies.** One click reorders the load order so every mod loads after the
  dependencies it declares in `meta.lsx` — a stable sort that leaves unrelated mods where they were,
  and reports dependency cycles or missing dependencies.
- **Saves load-order profiles.** Snapshot the current enabled mods + order under a name and switch
  between profiles any time (e.g. a "story" build vs. a "chaos" build). Stored as JSON in
  Application Support, and **exportable/importable as a file** so you can share a load order.
- **Health panel with one-click fixes.** A dedicated tab that checks the whole load order at once for
  missing dependencies, dependencies that are installed-but-disabled, dependencies that load too late,
  and SE-incompatible mods. Each issue has a fix button (enable the dependency, auto-sort, disable the
  mod, or copy the missing UUID), plus a **Fix all auto-resolvable** button.

---

## Download (no building required)

Grab the app from the [**releases page**](https://github.com/mageweaver/BG3ModManagerMac/releases/latest)
— a universal build (Apple Silicon + Intel). It's ad-hoc signed, not notarized, so on first
launch either **right-click → Open → Open**, or clear quarantine:

```bash
xattr -dr com.apple.quarantine "/path/to/BG3 Mod Manager.app"
```

Then see the [Tutorial](docs/TUTORIAL.md). To build from source instead, read on.

## Requirements

- macOS 13 (Ventura) or newer
- Xcode 15+ (free) to build — this is source you compile into a `.app`
- A BG3 install: native Mac build, **or** the Windows build in CrossOver/Wine
- (Optional) a free **mod.io** API key and/or a **Nexus** API key for in-app browsing

## Build & run

The project is a Swift Package, so the easiest path is:

```bash
cd BG3ModManagerMac
open Package.swift      # opens in Xcode
# press ▶ Run
```

Or from the command line:

```bash
swift run
```

### Make a double-clickable `.app` (with `nxm://` working)

Two supported ways, both giving a real app bundle that registers the `nxm://` scheme:

**A. One command, no extra tools** — uses the included `build_app.sh`:

```bash
cd BG3ModManagerMac
chmod +x build_app.sh        # first time only
./build_app.sh               # → "BG3 Mod Manager.app" in this folder
open "BG3 Mod Manager.app"
```

It compiles with SwiftPM, assembles the `.app` around `Info.plist`, ad-hoc-signs it, and registers
the `nxm://` handler with LaunchServices.

**B. A proper Xcode project** — uses the included `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
cd BG3ModManagerMac
xcodegen generate
open BG3ModManagerMac.xcodeproj   # Run/Debug in Xcode; .app registers nxm:// too
```

Prefer **A** to just get the app, **B** to develop in Xcode.

> If macOS blocks file access, grant the app **Files and Folders / Full Disk Access** in
> System Settings → Privacy & Security (it needs to read your `Documents` and, for CrossOver,
> the bottle folders).

---

> **New here?** See the step-by-step [**Tutorial**](docs/TUTORIAL.md).

## Using it

1. **Pick your install** in the top bar. CrossOver bottles are labelled `CrossOver · <bottle>`.
2. **Load Order tab** — toggle mods on/off; drag the active list to reorder (top loads first).
   Every change writes `modsettings.lsx` immediately, with a timestamped backup. Use **Auto-sort**
   to order by declared dependencies, and the **Profiles** menu to save the current order or switch
   to a saved one. The Profiles menu also **imports/exports** a profile as a shareable `.json`.
3. **Health tab** — one place to see every dependency/compatibility problem in the load order, each
   with a fix hint. Re-checks automatically whenever the order changes.
4. **Browse tab** — search mod.io or pull Nexus trending, then **Install** to download +
   unpack the `.pak` into your Mods folder.
5. **Script Extender tab** — environment-aware guidance and, under CrossOver, a one-click
   loader install.
6. **Settings tab** — paste your API keys and, if auto-detection missed your install, point
   the app at a custom "Baldur's Gate 3" folder (and game `bin` folder for SE).

### API keys

| Source | Search? | Direct download? | Key |
|--------|---------|------------------|-----|
| **mod.io** | ✅ full text | ✅ free public key | mod.io → *My account → Access* |
| **Nexus** | ⚠️ feeds only (no API text search) | ⚠️ Premium, or browser `nxm://` handoff for free accounts | Nexus → *Account → API Keys* |

Nexus's public API deliberately has no full-text search and gates direct download links behind
Premium — those are Nexus platform limits, not app limits. mod.io is the smoother of the two.

### `nxm://` download handoff (free Nexus accounts)

On any mod's Nexus page, the green **"Mod Manager Download"** button fires an `nxm://` link. This app
registers itself as a handler for that scheme, so clicking it hands the download straight to the app —
parsed by `NXMLink.swift`, resolved via the short-lived `key`/`expires` token (which is exactly what
lets **free** accounts download through a manager), then unpacked and installed automatically.

This requires the app to be built as a real `.app` bundle so macOS can register the scheme:

- **Xcode:** add `Info.plist` to your App target (or Target → Info → **URL Types** → add scheme `nxm`).
  The provided `Info.plist` already contains the `CFBundleURLTypes` entry.
- After first launch, macOS routes `nxm://baldursgate3/...` links to the app. If you run multiple
  managers, your browser may ask which one to open the link with.
- A bare `swift run` executable won't receive `nxm` links (no bundle to register) — use an app target.

---

## Script Extender — the full story

The BG3 Script Extender (Norbyte's `bg3se`) is **not a normal mod**. It injects itself into the
running game process and hooks the game's internal functions and the Osiris engine *in memory*,
then exposes a Lua API on top. A native-macOS port would require:

- reverse-engineering the macOS BG3 binary (a totally different Mach-O/ARM build, with different,
  undocumented function offsets than Windows);
- a code-injection + function-hooking layer that defeats **System Integrity Protection**, the
  **hardened runtime**, and **code signing** — exactly the things Apple builds to *prevent* this;
- re-doing all of it on every game patch.

That's why it doesn't exist. This app does **not** pretend to ship one.

**What works instead:** under CrossOver you're running the *Windows* game, so the *Windows* SE
loads — the same approach Linux/Steam Deck players use under Proton. The loader is a `DWrite.dll`
proxy placed next to `bg3.exe`, plus a Wine library override so the bottle loads it:

1. **Script Extender tab → Open SE releases**, download the latest release.
2. **Choose DWrite.dll…** — the app copies it into the bottle's game `bin` folder (backing up any
   existing `DWrite.dll`).
3. In **CrossOver → your bottle → winecfg → Libraries**, add an override for `dwrite` set to
   *Native, then Built-in*.
4. Launch BG3 from inside the bottle; the SE console confirms it loaded.

---

## How it's organised

```
Sources/BG3ModManager/
  App.swift            App entry / window
  AppState.swift       ObservableObject the UI binds to; all disk-mutating actions
  Environment.swift    Detects native + CrossOver installs; resolves all BG3 paths
  Models.swift         Mod, ModMeta, RemoteMod
  PakReader.swift      LSPK (.pak) reader — extracts meta.lsx (LZ4/zlib via Apple Compression)
  MetaParser.swift     Parses meta.lsx → ModMeta (incl. SE dependency detection)
  ModSettings.swift    Reads/writes modsettings.lsx (the load order), with backups
  ModRepository.swift  Scan / install / delete / apply-order; reconciles disk ↔ load order
  ScriptExtender.swift SE detection + CrossOver loader install
  NexusClient.swift    Nexus Mods API client
  ModIOClient.swift    mod.io API client
  NXMLink.swift        Parses nxm:// download links from the Nexus website
  ConflictDetector.swift  Finds mods that ship the same in-game files; resolves the winner by load order
  HealthChecker.swift     Whole-order dependency + compatibility checks with fix hints
  LoadOrderSorter.swift   Stable topological sort of the load order by declared dependencies
  ProfileStore.swift      Saves/loads + exports/imports named load-order profiles (JSON)
  Downloader.swift     Download + unzip → .pak files
  Views.swift          Load order, browse, health, conflicts, profiles, status bar UI
  SettingsViews.swift  Settings + Script Extender UI

Info.plist             Registers the nxm:// URL scheme (used by build_app.sh and the Xcode target)
build_app.sh           One-command SwiftPM → .app bundler that registers the nxm:// handler
project.yml            XcodeGen spec → generates a real .xcodeproj app target
```

## Known limits / nice next steps

- `.rar`/`.7z` archives aren't auto-extracted (only `.zip` and bare `.pak`). Unpack manually,
  then **Add .pak**.
- The LSPK reader targets v18 (current BG3) with v15/16 fallbacks; extremely old paks may not parse.
- `nxm://` handoff is supported (see above) — it just needs the app built as an `.app` bundle so macOS
  registers the scheme.
- The conflict detector lists v18 paks' files; very old (v15/16) paks aren't enumerated for conflicts.
  It flags *file overlaps*, not semantic conflicts (e.g. two mods editing the same stats entry inside
  different files) — those still need in-game testing.

## Disclaimer

Community tool, not affiliated with Larian, Nexus Mods, mod.io, or CodeWeavers. Modding edits game
files at your own risk — the app backs up `modsettings.lsx` before each write, but keep your own
saves backed up too.
