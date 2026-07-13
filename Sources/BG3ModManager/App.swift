import SwiftUI

@main
struct BG3ModManagerApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("BG3 Mod Manager for Mac") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { state.bootstrap() }
                // Nexus "Mod Manager Download" buttons launch the app with an nxm:// URL.
                .onOpenURL { url in
                    Task { await state.handleNXM(url) }
                }
        }
        .windowStyle(.titleBar)
    }
}
