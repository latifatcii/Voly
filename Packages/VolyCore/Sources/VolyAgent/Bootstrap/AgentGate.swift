#if canImport(UIKit)
import Foundation

public enum AgentGate {
    public static let envVar = "VOLY_AGENT_ENABLED"

    public static var isEnabled: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env[envVar] == "1" { return true }
        if CommandLine.arguments.contains("--voly-agent-enabled") { return true }
        return false
        #else
        return false
        #endif
    }
}
#endif
