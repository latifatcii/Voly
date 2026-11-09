import Foundation

/// Which app launches the launch bridge may add the agent to.
public struct InjectionPolicy: Codable, Equatable, Sendable {
    /// Also instrument `com.apple.*` apps. Off by default: the point is the
    /// developer's own apps.
    public var includeSystemApps: Bool
    /// When non-empty, *only* these bundle identifiers are instrumented.
    public var allowedBundleIDs: [String]
    /// Never instrumented, even if allowed above.
    public var excludedBundleIDs: [String]

    public init(
        includeSystemApps: Bool = false,
        allowedBundleIDs: [String] = [],
        excludedBundleIDs: [String] = []
    ) {
        self.includeSystemApps = includeSystemApps
        self.allowedBundleIDs = allowedBundleIDs
        self.excludedBundleIDs = excludedBundleIDs
    }

    /// Mirrors the bridge's own decision so the UI can say up front whether
    /// an app will be instrumented on its next launch.
    public func allows(bundleIdentifier: String) -> Bool {
        if excludedBundleIDs.contains(bundleIdentifier) { return false }
        if !allowedBundleIDs.isEmpty { return allowedBundleIDs.contains(bundleIdentifier) }
        return includeSystemApps || !bundleIdentifier.hasPrefix("com.apple.")
    }
}

/// The plist `VolyLaunchBridge` reads inside the simulator's runningboardd.
/// One per simulator; rewritten atomically whenever the policy changes and
/// picked up by the bridge on the next app launch.
public struct BridgeConfig: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let fileName = "bridge.plist"

    public var version: Int
    public var enabled: Bool
    public var simulatorUDID: String
    public var agentPath: String
    public var includeSystemApps: Bool
    public var allowedBundleIDs: [String]
    public var excludedBundleIDs: [String]

    public init(enabled: Bool, simulatorUDID: String, agentPath: String, policy: InjectionPolicy) {
        self.version = Self.currentVersion
        self.enabled = enabled
        self.simulatorUDID = simulatorUDID
        self.agentPath = agentPath
        self.includeSystemApps = policy.includeSystemApps
        self.allowedBundleIDs = policy.allowedBundleIDs
        self.excludedBundleIDs = policy.excludedBundleIDs
    }

    public var policy: InjectionPolicy {
        InjectionPolicy(
            includeSystemApps: includeSystemApps,
            allowedBundleIDs: allowedBundleIDs,
            excludedBundleIDs: excludedBundleIDs
        )
    }

    public func write(to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try encoder.encode(self).write(to: url, options: [.atomic])
    }

    public static func read(from url: URL) -> BridgeConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(BridgeConfig.self, from: data)
    }
}

/// Written by the bridge when it loads; tells the host which runningboardd
/// instance carries it and whether the launch seam exists on that runtime.
public struct BridgeStatus: Codable, Equatable, Sendable {
    public static let fileName = "bridge-status.plist"

    public let bridgeVersion: String
    public let pid: Int32
    public let hookInstalled: Bool
    public let simulatorUDID: String
    public let loadedAt: Date
    public let runtimeVersion: String?
    public let runtimeBuild: String?
    public let failureReason: String?

    public static func read(from url: URL) -> BridgeStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(BridgeStatus.self, from: data)
    }
}
