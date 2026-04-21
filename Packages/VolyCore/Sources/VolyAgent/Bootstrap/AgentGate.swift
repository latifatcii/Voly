#if canImport(UIKit) || os(macOS)
import Foundation

public enum AgentGate {
    public static let sdkEnvVar = "VOLY_AGENT_ENABLED"
    public static let sdkArg = "--voly-agent-enabled"
    public static let disableEnvVar = "VOLY_DISABLE"

    /// SDK path: `VolyAgent.start()` / `VolyAgent.wrap(original:)` only bootstrap
    /// when the app opts in via env var or launch argument, and only in DEBUG.
    public static var isSDKEnabled: Bool {
        #if DEBUG
        return isSDKEnabled(
            environment: ProcessInfo.processInfo.environment,
            args: CommandLine.arguments
        )
        #else
        return false
        #endif
    }

    public static func isSDKEnabled(environment: [String: String], args: [String]) -> Bool {
        if environment[sdkEnvVar] == "1" { return true }
        if args.contains(sdkArg) { return true }
        return false
    }

    /// Injection path: the dylib loader calls this before bootstrapping.
    /// Default-on; escape hatch is `VOLY_DISABLE=1`.
    public static var isInjectionEnabled: Bool {
        isInjectionEnabled(environment: ProcessInfo.processInfo.environment)
    }

    public static func isInjectionEnabled(environment: [String: String]) -> Bool {
        environment[disableEnvVar] != "1"
    }
}
#endif
