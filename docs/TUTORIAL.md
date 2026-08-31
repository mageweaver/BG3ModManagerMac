# BG3 Mod Manager for Mac — how to use it

A walkthrough from download to a modded game with the Script Extender
running. If you just want the Script Extender, jump to [§4](#4-install-the-script-extender-one-click).

## 0. Download & open

Grab the app from the [releases page](https://github.com/mageweaver/BG3ModManagerMac/releases/latest)
(universal — Apple Silicon and Intel, macOS 13+). Unzip, and move
**BG3 Mod Manager.app** to `/Applications` if you like.

The app is ad-hoc signed, **not notarized**, so macOS blocks the very first
open with *"from an unidentified developer."* That's expected. Either:

- **Right-click the app → Open → Open** (needed once; afterwards it opens
  normally), or
- clear the quarantine flag in Terminal:
  ```bash
  xattr -dr com.apple.quarantine "/Applications/BG3 Mod Manager.app"
  ```

## 1. First launch

Open **BG3 Mod Manager**. On launch it scans for Baldur's Gate 3 installs and
lists what it finds:

- **Native macOS** — the Mac build from Steam (or the Mac App Store).
- **CrossOver / Wine** — the Windows build running in a bottle.

If you have both, pick which one you're managing from the environment switcher
at the top. Everything below applies to the selected install.

> Nothing is written until you make a change. Browsing is safe.

## 2. See your load order

The main list is your **load order** — the mods BG3 will load, top to bottom.
Each row is read straight from the mod's `.pak` (Larian's format), so the name,
version, UUID and dependencies are the real ones, not guesses from the filename.

- **Drag** rows to reorder. Order matters: a mod that depends on another must
  load after it.
- **Enable / disable** with the checkbox. Only enabled mods are written to
  `modsettings.lsx` and loaded by the game.
- **Search** filters by name; notes you add are searchable too.
- Rows with problems (a missing dependency, a duplicate, a load-order conflict)
  are flagged. Hover for the detail.

When it looks right, your changes are saved to `modsettings.lsx` — the same file
BG3 reads. Launch the game and the order takes effect.

## 3. Add mods

Two ways:

- **Nexus / mod.io in-app** — search, and download with a click. Free Nexus
  accounts use the `nxm://` handoff: you click *Mod Manager Download* on the
  Nexus website and it lands in the app (this needs the real `.app` build, not
  `swift run` — see the README).
- **Drop a file in** — drag a `.pak` or a `.zip` containing one onto the window.

New mods appear in the load order disabled; enable and position them.

> **API keys** (Settings): a Nexus API key unlocks in-app search and direct
> downloads. mod.io works without one for public mods. Keys are stored in your
> login keychain, not in the app's files.

## 4. Install the Script Extender (one-click)

Many popular mods — MCM, 5eSpells, Compatibility Framework — need the **Script
Extender**. On the native Mac build this is
[BG3SE-macOS](https://github.com/mageweaver/bg3se-macos), and the app installs
it for you.

1. Open the **Script Extender** tab.
2. Under **native macOS** you'll see **Install the Script Extender
   (recommended)**. Click **Download & Install**.
3. The app downloads the latest pre-built `libbg3se.dylib`, copies it into
   `Baldur's Gate 3.app`, and clears the Gatekeeper quarantine — the step that
   otherwise silently blocks the unsigned file. Watch progress in **View
   install log**.
4. When it turns green, launch BG3 **through Steam**. The game loads the
   extender on its own; there's nothing to paste into launch options.

> **Version note.** The extender targets a specific game build (shown on the
> button). If your BG3 is a different version, the extender loads but idles by
> design rather than risk your game — wait for a matching release.

Once it's green, enable your SE-dependent mods in the load order and launch.
MCM opens in-game via its keybind.

### If it doesn't load

- **Nothing in the install log / game ignores it** — re-run **Download &
  Install**; it re-clears quarantine.
- **"Couldn't find Baldur's Gate 3.app"** — install the game through Steam
  first, or set the path in Settings.
- **Game updated and SE went quiet** — a game update replaces the app bundle.
  Just click **Update / Reinstall**.

### Advanced: build from source

Below the one-click box is **build from source**, for developers who want to
compile BG3SE-macOS against the game binary themselves (or target a build no
release covers yet). It clones and builds the project and wires Steam's launch
options. Most people don't need this — the download is the same result.

## 5. Fix Windows-only mods (Mac Fix tab)

Many visual mods — hair, heads, armor, weapons — are built with the Windows
toolkit, which compiles their materials only for DirectX/Vulkan. The Mac build
renders with **Metal**, so the first time such a mod's content actually appears
(equipping the armor, meeting the companion, opening its head preset in
character creation) the game **hangs on a loading spinner**.

The **Mac Fix** tab finds these before they bite:

1. Click **Scan Installed Mods**. Every `.pak` in your Mods folder is checked
   for Windows-only compiled shaders.
2. Mods marked **safe to fix** override base-game materials — one click on
   **Fix** (or **Fix All**) replaces each broken material with the game's own
   Metal-ready version of the same material, keeping the mod's models and
   custom textures intact. The original pak is backed up automatically
   (`~/Library/Application Support/BG3ModManagerMac/ShaderFixBackups`), and
   **Restore Original** puts it back any time.
3. Cloned materials (per-preset copies of base materials, the usual pattern
   in head-preset packs) are repaired with the base version re-stamped with the
   clone's identity, and unused leftover materials are ignored. Only mods with
   truly custom shader frameworks are flagged red — they can't be auto-fixed
   until their author ships Metal shaders, and the scan names them so nothing
   hangs you by surprise. Mods where only some materials are custom get a
   partial fix that repairs everything repairable.

A game update or re-downloading a mod replaces the fixed pak — just scan and
fix again.

## 6. CrossOver (Windows BG3 in a bottle)

If you selected a CrossOver install, the Script Extender tab installs the
**Windows** Script Extender into the bottle instead — a different mechanism,
same one-click idea. The load order and mod management work identically.

## 7. Profiles and backups

- **Profiles** save named load-order sets — a heavy setup and a light one, say —
  and switch between them.
- **Backup / import** snapshots your current `modsettings.lsx` and load order so
  you can restore it after a game update resets things, or move it to another
  machine.

## Where things live

- Load order / enabled mods → `~/Documents/Larian Studios/Baldur's Gate 3/PlayerProfiles/Public/modsettings.lsx`
- Installed mods → `~/Documents/Larian Studios/Baldur's Gate 3/Mods/`
- Script Extender (native) → inside `Baldur's Gate 3.app/Contents/MacOS/`
- Script Extender logs → `~/Library/Application Support/BG3SE/logs/`

The app never touches your save files.
