import Foundation

/// Runs the BG3SE-macOS setup end to end: clone the project, build the dylib, and point Steam at the
/// launcher.
///
/// BG3SE-macOS has no binary release — it is built from source against the Mac game binary — so
/// "install" here genuinely means running `git` and `cmake`. Each step streams its output so a build
/// that takes minutes doesn't look like a hang, and every step is separately re-runnable.
enum ScriptExtenderInstaller {

    // MARK: Prerequisites

    struct Prerequisites {
        var git: URL?
        var cmake: URL?
        var developerDir: String?

        var ready: Bool { git != nil && cmake != nil && developerDir != nil }

        var missing: [String] {
            var out: [String] = []
            if git == nil { out.append("git") }
            if cmake == nil { out.append("cmake") }
            if developerDir == nil { out.append("Xcode command line tools") }
            return out
        }

        /// What to tell the user to run, for whatever is absent.
        var remedy: String? {
            guard !ready else { return nil }
            var lines: [String] = []
            if developerDir == nil { lines.append("xcode-select --install") }
            if cmake == nil { lines.append("brew install cmake") }
            if git == nil { lines.append("xcode-select --install   # git ships with the command line tools") }
            return lines.joined(separator: "\n")
        }
    }

    static func checkPrerequisites() -> Prerequisites {
        Prerequisites(git: which("git"), cmake: which("cmake"), developerDir: developerDirectory())
    }

    /// Find a tool without assuming the app inherited a login shell's PATH — a GUI app generally has
    /// not. CMake in particular usually lives in its own .app bundle rather than on any PATH.
    private static func which(_ tool: String) -> URL? {
        var candidates = [
            "/usr/bin/\(tool)",
            "/opt/homebrew/bin/\(tool)",
            "/usr/local/bin/\(tool)",
            "/opt/local/bin/\(tool)",
        ]
        if tool == "cmake" {
            candidates.append("/Applications/CMake.app/Contents/bin/cmake")
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func developerDirectory() -> String? {
        guard let out = try? Shell.capture("/usr/bin/xcode-select", ["-p"]), !out.isEmpty else { return nil }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Install

    enum InstallError: LocalizedError {
        case missingTools([String])
        case stepFailed(String, Int32)
        case noDylib
        var errorDescription: String? {
            switch self {
            case .missingTools(let t): return "Missing \(t.joined(separator: ", "))."
            case .stepFailed(let s, let c): return "\(s) failed (exit \(c))."
            case .noDylib: return "The build finished but libbg3se.dylib wasn't produced."
            }
        }
    }

    /// Clone (or update) the project at `root` and build it. Safe to re-run: an existing checkout is
    /// fetched rather than re-cloned, and CMake reuses its build directory.
    static func install(into root: URL,
                        progress: @escaping @MainActor (String) -> Void) async throws -> ScriptExtenderMac.Installation {
        let tools = checkPrerequisites()
        guard tools.ready, let git = tools.git, let cmake = tools.cmake else {
            throw InstallError.missingTools(tools.missing)
        }

        let fm = FileManager.default
        let exists = fm.fileExists(atPath: root.appendingPathComponent(".git").path)

        if exists {
            await progress("Updating existing checkout at \(root.path)…")
            try await run(git, ["fetch", "--all", "--tags"], in: root, step: "git fetch", progress: progress)
            try await run(git, ["submodule", "update", "--init", "--recursive"], in: root,
                          step: "git submodule update", progress: progress)
        } else {
            await progress("Cloning BG3SE-macOS into \(root.path)…")
            try fm.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await run(git,
                          ["clone", "--recursive", ScriptExtenderMac.repository.absoluteString, root.lastPathComponent],
                          in: root.deletingLastPathComponent(),
                          step: "git clone", progress: progress)
        }

        let build = root.appendingPathComponent("build", isDirectory: true)
        try fm.createDirectory(at: build, withIntermediateDirectories: true)

        await progress("Configuring with CMake…")
        try await run(cmake, [".."], in: build, step: "cmake configure", progress: progress)

        await progress("Building — this is the slow part, several minutes is normal…")
        try await run(cmake, ["--build", ".", "--parallel"], in: build, step: "cmake build", progress: progress)

        guard let install = ScriptExtenderMac.inspect(root), install.isBuilt else {
            throw InstallError.noDylib
        }
        await progress("Built \(install.dylib?.lastPathComponent ?? "libbg3se.dylib").")
        return install
    }

    private static func run(_ tool: URL, _ args: [String], in cwd: URL, step: String,
                            progress: @escaping @MainActor (String) -> Void) async throws {
        let code = try await Shell.stream(tool, args, cwd: cwd) { line in
            await progress(line)
        }
        guard code == 0 else { throw InstallError.stepFailed(step, code) }
    }
}

// MARK: Steam launch options

/// Reads and writes the BG3 launch options Steam stores per account.
///
/// This is the step people miss: the dylib does nothing unless Steam starts the game through
/// `bg3w.sh`. Steam keeps that string in `localconfig.vdf` and rewrites the whole file when it
/// quits, so an edit made while Steam is running is discarded — hence the running check, and the
/// backup before touching anything.
enum SteamLaunchOptions {
    /// BG3's Steam app id.
    static let bg3AppID = "1086940"

    enum SteamError: LocalizedError {
        case steamRunning
        case noConfig
        case noAppEntry
        case malformed
        var errorDescription: String? {
            switch self {
            case .steamRunning: return "Quit Steam first — it rewrites its config when it exits, which would discard this change."
            case .noConfig:     return "Couldn't find Steam's localconfig.vdf for any account."
            case .noAppEntry:   return "Steam has no saved settings for Baldur's Gate 3 yet. Launch the game once from Steam, quit Steam, then try again."
            case .malformed:    return "Steam's config file wasn't in the expected format, so it was left untouched."
            }
        }
    }

    static var isSteamRunning: Bool {
        (try? Shell.capture("/bin/ps", ["-axco", "command"]))?
            .split(separator: "\n")
            .contains { $0.trimmingCharacters(in: .whitespaces) == "steam_osx" } ?? false
    }

    static func configFiles() -> [URL] {
        let fm = FileManager.default
        let userdata = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam/userdata")
        guard let accounts = try? fm.contentsOfDirectory(at: userdata, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles]) else { return [] }
        return accounts.map { $0.appendingPathComponent("config/localconfig.vdf") }
                       .filter { fm.fileExists(atPath: $0.path) }
    }

    /// Set BG3's launch options in every Steam account config on this Mac. Returns how many were changed.
    @discardableResult
    static func set(_ value: String) throws -> Int {
        guard !isSteamRunning else { throw SteamError.steamRunning }
        let configs = configFiles()
        guard !configs.isEmpty else { throw SteamError.noConfig }

        var changed = 0
        var sawAppEntry = false
        for config in configs {
            guard let text = try? String(contentsOf: config, encoding: .utf8) else { continue }
            guard let updated = try rewrite(text, launchOptions: value) else { continue }
            sawAppEntry = true
            guard updated != text else { changed += 1; continue }

            // Keep a copy: this file holds every per-game setting for the account, not just BG3.
            let backup = config.appendingPathExtension("bg3mm-backup")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: config, to: backup)

            try updated.write(to: config, atomically: true, encoding: .utf8)
            changed += 1
        }
        guard sawAppEntry else { throw SteamError.noAppEntry }
        return changed
    }

    /// Insert or replace `"LaunchOptions"` inside the app's block. Returns nil when this config has
    /// no block for BG3.
    ///
    /// Deliberately a targeted line edit rather than a VDF parse-and-reserialise: the file carries
    /// every setting for the account, and round-tripping it through a hand-written parser risks far
    /// more than the one key being changed.
    static func rewrite(_ text: String, launchOptions: String) throws -> String? {
        var lines = text.components(separatedBy: "\n")
        guard let header = appBlockHeader(in: lines) else { return nil }

        // The block opens on the line after the header.
        let open = header + 1
        guard open < lines.count, lines[open].trimmingCharacters(in: .whitespaces) == "{" else {
            throw SteamError.malformed
        }

        let indent = String(lines[open].prefix { $0 == "\t" || $0 == " " }) + "\t"
        let entry = "\(indent)\"LaunchOptions\"\t\t\"\(escape(launchOptions))\""

        // Walk to the matching close brace, tracking depth so nested blocks don't end it early.
        var depth = 0
        var index = open
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed == "{" { depth += 1 }
            if trimmed == "}" {
                depth -= 1
                if depth == 0 { break }
            }
            if depth == 1, trimmed.lowercased().hasPrefix("\"launchoptions\"") {
                lines[index] = entry          // replace the existing value
                return lines.joined(separator: "\n")
            }
            index += 1
        }
        guard depth == 0 else { throw SteamError.malformed }

        lines.insert(entry, at: open + 1)     // no existing key — add one at the top of the block
        return lines.joined(separator: "\n")
    }

    /// Find the line declaring BG3's app block: a bare `"1086940"` whose next line opens a block.
    /// The same id also appears as a plain value elsewhere in the file, which must not match.
    private static func appBlockHeader(in lines: [String]) -> Int? {
        for (i, line) in lines.enumerated() {
            guard line.trimmingCharacters(in: .whitespaces) == "\"\(bg3AppID)\"" else { continue }
            let next = i + 1
            guard next < lines.count, lines[next].trimmingCharacters(in: .whitespaces) == "{" else { continue }
            return i
        }
        return nil
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: Process helpers

enum Shell {
    /// Run a tool and return its combined output. For short, quick commands.
    static func capture(_ tool: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Run a tool, delivering output line by line as it arrives, and return its exit code.
    /// Used for clone and build, which take long enough that silence would read as a hang.
    static func stream(_ tool: URL, _ args: [String], cwd: URL,
                       onLine: @escaping (String) async -> Void) async throws -> Int32 {
        let process = Process()
        process.executableURL = tool
        process.arguments = args
        process.currentDirectoryURL = cwd

        // Give the child a usable PATH; a GUI app's environment is minimal.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:/Applications/CMake.app/Contents/bin"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        var buffer = Data()
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                    await onLine(line)
                }
            }
        }
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8), !line.isEmpty {
            await onLine(line)
        }

        process.waitUntilExit()
        return process.terminationStatus
    }
}
