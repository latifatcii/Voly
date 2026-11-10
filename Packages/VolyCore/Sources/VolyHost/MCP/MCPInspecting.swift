import Foundation
import VolyModels
import VolyProtocol

/// Where an app runs. Decides a few words in what agents are told
/// ("simulator" or "emulator", points or dp) and how the whole display is
/// captured; everything else is the same protocol.
public enum MCPPlatform: String, Sendable, Equatable {
    case iOS
    case android
}

/// An app Voly knows how to talk to.
public struct MCPApp: Sendable, Equatable {
    /// Opaque handle, valid while that process lives.
    public let id: String
    public let name: String
    public let bundleIdentifier: String?
    public let pid: Int32?
    public let simulatorUDID: String?
    /// Name of the simulator it runs in, e.g. `iPhone 16 Pro`.
    public let simulatorName: String?
    /// The app Voly's own window is showing right now.
    public let isShownInVoly: Bool
    /// For an Android app, `simulatorUDID` is the device's adb serial and
    /// `bundleIdentifier` the package name.
    public let platform: MCPPlatform

    public init(
        id: String, name: String, bundleIdentifier: String?, pid: Int32?,
        simulatorUDID: String?, simulatorName: String?, isShownInVoly: Bool,
        platform: MCPPlatform = .iOS
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.pid = pid
        self.simulatorUDID = simulatorUDID
        self.simulatorName = simulatorName
        self.isShownInVoly = isShownInVoly
        self.platform = platform
    }
}

public struct MCPSimulator: Sendable, Equatable {
    public let udid: String
    public let name: String
    /// e.g. `iOS 18.3`
    public let runtime: String
    /// Whether apps launched in it get the Voly agent, in words.
    public let integration: String
    public let isIntegrationActive: Bool
    /// Bundle identifiers of apps that are running without the agent
    /// (started before Voly was); they need a relaunch to be inspected.
    public let appsWithoutAgent: [String]
    /// `.android` for an emulator or device reached through adb; `udid` is
    /// then its adb serial.
    public let platform: MCPPlatform

    public init(
        udid: String, name: String, runtime: String, integration: String,
        isIntegrationActive: Bool, appsWithoutAgent: [String], platform: MCPPlatform = .iOS
    ) {
        self.udid = udid
        self.name = name
        self.runtime = runtime
        self.integration = integration
        self.isIntegrationActive = isIntegrationActive
        self.appsWithoutAgent = appsWithoutAgent
        self.platform = platform
    }
}

public struct MCPOverview: Sendable, Equatable {
    public let simulators: [MCPSimulator]
    public let apps: [MCPApp]

    public init(simulators: [MCPSimulator], apps: [MCPApp]) {
        self.simulators = simulators
        self.apps = apps
    }
}

/// How much the user lets AI agents do through Voly.
public enum MCPAccess: Sendable, Equatable {
    case off
    /// Look, but change nothing in the app.
    case readOnly
    case full
}

/// What the MCP tools need from a running Voly. Implemented by the app on
/// top of its inspector session; faked in tests.
public protocol MCPInspecting: Sendable {
    var access: MCPAccess { get async }
    /// The apps known right now, without looking for new ones.
    func apps() async -> [MCPApp]
    /// Look again for simulators and apps, then report both.
    func overview() async -> MCPOverview
    /// Send one inspector command to an app and wait for its answer.
    func send(_ command: Command, to appID: String) async throws -> Response
    /// The view selected in Voly's window, if any.
    func selection() async -> (appID: String, viewID: ObjectID)?
    /// Select a view in Voly's window and highlight it in the simulator,
    /// switching Voly to that app if it is showing another.
    func select(view: ObjectID, in appID: String) async throws
    /// An agent changed something in this app; Voly's window should catch up.
    func appDidChange(_ appID: String) async
    /// Terminate the app and start it again with the Voly agent loaded.
    func relaunch(bundleIdentifier: String, simulatorUDID: String) async throws
    /// A tool was called — for the "an agent is looking" indicator.
    func noteToolCall(_ name: String) async
    /// PNG of the whole display an app is shown on, for the platforms Voly
    /// captures itself (Android, through adb). Nil means "not mine": the
    /// caller falls back to the simulator capture.
    func captureDisplay(of app: MCPApp) async throws -> Data?
}

public extension MCPInspecting {
    func captureDisplay(of app: MCPApp) async throws -> Data? { nil }
}
