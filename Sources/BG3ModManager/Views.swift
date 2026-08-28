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
                SavesView().tabItem { Label("Saves", systemImage: "externaldrive.badge.timemachine") }
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
    @State private var filter = ""
    @State private var confirmingDeactivateAll = false
    @State private var confirmingDeleteAll = false
    @State private var syncing = false

    var body: some View {
        let q = filter.trimmingCharacters(in: .whitespaces)
        let filtering = !q.isEmpty
        let enabled = filtering ? state.enabledMods.filter { matches($0, q) } : state.enabledMods
        let disabled = filtering ? state.disabledMods.filter { matches($0, q) } : state.disabledMods

        return VStack(spacing: 0) {
            searchBar
            HSplitView {
                // Enabled (ordered)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        header("Active Load Order",
                               count: enabled.count,
                               subtitle: filtering
                                   ? "Showing \(enabled.count) of \(state.enabledMods.count) · clear filter to reorder"
                                   : "Top loads first · drag to reorder")
                        Spacer()
                        loadOrderActions
                    }
                    .padding(.trailing, 8)
                    let positions = state.loadOrderPositions
                    List {
                        ForEach(enabled) { mod in
                            ModRow(mod: mod, enabled: true, position: positions[mod.id])
                        }
                            .onMove { offsets, dest in
                                // Positions are only valid against the full list; a filtered view can't
                                // be safely reordered, so moves are ignored until the filter is cleared.
                                guard !filtering else { return }
                                state.moveEnabled(from: offsets, to: dest)
                            }
                    }
                    .listStyle(.inset)
                }
                .frame(minWidth: 360)

                // Disabled (available)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        header("Available Mods",
                               count: disabled.count,
                               subtitle: filtering ? "Showing \(disabled.count) of \(state.disabledMods.count)"
                                                   : "Not in load order")
                        Spacer()
                        Button { importing = true } label: { Label("Add Mod…", systemImage: "plus") }
                            .help("Add a .pak, or a .zip you downloaded — the paks inside are unpacked for you")
                        Button { syncing = true } label: {
                            Label("Copy from Install…", systemImage: "arrow.left.arrow.right")
                        }
                        .disabled(state.otherEnvironments.isEmpty || state.isScanningMods)
                        .help("Copy mods from another BG3 install on this Mac into this one")
                        Button(role: .destructive) { confirmingDeleteAll = true } label: {
                            Label("Delete All", systemImage: "trash")
                        }
                        .disabled(state.mods.isEmpty || state.isScanningMods)
                        .help("Delete every installed .pak, moving them to the Trash")
                    }
                    List {
                        ForEach(disabled) { mod in ModRow(mod: mod, enabled: false, position: nil) }
                    }
                    .listStyle(.inset)
                }
                .frame(minWidth: 320)
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: "pak") ?? .data, .zip, .archive],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { urls.forEach { state.addLocalFile($0) } }
        }
        .alert("Save load order as profile", isPresented: $showingSaveProfile) {
            TextField("Profile name", text: $newProfileName)
            Button("Cancel", role: .cancel) { newProfileName = "" }
            Button("Save") {
                state.saveProfile(named: newProfileName)
                newProfileName = ""
            }
            .disabled(state.isScanningMods)
        } message: {
            Text(state.isScanningMods
                 ? "Still scanning the Mods folder — wait for it to finish so the whole load order is saved."
                 : "Saves the current enabled mods and their order. You can switch back to it any time.")
        }
        .confirmationDialog("Disable all \(state.enabledMods.count) mods?",
                            isPresented: $confirmingDeactivateAll, titleVisibility: .visible) {
            Button("Disable All", role: .destructive) { state.deactivateAllMods() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every mod is turned off, but nothing is deleted. The current order is saved as a profile first, so you can put it back from the Profiles menu.")
        }
        .sheet(isPresented: $confirmingDeleteAll) { DeleteAllSheet() }
        .sheet(isPresented: $syncing) { SyncModsSheet() }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter installed mods by name, author, or note…", text: $filter)
                .textFieldStyle(.plain)
            if !filter.isEmpty {
                Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Clear filter")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func matches(_ mod: Mod, _ q: String) -> Bool {
        mod.displayName.localizedCaseInsensitiveContains(q)
            || (mod.meta?.author.localizedCaseInsensitiveContains(q) ?? false)
            || state.note(for: mod).localizedCaseInsensitiveContains(q)
    }

    /// The load-order toolbar. Five labelled controls need roughly 600pt, and this pane can be
    /// dragged down to 360 — so the labels drop to icons rather than the row clipping and quietly
    /// hiding whichever control sits at the end.
    private var loadOrderActions: some View {
        ViewThatFits(in: .horizontal) {
            actionCluster
            actionCluster.labelStyle(.iconOnly)
        }
    }

    private var actionCluster: some View {
        HStack(spacing: 8) {
            Button { state.autoSortByDependencies() } label: {
                Label("Auto-sort", systemImage: "wand.and.stars")
            }
            .help("Reorder so each mod loads after its declared dependencies")

            Button { confirmingDeactivateAll = true } label: {
                Label("Disable All", systemImage: "square.slash")
            }
            .disabled(state.enabledMods.isEmpty || state.isScanningMods)
            .help(state.enabledMods.isEmpty
                  ? "Nothing is enabled in this install"
                  : "Turn off all \(state.enabledMods.count) mods in the load order. The paks stay installed.")

            UpdatesMenu()
            ProfilesMenu(showingSaveProfile: $showingSaveProfile)
            BackupMenu()
        }
        .fixedSize()
    }

    private func header(_ title: String, count: Int, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                // Dimmed while a scan is in flight: the list underneath is stale until it lands, and
                // a confident-looking number that is about to change is worse than an obviously
                // provisional one.
                Text(state.isScanningMods ? "—" : "\(count)")
                    .font(.caption).monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(state.isScanningMods ? .tertiary : .secondary)
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.top, 8)
    }
}

struct ModRow: View {
    @EnvironmentObject var state: AppState
    let mod: Mod
    let enabled: Bool
    /// 1-based load-order position; nil for mods that aren't in the order.
    var position: Int?

    @State private var editingNote = false
    @State private var draftNote = ""
    @State private var linking = false
    @State private var movingTo = false
    @State private var targetPosition = ""

    var body: some View {
        HStack(spacing: 10) {
            if let position {
                Text("\(position)")
                    .font(state.positionFont)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: state.positionColumnWidth, alignment: .trailing)
            }
            Toggle("", isOn: Binding(
                get: { mod.isEnabled },
                set: { state.toggle(mod, on: $0) })
            ).labelsHidden().toggleStyle(.switch).controlSize(.mini)

            VStack(alignment: .leading, spacing: 1) {
                Text(mod.displayName).fontWeight(.medium)
                if let author = mod.meta?.author, !author.isEmpty {
                    Text(author).font(state.detailFont).foregroundStyle(.secondary)
                }
                if state.hasNote(mod) {
                    Label(state.note(for: mod), systemImage: "note.text")
                        .font(state.descriptionFont).foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(state.note(for: mod))
                }
                provenanceLine
            }
            Spacer()
            UpdateBadge(mod: mod)
            CompatibilityBadge(mod.compatibility)

            Button {
                draftNote = state.note(for: mod)
                editingNote = true
            } label: {
                Image(systemName: state.hasNote(mod) ? "note.text" : "square.and.pencil")
                    .foregroundStyle(state.hasNote(mod) ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(state.hasNote(mod) ? state.note(for: mod) : "Add note")
            .popover(isPresented: $editingNote, arrowEdge: .bottom) { noteEditor }

            Menu {
                Button(state.hasNote(mod) ? "Edit Note…" : "Add Note…") {
                    draftNote = state.note(for: mod)
                    editingNote = true
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(mod.allFiles)
                }
                if position != nil {
                    Divider()
                    Button("Move Before…") {
                        targetPosition = ""
                        movingTo = true
                    }
                }
                Divider()
                if state.updateAvailable(for: mod) {
                    Button("Update Now") { Task { await state.updateMod(mod) } }
                }
                if state.record(for: mod)?.isLinked == true {
                    Button("Open Mod Page") {
                        if let url = state.modPageURL(for: mod) { NSWorkspace.shared.open(url) }
                    }
                    Button("Unlink from \(state.record(for: mod)?.source?.rawValue ?? "upstream")") {
                        state.unlinkMod(mod)
                    }
                } else {
                    Button("Link to Nexus / mod.io…") { linking = true }
                }
                Divider()
                Button(mod.parts.isEmpty ? "Delete .pak" : "Delete .pak and \(mod.parts.count) split file\(mod.parts.count == 1 ? "" : "s")",
                       role: .destructive) { state.deleteMod(mod) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).frame(width: 28)
        }
        .padding(.vertical, 2)
        .sheet(isPresented: $linking) { LinkModSheet(mod: mod) }
        .popover(isPresented: $movingTo, arrowEdge: .bottom) { moveEditor }
    }

    /// Where this pak came from and when: install date, split-file count, and the linked source.
    @ViewBuilder
    private var provenanceLine: some View {
        let record = state.record(for: mod)
        let stamp = state.installedAt(for: mod)
        if stamp != nil || mod.isSplit || record?.isLinked == true {
            HStack(spacing: 8) {
                if let stamp {
                    Label(Self.dayFormatter.string(from: stamp.date), systemImage: "calendar")
                        .help(stamp.isExact
                              ? "Installed by this manager on \(Self.exactFormatter.string(from: stamp.date))"
                              : "From the pak's file date (\(Self.exactFormatter.string(from: stamp.date))) — copying a pak resets it")
                }
                if !mod.missingParts.isEmpty {
                    Label("Missing \(mod.missingParts.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .help("This mod is split across several files and one isn't in the Mods folder. It won't load without it.")
                } else if !mod.parts.isEmpty {
                    Label("\(mod.parts.count + 1) files", systemImage: "square.stack.3d.up")
                        .help("Split archive: \(mod.allFiles.map(\.lastPathComponent).joined(separator: ", "))")
                }
                if let record, record.isLinked {
                    Label(record.version.map { "v\($0)" } ?? (record.source?.rawValue ?? ""),
                          systemImage: "link")
                        .help("Linked to \(record.source?.rawValue ?? "upstream")")
                }
            }
            .font(state.detailFont)
            .foregroundStyle(.secondary)
        }
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()
    static let exactFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    /// Ask for a position and move this mod immediately above whatever is there now.
    private var moveEditor: some View {
        let total = state.enabledMods.count
        let entered = Int(targetPosition.trimmingCharacters(in: .whitespaces))
        let valid = entered.map { $0 >= 1 && $0 <= total + 1 } ?? false

        return VStack(alignment: .leading, spacing: 8) {
            Text("Move in load order").font(.headline)
            Text(mod.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)

            HStack(spacing: 6) {
                Text("Insert before #")
                TextField("", text: $targetPosition)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .onSubmit { if valid { commitMove(entered!) } }
                Text("of \(total)").foregroundStyle(.secondary)
            }

            Text(preview(entered, total: total))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Move to End") { commitMove(total + 1) }
                Spacer()
                Button("Cancel") { movingTo = false }
                Button("Move") { if let entered { commitMove(entered) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
        }
        .padding(12)
        .frame(width: 330)
    }

    /// Name the mod that will end up directly below, so the number means something before committing.
    private func preview(_ entered: Int?, total: Int) -> String {
        guard let entered else {
            return "Currently #\(position ?? 0). Enter 1–\(total + 1); \(total + 1) moves it to the end."
        }
        guard entered >= 1, entered <= total + 1 else {
            return "Enter a number between 1 and \(total + 1)."
        }
        guard entered <= total else { return "Moves “\(mod.displayName)” to the end of the load order." }
        let anchor = state.enabledMods[entered - 1]
        if anchor.id == mod.id { return "That's where it already is." }
        return "Loads immediately before “\(anchor.displayName)” (currently #\(entered))."
    }

    private func commitMove(_ position: Int) {
        movingTo = false
        state.moveMod(mod, before: position)
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Note").font(.headline)
            Text(mod.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            TextEditor(text: $draftNote)
                .font(.body)
                .frame(width: 320, height: 130)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            HStack {
                Button("Clear", role: .destructive) { draftNote = "" }
                    .disabled(draftNote.isEmpty)
                Spacer()
                Button("Cancel") { editingNote = false }
                Button("Save") {
                    state.setNote(draftNote, for: mod)
                    editingNote = false
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 344)
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

// MARK: Backup / restore menu

struct BackupMenu: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Menu {
            Button { state.backupNow() } label: { Label("Back Up Everything Now", systemImage: "arrow.down.doc.fill") }
            Button { exportBackup() } label: { Label("Export Backup…", systemImage: "square.and.arrow.up") }
            Divider()
            Button { importBackup() } label: { Label("Import Backup…", systemImage: "square.and.arrow.down") }

            let recent = BackupStore.recent()
            if !recent.isEmpty {
                Divider()
                Section("Restore a recent backup") {
                    ForEach(recent, id: \.self) { url in
                        Button(readableName(url)) { state.importBackup(from: url) }
                    }
                }
            }
            Divider()
            Button { NSWorkspace.shared.open(BackupStore.backupsDir) } label: {
                Label("Reveal Backups Folder", systemImage: "folder")
            }
        } label: {
            Label("Backup", systemImage: "archivebox")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Back up your load order, notes, and profiles to one file — or restore from a backup")
    }

    /// "BG3-backup-2026-07-13-142530.bg3backup.json" → "2026-07-13 14:25:30".
    private func readableName(_ url: URL) -> String {
        var s = url.lastPathComponent
        s = s.replacingOccurrences(of: "BG3-backup-", with: "")
        s = s.replacingOccurrences(of: BackupStore.fileSuffix, with: "")
        // yyyy-MM-dd-HHmmss → yyyy-MM-dd HH:mm:ss
        let parts = s.split(separator: "-")
        if parts.count == 4, parts[3].count == 6 {
            let t = parts[3]
            let hh = t.prefix(2), mm = t.dropFirst(2).prefix(2), ss = t.suffix(2)
            return "\(parts[0])-\(parts[1])-\(parts[2])  \(hh):\(mm):\(ss)"
        }
        return s
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "BG3-backup\(BackupStore.fileSuffix)"
        panel.message = "Save a portable backup of your load order, notes, and profiles"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.exportBackup(to: url)
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose a BG3 backup file to restore"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.importBackup(from: url)
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
                    Text("Nexus Mods").tag(RemoteMod.Source.nexus)
                }.pickerStyle(.segmented).frame(width: 260)

                TextField(source == .modio ? "Search all of mod.io…" : "Search all of Nexus Mods… (empty = trending)",
                          text: $query)
                    .textFieldStyle(.roundedBorder)
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
                    Text("by \(remote.author)").font(state.detailFont).foregroundStyle(.secondary)
                }
                Text(remote.summary)
                    .font(state.descriptionFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(remote.summary)
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
                    message: "All \(report.checkedCount) enabled mods have their dependencies present, enabled, and in the right order.",
                    messageFont: state.descriptionFont)
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
                            Text(issue.kind.label)
                                .font(state.descriptionFont)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(issue.kind.fixHint)
                                .font(state.detailFont)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
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
    /// Callers that show description-style text pass the configured size; the rest keep .callout.
    var messageFont: Font = .callout

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon).font(.system(size: 38)).foregroundStyle(tint)
            Text(title).font(.headline)
            Text(message).font(messageFont).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)
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

// MARK: Updates

/// The one control that drives update tracking: identify what's installed, then check for newer
/// versions. Both are bounded background passes, so the menu reports where they got to.
struct UpdatesMenu: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let pending = state.modsWithUpdates.count
        Menu {
            Button("Check for Updates") { Task { await state.checkForUpdates() } }
                .disabled(state.isCheckingUpdates)
            Button("Identify Installed Mods…") { Task { await state.identifyInstalledMods() } }
                .disabled(state.isCheckingUpdates)

            Divider()
            Text("\(state.linkedModCount) of \(state.mods.count) linked to Nexus or mod.io")

            if pending > 0 {
                Divider()
                Button("Update All (\(pending))") {
                    Task { for mod in state.modsWithUpdates { await state.updateMod(mod) } }
                }
                Divider()
                ForEach(state.modsWithUpdates) { mod in
                    Button("\(mod.displayName)\(state.latestVersionText(for: mod))") {
                        Task { await state.updateMod(mod) }
                    }
                }
            }
        } label: {
            if pending > 0 {
                Label("Updates (\(pending))", systemImage: "arrow.down.circle.fill")
            } else {
                Label("Updates", systemImage: "arrow.down.circle")
            }
        }
        .help(pending > 0 ? "\(pending) mod\(pending == 1 ? " has" : "s have") a newer version upstream"
                          : "Check Nexus and mod.io for newer versions")
    }
}

/// Inline "there's a newer version" affordance on a mod row — the update button itself, so acting on
/// it never needs a trip through a menu.
struct UpdateBadge: View {
    @EnvironmentObject var state: AppState
    let mod: Mod

    var body: some View {
        if state.updateAvailable(for: mod) {
            Button { Task { await state.updateMod(mod) } } label: {
                Label("Update", systemImage: "arrow.down.circle.fill")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.18))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(state.isBusy)
            .help("Update \(mod.displayName)\(state.latestVersionText(for: mod))")
        }
    }
}

/// Link a pak to its upstream page by hand — the fallback for mods whose hash neither service
/// recognises, which is the normal outcome for anything distributed inside a .zip.
struct LinkModSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let mod: Mod

    @State private var query = ""
    @State private var source: RemoteMod.Source = .nexus
    @State private var results: [RemoteMod] = []
    @State private var searching = false
    @State private var selected: RemoteMod?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Link “\(mod.displayName)”").font(.headline)
            Text("Find this mod on Nexus or mod.io so the manager can tell you when a newer version is published. Whatever is published now is treated as the version you already have.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Picker("", selection: $source) {
                    Text("Nexus Mods").tag(RemoteMod.Source.nexus)
                    Text("mod.io").tag(RemoteMod.Source.modio)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 200)

                TextField("Search by name…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search() }
                Button("Search") { search() }.disabled(searching)
            }

            if searching {
                ProgressView().frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 20)
            } else {
                List(results, selection: Binding(
                    get: { selected?.id },
                    set: { id in selected = results.first { $0.id == id } })
                ) { remote in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(remote.name).fontWeight(selected?.id == remote.id ? .semibold : .regular)
                        if !remote.author.isEmpty {
                            Text(remote.author).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(remote.id)
                }
                .frame(height: 240)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Link") {
                    if let selected { Task { await state.linkMod(mod, to: selected); dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear {
            query = mod.displayName
            search()
        }
    }

    private func search() {
        searching = true
        Task {
            defer { searching = false }
            do {
                switch source {
                case .nexus:  results = try await NexusClient(apiKey: state.nexusAPIKey).search(query)
                case .modio:  results = try await ModIOClient(apiKey: state.modioAPIKey).search(query)
                }
            } catch {
                results = []
                state.statusMessage = "Search failed: \(error.localizedDescription)"
            }
        }
    }
}


// MARK: Delete everything

/// Confirmation for the one action in the app that can't be undone from inside it.
///
/// Deliberately not a plain alert: this can remove tens of gigabytes across hundreds of files, and a
/// misclick on a default button is too cheap. The exact word has to be typed, and the sheet states
/// the count, the size and the folder being emptied.
struct DeleteAllSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    private let phrase = "DELETE"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Delete all \(state.mods.count) installed mods?", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.red)

            VStack(alignment: .leading, spacing: 6) {
                row("Mods", "\(state.mods.count)")
                row("Size on disk", state.installedSizeText)
                row("Folder", state.activeEnvironment?.modsFolder.path ?? "—")
            }
            .font(.caption)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

            Text("The .pak files are moved to the Trash, and the load order is cleared. Anything the volume refuses to trash is deleted outright.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Type \(phrase) to confirm").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $typed).textFieldStyle(.roundedBorder).frame(width: 180)
            }

            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Delete All Mods", role: .destructive) {
                    state.deleteAllMods()
                    dismiss()
                }
                .disabled(typed != phrase)
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
    }
}


// MARK: Copying mods between installs

/// Copy mods from one BG3 install into another.
///
/// The case this exists for: a load order built under CrossOver names mods the native install
/// doesn't have, so applying it silently skips them. Rather than hunting those down again, take them
/// from the install that already has them. Direction is whichever install is *active* — to go the
/// other way, switch installs at the top of the window and open this again.
struct SyncModsSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    enum Scope: Hashable { case all, profile(UUID) }

    @State private var source: GameEnvironment?
    @State private var scope: Scope = .all
    @State private var selection = Set<String>()
    @State private var skipScriptExtender = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Copy mods into “\(state.activeEnvironment?.label ?? "this install")”").font(.headline)

            HStack {
                Picker("From", selection: $source) {
                    Text("Choose an install…").tag(GameEnvironment?.none)
                    ForEach(state.otherEnvironments) { env in
                        Text(env.label).tag(GameEnvironment?.some(env))
                    }
                }
                .frame(maxWidth: 340)
                if state.isScanningSync { ProgressView().controlSize(.small) }
                Spacer()
            }

            Picker("Show", selection: $scope) {
                Text("Everything missing here").tag(Scope.all)
                ForEach(state.profiles) { profile in
                    Text("Only what “\(profile.name)” needs").tag(Scope.profile(profile.id))
                }
            }
            .frame(maxWidth: 420)

            if state.wouldNeedScriptExtenderApply {
                Toggle("Skip mods that need the Script Extender", isOn: $skipScriptExtender)
                    .font(.caption)
                    .help("Script Extender mods only run under CrossOver, so they do nothing on the native Mac build.")
            }

            let shown = visible
            List(shown, id: \.id, selection: $selection) { mod in
                HStack {
                    Toggle("", isOn: Binding(
                        get: { selection.contains(mod.id) },
                        set: { on in if on { selection.insert(mod.id) } else { selection.remove(mod.id) } })
                    ).labelsHidden().toggleStyle(.checkbox)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(mod.displayName)
                        HStack(spacing: 6) {
                            Text(mod.fileURL.lastPathComponent)
                            if !mod.parts.isEmpty { Text("· \(mod.parts.count + 1) files") }
                            if state.wouldNeedScriptExtender(mod) {
                                Text("· needs Script Extender").foregroundStyle(.orange)
                            }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .frame(height: 260)

            HStack(spacing: 8) {
                Button("Select All") { selection = Set(shown.map(\.id)) }
                Button("Select None") { selection.removeAll() }
                Spacer()
                Text(summary(shown)).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Copy \(selection.count) Mod\(selection.count == 1 ? "" : "s")") {
                    state.copyMods(shown.filter { selection.contains($0.id) })
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty || state.isScanningSync)
            }
        }
        .padding(16)
        .frame(width: 620)
        .onChange(of: source) { env in
            selection.removeAll()
            guard let env else { state.syncCandidates = []; return }
            Task { await state.loadSyncCandidates(from: env) }
        }
        .onAppear { source = state.otherEnvironments.first }
    }

    /// Candidates after the scope filter and the Script Extender toggle.
    private var visible: [Mod] {
        var list = state.syncCandidates
        if case .profile(let id) = scope, let profile = state.profiles.first(where: { $0.id == id }) {
            let wanted = Set(profile.entries.map { $0.uuid.lowercased() })
            list = list.filter { mod in mod.meta.map { wanted.contains($0.uuid.lowercased()) } ?? false }
        }
        if skipScriptExtender, state.wouldNeedScriptExtenderApply {
            list = list.filter { !state.wouldNeedScriptExtender($0) }
        }
        return list
    }

    private func summary(_ shown: [Mod]) -> String {
        let chosen = shown.filter { selection.contains($0.id) }
        let bytes = ModRepository.totalSize(of: chosen.flatMap(\.allFiles))
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "\(shown.count) available · \(chosen.count) selected · \(size)"
    }
}


// MARK: Saves

/// Manage BG3 campaign saves: copy them between the installs on this Mac, stage them for another
/// machine, or delete them.
///
/// Saves are folders named `<campaignUUID>__<Label>`, and there are hundreds of them — mostly
/// autosaves — so the list leads with filtering and bulk selection rather than per-row buttons.
struct SavesView: View {
    @EnvironmentObject var state: AppState

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", manual = "Manual only", auto = "Autosaves", honour = "Honour Mode"
        var id: String { rawValue }
    }

    @State private var selection = Set<String>()
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var overwrite = false
    @State private var confirmingDelete = false
    @State private var copyTarget: GameEnvironment?
    @State private var loaded = false
    @State private var grouped = true
    @State private var expanded = Set<String>()

    var body: some View {
        VStack(spacing: 8) {
            controls
            if state.isLoadingSaves {
                ProgressView("Reading saves…").frame(maxHeight: .infinity)
            } else if state.saves.isEmpty {
                ContentUnavailableLikeView(
                    icon: "tray", tint: .secondary,
                    title: "No saves here",
                    message: "This install has no campaign saves in PlayerProfiles/…/Savegames/Story.",
                    messageFont: state.descriptionFont)
            } else {
                if grouped { groupedList } else { list }
                footer
            }
        }
        .task(id: state.activeEnvironment?.id) {
            selection.removeAll()
            expanded.removeAll()
            await state.loadSaves()
            // Open the character you played last; the rest stay collapsed.
            if let newest = campaigns.first { expanded.insert(newest.id) }
            loaded = true
        }
        .confirmationDialog(deletePrompt, isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Move \(selection.count) Save\(selection.count == 1 ? "" : "s") to Trash", role: .destructive) {
                Task { await state.deleteSaves(selected); selection.removeAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves go to the Trash, so you can put them back until you empty it.")
        }
    }

    // MARK: Pieces

    private var controls: some View {
        VStack(spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("Saves").font(.headline)
                        Text("\(visible.count)")
                            .font(.caption).monospacedDigit()
                            .padding(.horizontal, 7).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Text("\(state.activeEnvironment?.label ?? "—") · \(state.savesTotalSizeText) total")
                        .font(state.detailFont).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await state.loadSaves() } } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
            }

            HStack(spacing: 8) {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 380)

                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search character, save name or campaign…", text: $search)
                    .textFieldStyle(.roundedBorder)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Toggle("Group", isOn: $grouped)
                    .toggleStyle(.checkbox)
                    .help("Group saves by character, the way BG3's load screen does")
            }
        }
        .padding(.horizontal, 12).padding(.top, 8)
    }

    /// Saves grouped by character, the way BG3's own load screen presents them. Collapsed by
    /// default — 171 saves in one flat list is what made this hard to read in the first place — with
    /// the most recently played character open, and every matching group opened while searching.
    private var groupedList: some View {
        List {
            ForEach(campaigns) { campaign in
                DisclosureGroup(isExpanded: expansion(for: campaign.id)) {
                    ForEach(campaign.saves) { save in row(save) }
                } label: {
                    campaignHeader(campaign)
                }
            }
        }
        .listStyle(.inset)
    }

    private func campaignHeader(_ campaign: SaveCampaign) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(campaign.name).fontWeight(.semibold)
                Text(campaign.subtitle).font(state.detailFont).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Select") { selection.formUnion(campaign.saves.map(\.id)) }
                .buttonStyle(.borderless).font(state.detailFont)
                .help("Add this character's saves to the selection")
        }
        .padding(.vertical, 1)
    }

    private func expansion(for id: String) -> Binding<Bool> {
        Binding(
            get: { !search.trimmingCharacters(in: .whitespaces).isEmpty || expanded.contains(id) },
            set: { open in if open { expanded.insert(id) } else { expanded.remove(id) } })
    }

    private var list: some View {
        List(visible, id: \.id, selection: $selection) { save in row(save, showCharacter: true) }
            .listStyle(.inset)
    }

    private func row(_ save: SaveGame, showCharacter: Bool = false) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { selection.contains(save.id) },
                set: { on in if on { selection.insert(save.id) } else { selection.remove(save.id) } })
            ).labelsHidden().toggleStyle(.checkbox)

            SaveThumbnail(url: save.screenshot)

            VStack(alignment: .leading, spacing: 1) {
                Text(save.displayName).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 6) {
                    if showCharacter { Text(save.characterName); Text("·") }
                    if let when = save.modifiedAt { Text(Self.stamp.string(from: when)) }
                    Text("·")
                    Text(ByteCountFormatter.string(fromByteCount: save.bytes, countStyle: .file))
                    if save.isHonourMode { Text("· Honour").foregroundStyle(.orange) }
                }
                .font(state.detailFont).foregroundStyle(.secondary)
            }
            Spacer()
            Button { NSWorkspace.shared.activateFileViewerSelecting([save.folderURL]) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless).help("Reveal in Finder")
        }
        .padding(.vertical, 2)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Select All") { selection = Set(visible.map(\.id)) }
            Button("Select None") { selection.removeAll() }
            Toggle("Overwrite existing", isOn: $overwrite)
                .help("Replace saves that already exist at the destination instead of skipping them")

            Spacer()
            Text(selectionSummary).font(state.detailFont).foregroundStyle(.secondary)

            if !state.otherEnvironments.isEmpty {
                Menu {
                    ForEach(state.otherEnvironments) { env in
                        Button("Copy to \(env.label)") {
                            Task { await state.copySaves(selected, to: env, overwrite: overwrite) }
                        }
                    }
                } label: { Label("Copy to Install", systemImage: "arrow.left.arrow.right") }
                .disabled(selection.isEmpty || state.isBusy)
                .frame(width: 170)
            }

            Button { exportSaves() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                .disabled(selection.isEmpty || state.isBusy)

            Button(role: .destructive) { confirmingDelete = true } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selection.isEmpty || state.isBusy)
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    // MARK: Data

    private var visible: [SaveGame] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return state.saves.filter { save in
            switch filter {
            case .all:    break
            case .manual: if save.isAutoSave { return false }
            case .auto:   if !save.isAutoSave { return false }
            case .honour: if !save.isHonourMode { return false }
            }
            guard !q.isEmpty else { return true }
            return save.displayName.localizedCaseInsensitiveContains(q)
                || save.characterName.localizedCaseInsensitiveContains(q)
                || save.campaignID.localizedCaseInsensitiveContains(q)
        }
    }

    /// Visible saves bucketed by character, most recently played first.
    private var campaigns: [SaveCampaign] {
        let buckets = Dictionary(grouping: visible, by: \.characterName)
        return buckets.map { name, saves in
            let ordered = saves.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
            return SaveCampaign(name: name, saves: ordered)
        }
        .sorted { ($0.newest ?? .distantPast) > ($1.newest ?? .distantPast) }
    }

    private var selected: [SaveGame] { visible.filter { selection.contains($0.id) } }

    private var selectionSummary: String {
        let bytes = selected.reduce(Int64(0)) { $0 + $1.bytes }
        return "\(selected.count) selected · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }

    private var deletePrompt: String {
        let bytes = selected.reduce(Int64(0)) { $0 + $1.bytes }
        return "Delete \(selected.count) save\(selected.count == 1 ? "" : "s") (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))?"
    }

    private func exportSaves() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose a staging folder to copy these saves into"
        panel.prompt = "Export Here"
        if !state.saveExportPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: state.saveExportPath)
        }
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let chosen = selected
        Task { await state.exportSaves(chosen, to: dir, overwrite: overwrite) }
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
}

/// The save's own screenshot, which is how a row becomes recognisable — the folder names are UUIDs
/// and the labels are mostly "AutoSave_4".
struct SaveThumbnail: View {
    let url: URL?

    var body: some View {
        Group {
            if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "photo").font(.caption2).foregroundStyle(.secondary))
            }
        }
        .frame(width: 56, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}


/// A character's saves, grouped the way BG3's load screen groups them.
struct SaveCampaign: Identifiable {
    var id: String { name }
    let name: String
    let saves: [SaveGame]

    var newest: Date? { saves.compactMap(\.modifiedAt).max() }
    var oldest: Date? { saves.compactMap(\.modifiedAt).min() }
    var bytes: Int64 { saves.reduce(0) { $0 + $1.bytes } }

    /// "12 saves · 1.4 GB · last played 24 Aug 2026" — with the span when a playthrough covers days.
    var subtitle: String {
        var parts = ["\(saves.count) save\(saves.count == 1 ? "" : "s")",
                     ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)]
        if let newest {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
            parts.append("last played \(f.string(from: newest))")
            if let oldest, !Calendar.current.isDate(oldest, inSameDayAs: newest) {
                let d = DateFormatter(); d.dateStyle = .medium; d.timeStyle = .none
                parts.append("started \(d.string(from: oldest))")
            }
        }
        return parts.joined(separator: " · ")
    }
}
