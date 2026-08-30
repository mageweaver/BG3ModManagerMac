import SwiftUI

/// Detects and repairs mods whose custom materials ship Windows-only compiled
/// shaders (DX11/DX12/Vulkan, no Metal) — on the native Mac build these hang
/// the game the first time their visual loads. See ShaderCompatFixer.
struct MacFixView: View {
    @EnvironmentObject var state: AppState

    private var results: [ShaderCompatFixer.ScanResult] { state.shaderScanResults }
    private var fixableCount: Int {
        results.filter { $0.fixable && !state.fixedShaderPaks.contains($0.pakURL.path) }.count
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            Divider()
            if results.isEmpty {
                emptyState
            } else {
                resultList
            }
            footer
        }
        .padding(12)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Mac Compatibility").font(.headline)
                Text("Mods built with the Windows toolkit ship shaders for DX11/DX12/Vulkan only. "
                     + "BG3 on the Mac renders with Metal, so the game hangs the first time such a "
                     + "mod's hair, armor or character actually appears. The fix removes the mod's "
                     + "Windows-only material overrides so the game falls back to its own Metal "
                     + "shaders — the mod keeps its models and content, rendered with standard shading.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button {
                    state.scanShaderCompat()
                } label: {
                    Label(state.isScanningShaders ? "Scanning…" : "Scan Installed Mods",
                          systemImage: "magnifyingglass")
                }
                .disabled(state.isScanningShaders || state.activeEnvironment == nil)

                if fixableCount > 1 {
                    Button {
                        state.fixAllShaderCompat()
                    } label: {
                        Label("Fix All (\(fixableCount))", systemImage: "wrench.and.screwdriver")
                    }
                    .disabled(state.isBusy)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: state.shaderScanRan ? "checkmark.seal" : "wrench.and.screwdriver")
                .font(.system(size: 36)).foregroundStyle(.secondary)
            Text(state.shaderScanRan
                 ? "No mods with Windows-only shaders found."
                 : "Scan your Mods folder to find mods that will hang or render broken on the Mac.")
                .foregroundStyle(.secondary)
            if state.isScanningShaders {
                ProgressView().padding(.top, 4)
                Text(state.shaderScanProgress).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var resultList: some View {
        List(results) { r in
            HStack(alignment: .center, spacing: 10) {
                statusIcon(for: r)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.displayName).font(.body)
                    Text(detailLine(for: r)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                actionButtons(for: r)
            }
            .padding(.vertical, 2)
        }
    }

    private func statusIcon(for r: ShaderCompatFixer.ScanResult) -> some View {
        let fixed = state.fixedShaderPaks.contains(r.pakURL.path)
        let (name, color): (String, Color) =
            fixed || !r.affected ? ("checkmark.circle.fill", .green)
            : r.fixable          ? ("wrench.and.screwdriver.fill", .orange)
            :                      ("exclamationmark.triangle.fill", .red)
        return Image(systemName: name).foregroundStyle(color).frame(width: 22)
    }

    private func detailLine(for r: ShaderCompatFixer.ScanResult) -> String {
        if state.fixedShaderPaks.contains(r.pakURL.path) || !r.affected {
            return "Fixed — using base-game Metal shaders. Original backed up."
        }
        let plats = r.platforms.sorted().joined(separator: "/")
        var line = "\(r.shaderCount) Windows-only shaders (\(plats)), \(r.materials.count) material\(r.materials.count == 1 ? "" : "s")"
        if r.fixable {
            line += " — all override base-game materials, safe to fix"
        } else if r.customMaterialCount > 0 {
            line += " — \(r.customMaterialCount) custom material\(r.customMaterialCount == 1 ? "" : "s") with no base-game fallback; can't auto-fix"
        } else {
            line += " — no material definitions found; can't auto-fix"
        }
        return line
    }

    @ViewBuilder
    private func actionButtons(for r: ShaderCompatFixer.ScanResult) -> some View {
        let fixed = state.fixedShaderPaks.contains(r.pakURL.path)
        if fixed {
            Button("Restore Original") { state.restoreShaderFix(r) }
                .disabled(state.isBusy)
        } else if r.fixable {
            Button {
                state.fixShaderCompat(r)
            } label: {
                Label("Fix", systemImage: "wrench.and.screwdriver")
            }
            .disabled(state.isBusy)
        }
    }

    private var footer: some View {
        HStack {
            if !state.shaderScanProgress.isEmpty {
                Text(state.shaderScanProgress).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if state.shaderScanRan {
                Text("Backups: ~/Library/Application Support/BG3ModManagerMac/ShaderFixBackups")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
