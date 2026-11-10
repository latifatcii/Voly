// Packages/VolyCore/Sources/VolyHost/DiscoveredAgent.swift
import Foundation

public struct DiscoveredAgent: Equatable, Hashable, Sendable {
    public let deviceUDID: String
    public let bundleIdentifier: String
    public let processName: String
    public let pid: Int32
    public let port: UInt16
    public let issuedAt: Date
    /// Session token the agent expects in the handshake (injected agents).
    public let token: String?

    public init(deviceUDID: String, bundleIdentifier: String, processName: String,
                pid: Int32, port: UInt16, issuedAt: Date, token: String? = nil) {
        self.deviceUDID = deviceUDID
        self.bundleIdentifier = bundleIdentifier
        self.processName = processName
        self.pid = pid
        self.port = port
        self.issuedAt = issuedAt
        self.token = token
    }
}
