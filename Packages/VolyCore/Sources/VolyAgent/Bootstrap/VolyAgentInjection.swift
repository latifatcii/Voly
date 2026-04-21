// Packages/VolyCore/Sources/VolyAgent/Bootstrap/VolyAgentInjection.swift
#if canImport(UIKit)
import Foundation
import OSLog

nonisolated(unsafe) private let log = Logger(
    subsystem: "com.latifatci.VolyAgent",
    category: "Injection"
)

/// Called by `VolyAgentLoader.m` on the main thread after
/// `UIApplicationDidFinishLaunchingNotification` fires. Never called elsewhere.
///
/// Must be nonisolated — dyld's constructor + NSNotificationCenter don't know
/// about Swift's main actor. We hop to the main actor internally.
@_cdecl("voly_agent_injected_bootstrap")
public func voly_agent_injected_bootstrap() {
    guard AgentGate.isInjectionEnabled else {
        log.info("VOLY_DISABLE set — skipping injection bootstrap")
        return
    }
    log.notice("injection bootstrap starting")
    // NSNotificationCenter delivers on the main queue because we registered
    // with queue:.main — so we're already on the main thread here.
    MainActor.assumeIsolated {
        VolyAgentRuntime.shared.bootstrap(mode: .injected)
    }
}
#endif
