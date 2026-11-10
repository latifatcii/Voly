import SwiftUI
import VolyModels
import VolyProtocol

/// Runtime actions in the inspector's footer, next to Pick and Refresh:
/// UIKit navigation, language override, screenshots.
struct RuntimeActionsBar: View {
    @Bindable var session: InspectorSession
    /// Remembered across language switches so "Arabic strings, LTR layout"
    /// stays a one-click test.
    @State private var layoutDirection: LayoutDirectionMode = .followLanguage

    private var isConnected: Bool { session.state.connectionStatus == .connected }
    private var capabilities: AgentCapabilities? { session.state.agent?.capabilities }

    var body: some View {
        navigationButtons
        localizationMenu
        screenshotMenu
    }

    // MARK: - Navigation

    @ViewBuilder
    private var navigationButtons: some View {
        navigationButton(.dismiss, title: "Dismiss", symbol: "xmark.rectangle")
        navigationButton(.pop, title: "Pop", symbol: "chevron.backward")
        navigationButton(.popToRoot, title: "Pop to Root", symbol: "chevron.backward.2")
    }

    private func navigationButton(_ action: NavigationAction, title: String, symbol: String) -> some View {
        let navigation = session.state.navigation
        let available = isConnected && navigation.isAvailable(action)
        return Button {
            Task { await session.navigate(action) }
        } label: {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(VolyIconButtonStyle())
        .disabled(!available)
        .help(available ? title : (navigation.unavailableReasons[action.rawValue] ?? title))
    }

    // MARK: - Localization

    private var localizationMenu: some View {
        let localization = session.state.localization
        let active = localization?.activeOverride
        return Menu {
            Button {
                Task { await session.setLocalization(language: nil, layoutDirection: .system) }
            } label: {
                menuLabel("System / Default", checked: active == nil)
            }
            if let localization, !localization.available.isEmpty {
                Divider()
                ForEach(localization.available) { language in
                    Button {
                        Task { await session.setLocalization(language: language.code, layoutDirection: layoutDirection) }
                    } label: {
                        menuLabel(
                            "\(language.displayName) (\(language.code))\(language.isRightToLeft ? " — RTL" : "")",
                            checked: active == language.code
                        )
                    }
                }
            }
            Divider()
            Picker("Layout Direction", selection: $layoutDirection) {
                Text("Follow Language").tag(LayoutDirectionMode.followLanguage)
                Text("Left to Right").tag(LayoutDirectionMode.leftToRight)
                Text("Right to Left").tag(LayoutDirectionMode.rightToLeft)
                Text("App Default").tag(LayoutDirectionMode.system)
            }
            Button("Refresh Supported UI") {
                Task { await session.refreshLocalizedUI() }
            }
            Button("Reset Localization") {
                Task { await session.setLocalization(language: nil, layoutDirection: .system) }
            }
            .disabled(active == nil)
        } label: {
            Image(systemName: "globe")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active == nil ? VolyTheme.dim : VolyTheme.selection)
                .frame(width: 26, height: 22)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isConnected || capabilities?.localization == false)
        .help(active.map { "Language override: \($0)" } ?? "Override the app's language")
        .onChange(of: layoutDirection) { _, mode in
            // Changing direction re-applies the current override with it.
            guard let active else { return }
            Task { await session.setLocalization(language: active, layoutDirection: mode) }
        }
    }

    private func menuLabel(_ title: String, checked: Bool) -> some View {
        HStack {
            Text(title)
            if checked { Image(systemName: "checkmark") }
        }
    }

    // MARK: - Screenshots

    private var screenshotMenu: some View {
        let hasSelection = session.state.selectedViewID != nil
        let agentShots = isConnected && capabilities?.screenshots != false
        return Menu {
            Button("Save Simulator Screen") { capture(.fullSimulator, .file) }
            Button("Save App Content") { capture(.application, .file) }
                .disabled(!agentShots)
            Button("Save Selected View") { capture(.selectedView, .file) }
                .disabled(!agentShots || !hasSelection)
            Divider()
            Button("Copy Simulator Screen") { capture(.fullSimulator, .clipboard) }
            Button("Copy App Content") { capture(.application, .clipboard) }
                .disabled(!agentShots)
            Button("Copy Selected View") { capture(.selectedView, .clipboard) }
                .disabled(!agentShots || !hasSelection)
            Divider()
            Button("Save To: \(session.screenshots.directory.lastPathComponent)…") {
                session.screenshots.chooseDirectory()
            }
        } label: {
            Image(systemName: "camera")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(VolyTheme.dim)
                .frame(width: 26, height: 22)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Capture the simulator screen, the app's content, or the selected view")
    }

    private func capture(_ mode: VolyScreenshotManager.Mode, _ destination: VolyScreenshotManager.Destination) {
        Task { await session.captureScreenshot(mode, to: destination) }
    }
}
