import SwiftUI

@main
struct VolyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = InspectorSession()

    var body: some Scene {
        WindowGroup("Voly") {
            InspectorRootView(session: session)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1400, height: 900)
        .defaultPosition(.center)
        .commands {
            CommandGroup(after: .appInfo) {
                Divider()
                Button("Reconnect") { Task { await session.reconnect() } }
                    .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }
}
