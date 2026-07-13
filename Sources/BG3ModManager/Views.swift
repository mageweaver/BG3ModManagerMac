import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            EnvironmentBar()
            Divider()
            TabView {
                LoadOrderView().tabItem { Label("Load Order", systemImage: "list.number") }
                BrowseView().tabItem { Label("Browse", systemImage: "magnifyingglass") }
                HealthView().tabItem { Label("Health", systemImage: "stethoscope") }
                ConflictsView().tabItem { Label("Conflicts", systemImage: "exclamationmark.triangle") }
                ScriptExtenderView().tabItem { Label("Script Extender", systemImage: "terminal") }
                SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .padding(.top, 4)
            Divider()
            StatusBar()
        }
    }
}

// MARK: Environment picker

struct EnvironmentBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "gamecontroller")
            if state.environments.isEmpty {
                Text("No BG3 install detected").foregroundStyle(.secondary)
            } else {
                Picker("Install", selection: Binding(
                    get: { state.activeEnvironment },
                    set: { state.activeEnvironment = $0 })
                ) {
                    ForEach(state.environments) { env in
                        Text(env.label).tag(GameEnvironment?.some(env))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 360)

                if let env = state.activeEnvironment {
                    Label(env.kind == .crossOver ? "CrossOver — SE possible" :
                            (env.kind == .nativeMac ? "Native — no SE" : "Custom"),
                          systemImage: env.supportsScriptExtender ? "checkmark.seal" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(env.supportsScriptExtender ? .green : .secondary)
                }
            }
            Spacer()
            Button { state.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

// MARK: Load order

struct LoadOrderView: View {
    @EnvironmentObject var state: AppState
    @State private var importing = false
    @State private var showingSaveProfile = false
    @State private var newProfileName = ""

    var body: some View {
        HSplitView {
            // Enabled (ordered)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    header("Active Load Order", subtitle: "Top loads first · drag to reorder")
                    Spacer()
                    Button { state.autoSortByDependencies() } label: {
                        Label("Auto-sort", systemImage: "wand.and.stars")
                    }
                    .help("Reorder so each mod loads after its declared dependencies")
                    ProfilesMenu(showingSaveProfile: $showingSaveProfile)
                }
                .padding(.trailing, 8)
                List {
                    ForEach(state.enabledMods) { mod in ModRow(mod: mod, enabled: true) }
                        .onMove { state.moveEnabled(from: $0, to: $1) }
                }
                .listStyle(.inset)
            }
            .frame(minWidth: 360)

            // Disabled (available)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    header("Available Mods", subtitle: "Not in load order")
                    Spacer()
                    Button { importing = true } label: { Label("Add .pak", systemImage: "plus") }
                }
                List {
                    ForEach(state.disabledMods) { mod in ModRow(mod: mod, enabled: false) }
                }
                .listStyle(.inset)
            }
            .frame(minWidth: 320)
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: "pak") ?? .data],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { urls.forEach { state.installLocalPak($0) } }
        }
        .alert("Save load order as profile", isPresented: $showingSaveProfile) {
            TextField("Profile name", text: $newProfileName)
            Button("Cancel", role: .cancel) { newProfileName = "" }
            Button("Save") {
                state.saveProfile(named: newProfileName)
                newProfileName = ""
            }
        } message: {
            Text("Saves the current enabled mods and their order. You can switch back to it any time.")
        }
    }

    private func header(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.top, 8)
    }
}

struct ModRow: View {
    @EnvironmentObject var state: AppState
    let mod: Mod
    let enabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { mod.isEnabled },
                set: { state.toggle(mod, on: $0) })
            ).labelsHidden().toggleStyle(.switch).controlSize(.mini)

            VStack(alignment: .leading, spacing: 1) {
                Text(mod.displayName).fontWeight(.medium)
                if let author = mod.meta?.author, !author.isEmpty {
                    Text(author).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            CompatibilityBadge(mod.compatibility)
            Menu {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([mod.fileURL])
                }
                Button("Delete .pak", role: .destructive) { state.deleteMod(mod) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).frame(width: 28)
        }
        .padding(.vertical, 2)
    }
}

struct CompatibilityBadge: View {
    let compat: Mod.Compatibility
    init(_ c: Mod.Compatibility) { compat = c }
    var body: some View {
        switch compat {
        case .ok: EmptyView()
        case .needsScriptExtender:
            badge("Needs SE", color: .orange, icon: "exclamationmark.triangle.fill")
        case .unreadableMeta:
            badge("No meta", color: .gray, icon: "questionmark.diamond")
        }
    }
    private func badge(_ text: String, color: Color, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18)).foregroundStyle(color).clipShape(Capsule())
    }
}

// MARK: Profiles menu

struct ProfilesMenu: View {
    @EnvironmentObject var state: AppState
    @Binding var showingSaveProfile: Bool

    var body: some View {
        Menu {
            Button {
                showingSaveProfile = true
            } label: { Label("Save current as profile…", systemImage: "square.and.arrow.down") }
            Button { importProfile() } label: { Label("Import profile…", systemImage: "tray.and.arrow.down") }

            if state.profiles.isEmpty {
                Text("No saved profiles")
            } else {
                Divider()
                ForEach(state.profiles) { profile in
                    Menu(profile.name) {
                        Button {
                            state.applyProfile(profile)
                        } label: { Label("Apply (\(profile.entries.count) mods)", systemImage: "checkmark.circle") }
                        Button { exportProfile(profile) } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                        Button(role: .destructive) {
                            state.deleteProfile(profile)
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
        } label: {
            Label("Profiles", systemImage: "person.crop.rectangle.stack")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func exportProfile(_ profile: LoadOrderProfile) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(profile.name).bg3profile.json"
        panel.message = "Export this load order to share it"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.exportProfile(profile, to: url)
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose a shared BG3 load-order profile (.json)"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.importProfile(from: url)
    }
}

// MARK: Browse remote

struct BrowseView: View {
    @EnvironmentObject var state: AppState
    @State private var query = ""
    @State private var source: RemoteMod.Source = .modio

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Source", selection: $source) {
                    Text("mod.io").tag(RemoteMod.Source.modio)
                    Text("Nexus (trending)").tag(RemoteMod.Source.nexus)
                }.pickerStyle(.segmented).frame(width: 260)

                TextField(source == .modio ? "Search mod.io…" : "Nexus has no API search — shows trending",
                          text: $query)
                    .textFieldStyle(.roundedBorder)
                    .disabled(source == .nexus)
                    .onSubmit { Task { await state.browse(source, query: query) } }

                Button { Task { await state.browse(source, query: query) } } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
            }
            .padding(.horizontal, 12).padding(.top, 8)

            if state.isBusy { ProgressView().padding() }

            List(state.remoteResults) { remote in
                RemoteRow(remote: remote)
            }.listStyle(.inset)
        }
    }
}

struct RemoteRow: View {
    @EnvironmentObject var state: AppState
    let remote: RemoteMod

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(remote.name).fontWeight(.semibold)
                    Text(remote.source.rawValue).font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary).clipShape(Capsule())
                    if remote.mentionsScriptExtender {
                        Label("Mentions SE", systemImage: "exclamationmark.triangle")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                if !remote.author.isEmpty {
                    Text("by \(remote.author)").font(.caption).foregroundStyle(.secondary)
                }
                Text(remote.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            VStack(spacing: 6) {
                Button { Task { await state.download(remote) } } label: {
                    Label("Install", systemImage: "square.and.arrow.down")
                }
                if let page = remote.pageURL {
                    Link("Open page", destination: page).font(.caption)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: Health

struct HealthView: View {
    @EnvironmentObject var state: AppState

    private var report: HealthChecker.Report { state.healthReport }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Load Order Health").font(.headline)
                    Text("Dependency and compatibility checks across your enabled mods.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if report.errorCount > 0 {
                    countPill("\(report.errorCount) error\(report.errorCount == 1 ? "" : "s")", .red)
                }
                if report.warningCount > 0 {
                    countPill("\(report.warningCount) warning\(report.warningCount == 1 ? "" : "s")", .orange)
                }
                Button { state.refresh() } label: { Label("Re-check", systemImage: "arrow.clockwise") }
            }
            .padding(.horizontal, 12).padding(.top, 8)

            if report.isHealthy {
                ContentUnavailableLikeView(
                    icon: "checkmark.seal.fill", tint: .green,
                    title: "Everything checks out",
                    message: "All \(report.checkedCount) enabled mods have their dependencies present, enabled, and in the right order.")
            } else {
                HStack {
                    Spacer()
                    Button { state.fixAllAutoResolvable() } label: {
                        Label("Fix all auto-resolvable", systemImage: "wand.and.stars")
                    }
                    .disabled(!report.hasAutoFixes)
                    .padding(.horizontal, 12)
                }
                List(report.issues) { issue in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.severity == .error ? .red : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.modName).fontWeight(.medium)
                            Text(issue.kind.label).font(.caption)
                            Text(issue.kind.fixHint).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let title = issue.resolution.actionTitle {
                            Button { state.resolve(issue) } label: {
                                Label(title, systemImage: issue.resolution.actionIcon)
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
    }

    private func countPill(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2).padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.18)).foregroundStyle(color).clipShape(Capsule())
    }
}

// MARK: Conflicts

struct ConflictsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("File Conflicts").font(.headline)
                    Text("Mods in your load order that ship the same file. The mod lower in the order wins.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await state.scanConflicts() } } label: {
                    Label("Scan load order", systemImage: "magnifyingglass")
                }.disabled(state.isScanningConflicts)
            }
            .padding(.horizontal, 12).padding(.top, 8)

            if state.isScanningConflicts {
                ProgressView("Reading paks…").padding()
                Spacer()
            } else if let report = state.conflictReport {
                if report.isEmpty {
                    ContentUnavailableLikeView(
                        icon: "checkmark.seal.fill", tint: .green,
                        title: "No conflicts",
                        message: "None of your \(report.scannedModCount) enabled mods overwrite each other’s files.")
                } else {
                    conflictList(report)
                }
            } else {
                ContentUnavailableLikeView(
                    icon: "exclamationmark.triangle", tint: .secondary,
                    title: "Not scanned yet",
                    message: "Run a scan to check your enabled mods for overlapping files.")
            }
        }
    }

    private func conflictList(_ report: ConflictDetector.Report) -> some View {
        List {
            if !report.pairs.isEmpty {
                Section("Mod pairs that overlap") {
                    ForEach(report.pairs) { pair in
                        HStack {
                            Text(pair.a.displayName).lineLimit(1)
                            Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                            Text(pair.b.displayName).lineLimit(1)
                            Spacer()
                            Text("\(pair.count) file\(pair.count == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Conflicting files (\(report.fileConflicts.count))") {
                ForEach(report.fileConflicts) { c in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(c.path).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 6) {
                            if let winner = c.winner {
                                Label(winner.displayName, systemImage: "crown.fill")
                                    .font(.caption2).foregroundStyle(.green).lineLimit(1)
                            }
                            if !c.losers.isEmpty {
                                Text("overrides " + c.losers.map { $0.displayName }.joined(separator: ", "))
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .listStyle(.inset)
    }
}

/// Small stand-in so we don't depend on macOS 14's ContentUnavailableView.
struct ContentUnavailableLikeView: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon).font(.system(size: 38)).foregroundStyle(tint)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: Status bar

struct StatusBar: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        HStack {
            if state.isBusy { ProgressView().controlSize(.small) }
            Text(state.statusMessage.isEmpty ? "Ready" : state.statusMessage)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}
