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
    }

    private var nativePanel: some View {
        infoBox(color: .red, icon: "xmark.octagon.fill",
                title: "Not available on the native Mac build",
                body: "The native macOS version of BG3 can’t run the Script Extender — Apple’s process-injection protections block the memory hooking the SE relies on. Any mod flagged “Needs SE” will not work here. To use those mods, install BG3’s Windows build in CrossOver and switch to that install above.")
    }

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

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Why there’s no Mac-native Script Extender").font(.headline)
            Text("The Script Extender isn’t a normal mod — it injects into the running game and hooks its internals in memory to expose a Lua scripting layer. Doing that on macOS would mean defeating System Integrity Protection, the hardened runtime, and code signing, against a game binary that changes every patch. That’s why no native port exists. Running the Windows game + Windows SE under CrossOver sidesteps the whole problem.")
                .font(.callout).foregroundStyle(.secondary)
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
