#if DEBUG
import Foundation

/// Scripted smoke runs of a debug build can be confined to chosen
/// simulators (`VOLY_SCRIPTED_SIMULATORS=<udid>,<udid>`): everything else
/// that is booted is neither integrated with nor connected to, and apps
/// advertising over Bonjour are ignored — so a test never touches the
/// simulators or apps someone is working in.
nonisolated enum ScriptedRun {
    static let simulators: Set<String>? = {
        guard let list = ProcessInfo.processInfo.environment["VOLY_SCRIPTED_SIMULATORS"], !list.isEmpty else {
            return nil
        }
        return Set(list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }()

    /// `VOLY_SCRIPTED_HOVER=<x>,<y>`: where the pointer is taken to be, in
    /// Cocoa screen coordinates, so hover measuring can be driven without a
    /// hand on the mouse.
    static let hoverLocation: CGPoint? = {
        let parts = (ProcessInfo.processInfo.environment["VOLY_SCRIPTED_HOVER"] ?? "")
            .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
    }()
}
#endif
