import SwiftUI

@main
enum VolyMain {
    static func main() {
        // Started by an AI agent as its MCP server: serve it and never
        // become an app (see `MCPRelay`).
        if CommandLine.arguments.dropFirst().contains(MCPRelay.flag) {
            MCPRelay.run()
        }
        VolyApp.main()
    }
}

struct VolyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Empty Settings scene — satisfies the App protocol without opening
        // a window. AppCoordinator (via AppDelegate) owns the inspector panel.
        Settings { EmptyView() }
    }
}
