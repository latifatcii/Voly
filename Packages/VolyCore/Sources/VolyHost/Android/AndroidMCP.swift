import Foundation
import VolyModels
import VolyProtocol

/// How Android devices and apps appear to the MCP tools — shared by
/// Voly.app's own bridge and the app-less one below, so both say the same.
public enum AndroidMCP {
    /// The handle of one agent: stable for the life of that process.
    public static func appID(serial: String, package: String, pid: Int32) -> String {
        "android:\(serial):\(package):\(pid)"
    }

    public static func appID(_ endpoint: AndroidAgentEndpoint) -> String {
        appID(serial: endpoint.serial, package: endpoint.package, pid: endpoint.pid)
    }

    public static func app(_ endpoint: AndroidAgentEndpoint, deviceName: String?, isShownInVoly: Bool) -> MCPApp {
        MCPApp(
            id: appID(endpoint), name: endpoint.label, bundleIdentifier: endpoint.package, pid: endpoint.pid,
            simulatorUDID: endpoint.serial, simulatorName: deviceName, isShownInVoly: isShownInVoly,
            platform: .android
        )
    }

    public static func simulator(_ status: AndroidDeviceStatus) -> MCPSimulator {
        MCPSimulator(
            udid: status.device.serial,
            name: status.device.displayName,
            runtime: status.device.runtimeName,
            integration: describe(status),
            isIntegrationActive: status.isIntegrationEnabled && status.error == nil,
            appsWithoutAgent: status.apps.filter { $0.state != .inspectable && $0.state != .excluded }.map(\.package),
            platform: .android
        )
    }

    public static func describe(_ status: AndroidDeviceStatus) -> String {
        if let error = status.error { return "Voly could not use this device: \(error)" }
        guard status.isIntegrationEnabled else {
            return "Voly is switched off for this device (its switch in Voly's Simulators tab)"
        }
        return "debuggable apps running here are inspectable"
    }
}

/// `MCPInspecting` straight on top of adb, without Voly.app: for `volyctl`
/// and scripted checks. Every command opens its own connection to the
/// agent through `send`.
public struct AndroidDirectInspector: MCPInspecting {
    public typealias Sender = @Sendable (AndroidAgentEndpoint, Command) async throws -> Response

    private let integration: AndroidIntegration
    private let serials: Set<String>?
    private let sender: Sender
    private let recent = RecentSnapshot()

    /// Listing devices and apps costs several adb round trips; one tool
    /// call asks more than once.
    private actor RecentSnapshot {
        private var value: (snapshot: AndroidSnapshot, takenAt: Date)?

        func get(maxAge: TimeInterval) -> AndroidSnapshot? {
            guard let value, Date().timeIntervalSince(value.takenAt) < maxAge else { return nil }
            return value.snapshot
        }

        func set(_ snapshot: AndroidSnapshot) {
            value = (snapshot, Date())
        }
    }

    /// - Parameter serials: only these devices, when set.
    public init(integration: AndroidIntegration, serials: Set<String>? = nil, send: @escaping Sender) {
        self.integration = integration
        self.serials = serials
        self.sender = send
    }

    public var access: MCPAccess { get async { .full } }

    private func snapshot(maxAge: TimeInterval = 3) async -> AndroidSnapshot {
        if let cached = await recent.get(maxAge: maxAge) { return cached }
        let fresh = await integration.refresh(wantsDevice: { _ in true }, allowsApp: { _ in true }, only: serials)
        await recent.set(fresh)
        return fresh
    }

    private func apps(in snapshot: AndroidSnapshot) -> [MCPApp] {
        snapshot.agents.map { endpoint in
            AndroidMCP.app(
                endpoint,
                deviceName: snapshot.devices.first { $0.device.serial == endpoint.serial }?.device.displayName,
                isShownInVoly: false
            )
        }
    }

    public func apps() async -> [MCPApp] {
        apps(in: await snapshot())
    }

    public func overview() async -> MCPOverview {
        // "Look again": never from the cache.
        let snapshot = await snapshot(maxAge: 0)
        return MCPOverview(simulators: snapshot.devices.map(AndroidMCP.simulator), apps: apps(in: snapshot))
    }

    public func send(_ command: Command, to appID: String) async throws -> Response {
        guard let endpoint = await snapshot().agents.first(where: { AndroidMCP.appID($0) == appID }) else {
            throw InspectorError.unavailable("That app is no longer running. list_apps shows what is inspectable now.")
        }
        let response = try await sender(endpoint, command)
        if case .error(let error) = response { throw error }
        return response
    }

    public func selection() async -> (appID: String, viewID: ObjectID)? { nil }

    public func select(view: ObjectID, in appID: String) async throws {
        _ = try await send(.highlight(objectID: view), to: appID)
    }

    public func appDidChange(_ appID: String) async {}

    public func relaunch(bundleIdentifier: String, simulatorUDID: String) async throws {
        try await integration.relaunch(serial: simulatorUDID, package: bundleIdentifier)
    }

    public func noteToolCall(_ name: String) async {}

    public func captureDisplay(of app: MCPApp) async throws -> Data? {
        guard app.platform == .android, let serial = app.simulatorUDID else { return nil }
        return try await integration.screenshot(serial: serial)
    }
}
