import SwiftUI

@main
struct VolyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Empty Settings scene — satisfies the App protocol without opening
        // a window. AppCoordinator (via AppDelegate) owns the inspector panel.
        Settings { EmptyView() }
    }
}
