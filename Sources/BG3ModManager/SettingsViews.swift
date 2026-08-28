import SwiftUI
import AppKit

// MARK: Settings

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("Nexus Mods") {
                SecureField("API key", text: $state.nexusAPIKey)
                HStack {
                    Button("Validate key") { Task { await state.validateNexus() } }
                    Link("Get a key", destination: URL(string: "https://www.nexusmods.com/users/myaccount?tab=api")!)
                        .font(.caption)
                }
                Text("The public Nexus API has no text search and free accounts can't generate direct download links — those need Nexus Premium or an in-browser “Mod Manager Download”.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("mod.io") {
                SecureField("API key", text: $state.modioAPIKey)
                Link("Get a key", destination: URL(string: "https://mod.io/me/access")!).font(.caption)
                Text("mod.io supports search and direct downloads with a free public API key. This is the same source BG3’s in-game mod manager uses.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Appearance") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Description text size")
                        Spacer()
                        Text("\(Int(state.descriptionTextSize)) pt")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Button("Reset") { state.descriptionTextSize = AppState.defaultDescriptionTextSize }
                            .buttonStyle(.borderless)
                            .disabled(state.descriptionTextSize == AppState.defaultDescriptionTextSize)
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                        Slider(value: $state.descriptionTextSize,
                               in: AppState.descriptionTextSizeRange,
                               step: 1)
                        Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                    }

                    // Live sample: the same two lines a mod row and a Browse result actually render,
                    // so the effect of the slider is visible without switching tabs.
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mod Configuration Menu").fontWeight(.medium)
                        Text("Volitio").font(state.detailFont).foregroundStyle(.secondary)
                        Text("A configuration menu for mods, letting them expose their settings in-game rather than through config files.")
                            .font(state.descriptionFont)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

                    Text("Applies to mod descriptions in Browse, the load-order position numbers, the author, note and install lines under each mod, and the issue text in Health.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Game location") {
                if let env = state.activeEnvironment {
                    LabeledContent("Active install", value: env.label)
                    LabeledContent("Mods folder") { pathText(env.modsFolder.path) }
                    LabeledContent("modsettings.lsx") { pathText(env.modSettingsFile.path) }
                    if let bin = env.gameBinFolder {
                        LabeledContent("Game bin") { pathText(bin.path) }
                    }
                }
                Button("Add a custom BG3 documents folder…") { pickCustomFolder() }
                Text("Use this if your install lives somewhere unusual — e.g. a CrossOver bottle this app didn’t auto-detect. Point it at the “Baldur’s Gate 3” folder that contains Mods and PlayerProfiles.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func pathText(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
    }

    private func pickCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Select Baldur's Gate 3 folder"
        guard panel.runModal() == .OK, let docs = panel.url else { return }

        // Optionally also ask for the game bin folder (needed for Script Extender under CrossOver).
        let binPanel = NSOpenPanel()
        binPanel.canChooseDirectories = true
        binPanel.canChooseFiles = false
        binPanel.message = "Optional: select the game 'bin' folder (contains bg3.exe) for Script Extender. Cancel to skip."
        binPanel.prompt = "Select bin folder"
        let bin = binPanel.runModal() == .OK ? binPanel.url : nil

        state.setCustomPaths(documents: docs, gameBin: bin)
    }
}

// MARK: Script Extender

struct ScriptExtenderView: View {
    @EnvironmentObject var state: AppState
    @State private var showingInstallLog = false

    private var env: GameEnvironment? { state.activeEnvironment }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Script Extender").font(.title2).bold()

                Group {
                    if env?.kind == .crossOver {
                        crossOverPanel
                    } else if env?.kind == .nativeMac {
                        nativePanel
                    } else {
                        Text("Select a BG3 install to see Script Extender options.")
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()
                explainer
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .sheet(isPresented: $showingInstallLog) { InstallLogSheet() }
    }

    private var nativePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            binaryReleaseBox            // the recommended one-click path, first
            Divider()
            advancedBuildHeader
            if let install = state.macScriptExtender {
                switch install.stage {
                case .ready:
                    infoBox(color: .green, icon: "checkmark.seal.fill",
                            title: "Script Extender is set up for the native Mac build",
                            body: "BG3SE-macOS is built and Steam is launching the game through it. Mods that need the Script Extender work here.")
                case .notWired:
                    infoBox(color: .orange, icon: "exclamationmark.triangle.fill",
                            title: "Built, but Steam isn’t launching through it",
                            body: "The dylib exists, but BG3’s launch options don’t point at the launcher — so the game starts without the Script Extender. Paste the line below into Steam.")
                case .notBuilt:
                    infoBox(color: .orange, icon: "hammer.fill",
                            title: "Checkout found, but not built yet",
                            body: "BG3SE-macOS builds from source. Run the commands below in Terminal, then come back and re-check.")
                }
                installationDetails(install)
            } else {
                infoBox(color: .secondary, icon: "questionmark.circle.fill",
                        title: "BG3SE-macOS not installed",
                        body: "The native Mac build can run Script Extender mods through BG3SE-macOS, a separate open-source project. It has no prebuilt download — it compiles against the Mac game binary — so installing it means cloning and building it. This app can do that for you.")
                prerequisites
                HStack {
                    Button("Install BG3SE-macOS…") { installScriptExtender(into: state.defaultScriptExtenderRoot) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!ScriptExtenderInstaller.checkPrerequisites().ready || state.isInstallingScriptExtender)
                    Button("Choose Existing Folder…") { chooseScriptExtenderFolder() }
                    Button("Look Again") { state.refreshScriptExtenderMac() }
                    Spacer()
                    Button("Project page") { NSWorkspace.shared.open(ScriptExtenderMac.repository) }
                }
            }
        }
    }

    @ViewBuilder
    private func installationDetails(_ install: ScriptExtenderMac.Installation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                detailRow("Folder", install.root.path)
                if let built = install.dylibBuiltAt {
                    detailRow("Built", Self.stamp.string(from: built)
                              + " · " + ByteCountFormatter.string(fromByteCount: install.dylibBytes, countStyle: .file)
                              + (install.isUniversal ? " · universal (Intel + Apple Silicon)" : ""))
                } else {
                    detailRow("Built", "not yet")
                }
                detailRow("Steam launch options", install.wiredIntoSteam ? "pointing at the launcher" : "not set")
            }
            .font(.caption)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

            if !install.isBuilt {
                codeBlock(title: "Build it", text: ScriptExtenderMac.buildCommands(for: install.root))
            } else if let options = install.launchOptions, !install.wiredIntoSteam {
                codeBlock(title: "Steam → Baldur’s Gate 3 → Properties → Launch Options",
                          text: options)
                Text("Steam only writes launch options to disk when it quits, so this may keep reading “not set” until you restart Steam.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if !install.isBuilt {
                    Button("Build It Now") { installScriptExtender(into: install.root) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!ScriptExtenderInstaller.checkPrerequisites().ready || state.isInstallingScriptExtender)
                } else if !install.wiredIntoSteam {
                    Button("Set Steam Launch Options") { state.wireScriptExtenderIntoSteam() }
                        .buttonStyle(.borderedProminent)
                        .disabled(SteamLaunchOptions.isSteamRunning)
                        .help(SteamLaunchOptions.isSteamRunning
                              ? "Quit Steam first — it rewrites its config on exit and would discard the change"
                              : "Write the launcher into BG3's Steam launch options")
                }
                Button("Update & Rebuild") { installScriptExtender(into: install.root) }
                    .disabled(state.isInstallingScriptExtender)
                Button("Re-check") { state.refreshScriptExtenderMac() }
                Spacer()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([install.root]) }
                Button("Choose Different Folder…") { chooseScriptExtenderFolder() }
            }
            if !install.isBuilt { prerequisites }
            if install.isBuilt, !install.wiredIntoSteam, SteamLaunchOptions.isSteamRunning {
                Label("Steam is running — quit it first, or the change will be overwritten when it exits.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// What the build needs, and how to get whatever is absent.
    @ViewBuilder
    private var prerequisites: some View {
        let tools = ScriptExtenderInstaller.checkPrerequisites()
        if tools.ready {
            Label("git, CMake and the Xcode command line tools are all present.",
                  systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("Missing \(tools.missing.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                if let remedy = tools.remedy {
                    codeBlock(title: "Install the missing tools first", text: remedy)
                }
            }
        }
    }

    private func installScriptExtender(into root: URL) {
        showingInstallLog = true
        Task { await state.installScriptExtenderMac(into: root) }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
    }

    private func codeBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                .buttonStyle(.borderless)
            }
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
        }
    }

    private func chooseScriptExtenderFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Choose your bg3se-macos folder"
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.setScriptExtenderMacPath(url)
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    private var crossOverPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            infoBox(color: .green, icon: "checkmark.seal.fill",
                    title: "Script Extender is possible in this CrossOver bottle",
                    body: "Because CrossOver runs the Windows build of BG3, the Windows Script Extender can load here — just like it does under Proton on a Steam Deck.")

            if env?.gameBinFolder == nil {
                infoBox(color: .orange, icon: "exclamationmark.triangle.fill",
                        title: "Game ‘bin’ folder not found",
                        body: "Set the bin folder (the one containing bg3.exe) in Settings → Game location, then come back.")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Install the loader").font(.headline)
                Text("1. Download the latest Script Extender release. 2. From its archive, pick the DWrite.dll file. 3. This app copies it next to bg3.exe and backs up any existing one.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Link(destination: ScriptExtender.releasesPage) {
                        Label("Open SE releases", systemImage: "arrow.up.right.square")
                    }
                    Button { installLoader() } label: { Label("Choose DWrite.dll…", systemImage: "square.and.arrow.down") }
                        .disabled(env?.gameBinFolder == nil)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Then add the Wine DLL override").font(.headline)
                Text(ScriptExtender.wineOverrideInstructions)
                    .font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    /// The recommended path: download the pre-built dylib straight into the game.
    private var binaryReleaseBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let rel = state.macSERelease, rel.isReady {
                infoBox(color: .green, icon: "checkmark.seal.fill",
                        title: "Script Extender installed",
                        body: "libbg3se.dylib is in the game and Gatekeeper-cleared. Launch Baldur's Gate 3 through Steam — it loads the extender on its own.")
                releaseDetails(rel)
                HStack {
                    Button("Update / Reinstall") { Task { await state.installSEFromRelease() } }
                        .disabled(state.isDownloadingSE)
                    Button("Remove") { state.uninstallSERelease() }
                    Spacer()
                    Button("Releases") { NSWorkspace.shared.open(ScriptExtenderRelease.releasesPage) }
                }
            } else if let rel = state.macSERelease, rel.isInstalled, rel.quarantined {
                infoBox(color: .orange, icon: "lock.shield",
                        title: "Installed, but quarantined",
                        body: "macOS is blocking the unsigned dylib. Re-run the install to clear it, or run `xattr -d com.apple.quarantine` on it yourself.")
                Button("Fix (clear quarantine)") { Task { await state.installSEFromRelease() } }
                    .buttonStyle(.borderedProminent).disabled(state.isDownloadingSE)
            } else {
                infoBox(color: .blue, icon: "arrow.down.circle.fill",
                        title: "Install the Script Extender (recommended)",
                        body: "Download the pre-built extender and drop it straight into Baldur's Gate 3. No Terminal, no building. Targets game build \(ScriptExtenderRelease.targetGameBuild).")
                HStack {
                    Button {
                        Task { await state.installSEFromRelease() }
                    } label: {
                        if state.isDownloadingSE {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Downloading…") }
                        } else {
                            Text("Download & Install")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isDownloadingSE || ScriptExtenderRelease.discoverGameApp() == nil)

                    Button("Look Again") { state.refreshSERelease() }
                    Spacer()
                    Button("Releases") { NSWorkspace.shared.open(ScriptExtenderRelease.releasesPage) }
                }
                if ScriptExtenderRelease.discoverGameApp() == nil {
                    Text("Couldn't find Baldur's Gate 3.app. Install the game through Steam first, or set the path in Settings.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if !state.scriptExtenderLog.isEmpty {
                Button("View install log") { showingInstallLog = true }.font(.callout)
            }
        }
    }

    private func releaseDetails(_ rel: ScriptExtenderRelease.State) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let d = rel.installedDylib {
                Text(d.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                if rel.installedBytes > 0 {
                    Text("\(ByteCountFormatter.string(fromByteCount: rel.installedBytes, countStyle: .file))")
                }
                if let at = rel.installedAt {
                    Text("installed \(at.formatted(date: .abbreviated, time: .shortened))")
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }

    private var advancedBuildHeader: some View {
        Text("Advanced: build from source")
            .font(.subheadline).bold().foregroundStyle(.secondary)
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Two routes to the Script Extender on a Mac").font(.headline)
            Text("The Script Extender isn’t a normal mod — it hooks the running game’s internals to expose a Lua scripting layer, so it has to be built for the exact binary it attaches to.\n\nUnder CrossOver you’re running the Windows game, so Norbyte’s Windows SE loads as a DWrite.dll proxy, exactly as it does under Proton.\n\nOn the native Mac build, BG3SE-macOS is a separate project that reimplements the extender against the Mac binary. It ships as a dylib you build yourself and loads by wrapping the game’s launch command in Steam — no DLL, and nothing to place in the Mods folder. Most Windows SE mods work through it, including Mod Configuration Menu and the libraries that hundreds of mods depend on.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func infoBox(color: Color, icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(body).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func installLoader() {
        guard let env else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Select DWrite.dll from the Script Extender release"
        panel.prompt = "Install loader"
        guard panel.runModal() == .OK, let dll = panel.url else { return }
        do {
            let dest = try ScriptExtender.installLoader(dll, into: env)
            state.statusMessage = "Installed Script Extender loader → \(dest.path). Now add the dwrite Wine override."
        } catch {
            state.statusMessage = "SE install failed: \(error.localizedDescription)"
        }
    }
}


/// Live output from the clone and build.
///
/// A CMake build of this project runs for minutes; without the log it is indistinguishable from a
/// frozen app, so the output is shown as it arrives rather than summarised at the end.
struct InstallLogSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Installing BG3SE-macOS").font(.headline)
                if state.isInstallingScriptExtender {
                    ProgressView().controlSize(.small).padding(.leading, 4)
                }
                Spacer()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(state.scriptExtenderLog.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 320)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: state.scriptExtenderLog.count) { count in
                    withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }

            HStack {
                Button("Copy Log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.scriptExtenderLog.joined(separator: "\n"), forType: .string)
                }
                .disabled(state.scriptExtenderLog.isEmpty)
                Spacer()
                Button(state.isInstallingScriptExtender ? "Hide" : "Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            if state.isInstallingScriptExtender {
                Text("Hiding this leaves the build running; reopen it from the Script Extender tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 620)
    }
}
