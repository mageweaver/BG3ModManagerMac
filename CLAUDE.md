# CLAUDE.md — project context for Claude Code

A native macOS (SwiftUI) mod manager for **Baldur's Gate 3** that works with **Nexus Mods** and
**mod.io**, manages load order by writing `modsettings.lsx`, and is **CrossOver-aware**. Started in
Cowork; this file is the handoff so you can continue with full context.

## First task
I (the previous session) could NOT compile — no Swift/Xcode toolchain was available. So the very
first job is to **make it build** and fix any first-compile errors:

```bash
./build_app.sh            # SwiftPM → "BG3 Mod Manager.app", registers nxm:// handler
# or, to develop in Xcode:
brew install xcodegen && xcodegen generate && open BG3ModManagerMac.xcodeproj
```

Expect a few small fixes (SwiftUI API mismatches, optional-unwrap nits). The logic has been
reviewed by hand but not verified by a compiler.

## Build / run
- Swift Package (`Package.swift`), macOS 13+, single executable target `BG3ModManagerMac`.
- `swift run` works for quick runs, but `nxm://` handoff needs a real `.app` bundle — use
  `build_app.sh` or the XcodeGen project (`project.yml` + `Info.plist`).

## Architecture (Sources/BG3ModManager/)
- `App.swift` — `@main` app + window; `.onOpenURL` routes `nxm://` links to `AppState.handleNXM`.
- `AppState.swift` — `@MainActor ObservableObject`, single source of truth + all disk-mutating actions.
- `Environment.swift` — detects installs. Native Mac (`~/Documents/Larian Studios/Baldur's Gate 3`)
  AND CrossOver/Wine bottles (scans `.../CrossOver/Bottles/*/drive_c/...`). Resolves Mods folder,
  `modsettings.lsx`, and (CrossOver only) the game `bin` folder.
- `Models.swift` — `Mod`, `ModMeta`, `RemoteMod`.
- `PakReader.swift` — LSPK (.pak) reader; extracts `meta.lsx` and lists file names. LZ4/zlib via
  Apple's Compression framework (`COMPRESSION_LZ4_RAW`, `COMPRESSION_ZLIB`). Targets v18 with v15/16
  fallback for meta.
- `MetaParser.swift` — parses `meta.lsx` XML → `ModMeta` (name/uuid/folder/version/deps + SE flag).
- `ModSettings.swift` — reads/writes `modsettings.lsx` (the load order); backs up before each write;
  always keeps GustavDev base first.
- `ModRepository.swift` — scan/install/delete/apply-order; reconciles disk ↔ load order.
- `ScriptExtender.swift` — SE detection + CrossOver loader (`DWrite.dll`) install.
- `NexusClient.swift` — Nexus API (feeds + files + download link; no text search in public API).
- `ModIOClient.swift` — mod.io API (`@baldursgate3`, search + direct download).
- `NXMLink.swift` — parses `nxm://` deep links (key/expires token → free-account downloads).
- `Downloader.swift` — download + unzip → `.pak` files.
- `ConflictDetector.swift` — finds mods shipping the same in-game file; winner = lower in load order.
- `HealthChecker.swift` — whole-order dependency/compat checks, each with a `Resolution` for
  one-click fixes; `Report.hasAutoFixes` drives "Fix all auto-resolvable".
- `LoadOrderSorter.swift` — stable topological sort by declared dependencies.
- `ProfileStore.swift` — named load-order profiles (JSON in Application Support) + export/import.
- `Views.swift` / `SettingsViews.swift` — tabs: Load Order, Browse, Health, Conflicts,
  Script Extender, Settings.

## Key domain facts (don't regress these)
- **No native-macOS Script Extender is feasible** (SIP / hardened runtime / code signing block the
  memory injection SE needs). The ONLY path to SE on Mac is running the **Windows** BG3 in CrossOver;
  the app installs the Windows SE loader there. Keep this framing honest in UI + docs.
- Native Mac build: SE-dependent mods are flagged incompatible, not silently broken.
- Nexus public API: no full-text search; free accounts need the `nxm://` website handoff for
  downloads. mod.io is the smoother source (search + direct download with a free key).
- Every `modsettings.lsx` write is backed up first. Keep that safety.

## Conventions
- Pure value types where possible; `AppState` is the only `@MainActor` mutation point.
- File reads that could be slow (conflict scan) run off the main actor via `Task.detached`.
- `refresh()` recomputes `healthReport` and invalidates a stale `conflictReport`.

## Backlog / ideas (not yet built)
- App icon + real bundle id / signing for distribution.
- `.rar`/`.7z` extraction (currently only `.zip` and bare `.pak`).
- Conflict detector: enumerate v15/16 paks too; detect *semantic* conflicts (same stats entry in
  different files), not just same-path overlaps.
- Per-issue "why" detail view in Health; richer missing-dependency resolution (search + install).
- Nexus: register as the system `nxm://` handler more robustly; handle collections.

## Disclaimer
Community tool, not affiliated with Larian, Nexus Mods, mod.io, or CodeWeavers.
