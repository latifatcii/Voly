import Foundation

/// Which simulators the user wants runtime integration in.
///
/// The default is every booted simulator, so there is nothing to switch on
/// before inspecting an app; individual simulators can be opted out. Turning
/// "all" off leaves a hand-picked set instead.
public struct IntegrationPreference: Equatable, Sendable {
    public static let allSimulatorsKey = "voly.integration.allSimulators"
    public static let enabledKey = "voly.integration.enabledSimulators"
    public static let optedOutKey = "voly.integration.disabledSimulators"

    /// Integrate with every booted simulator except `optedOut`.
    public var allSimulators: Bool
    /// Hand-picked simulators, used only when `allSimulators` is off.
    public var enabled: Set<String>
    /// Simulators excluded while `allSimulators` is on.
    public var optedOut: Set<String>

    public init(allSimulators: Bool = true, enabled: Set<String> = [], optedOut: Set<String> = []) {
        self.allSimulators = allSimulators
        self.enabled = enabled
        self.optedOut = optedOut
    }

    public func wants(_ udid: String) -> Bool {
        allSimulators ? !optedOut.contains(udid) : enabled.contains(udid)
    }

    /// The per-simulator switch. Recorded for both modes so flipping "all"
    /// later doesn't silently undo a choice made for this simulator.
    public mutating func set(_ wanted: Bool, for udid: String) {
        if wanted {
            enabled.insert(udid)
            optedOut.remove(udid)
        } else {
            enabled.remove(udid)
            optedOut.insert(udid)
        }
    }

    /// Switch between "all" and hand-picked without changing what is
    /// integrated right now: going manual keeps the currently active
    /// simulators; going back to "all" keeps earlier opt-outs.
    public mutating func setAllSimulators(_ all: Bool, currentlyActive: Set<String>) {
        guard all != allSimulators else { return }
        if !all { enabled = currentlyActive }
        allSimulators = all
    }

    // MARK: - Persistence

    public init(defaults: UserDefaults) {
        self.init(
            // Absent key == never chosen == the default (all simulators).
            allSimulators: defaults.object(forKey: Self.allSimulatorsKey) as? Bool ?? true,
            enabled: Set(defaults.stringArray(forKey: Self.enabledKey) ?? []),
            optedOut: Set(defaults.stringArray(forKey: Self.optedOutKey) ?? [])
        )
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(allSimulators, forKey: Self.allSimulatorsKey)
        defaults.set(enabled.sorted(), forKey: Self.enabledKey)
        defaults.set(optedOut.sorted(), forKey: Self.optedOutKey)
    }
}
