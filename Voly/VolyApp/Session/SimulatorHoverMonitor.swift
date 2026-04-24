import AppKit
import Foundation
import Observation
import OSLog
import VolyCodables
import VolyHost
import VolyModels

nonisolated(unsafe) private let log = Logger(subsystem: "com.latifatci.Voly", category: "SimulatorHoverMonitor")

/// Captures Mac mouse-move events globally (while the iOS Simulator is
/// frontmost) and turns them into iOS-scene hover targets. Written to
/// `session.measurement.hoverID`.
///
/// This exists because `UIHoverGestureRecognizer` and `UIPointerInteraction`
/// do NOT fire in iPhone iOS Simulator — pointer events are only delivered
/// to iPad targets. The Mac-side monitor works for every target.
@MainActor
@Observable
final class SimulatorHoverMonitor {
    weak var session: InspectorSession?

    private let locator: SimulatorLocator
    private var eventMonitor: Any?
    private var throttleTask: Task<Void, Never>?
    private var pendingLocation: NSPoint?
    private var cachedRegion: Region?
    private var regionRefreshTask: Task<Void, Never>?

    init(locator: SimulatorLocator = AXSimulatorLocator()) {
        self.locator = locator
    }

    /// Called by `InspectorSession.enterMeasureMode`. Returns false if
    /// Accessibility permission is not granted (caller should auto-exit
    /// measure mode and surface an error).
    func start() -> Bool {
        guard AccessibilityTrust.isTrusted(prompt: true) else {
            log.error("start: Accessibility not trusted — cannot monitor cursor")
            return false
        }
        refreshRegion()
        startRegionRefreshLoop()
        installMonitor()
        log.notice("start: monitor installed, region=\(String(describing: self.cachedRegion?.screenFrame), privacy: .public)")
        return true
    }

    func stop() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        throttleTask?.cancel()
        throttleTask = nil
        regionRefreshTask?.cancel()
        regionRefreshTask = nil
        pendingLocation = nil
        cachedRegion = nil
        session?.measurement.hoverID = nil
        log.notice("stop: monitor removed")
    }

    // MARK: - Region

    private struct Region {
        let screenFrame: CGRect   // Cocoa bottom-left, where iOS is rendered on screen
        let iosPointSize: CGSize  // e.g. 393 × 852
        let sceneID: ObjectID
    }

    private func refreshRegion() {
        guard let state = session?.state,
              let snapshot = state.hierarchy,
              let firstScene = snapshot.scenes.first,
              let firstWindow = firstScene.windowsInline.first
        else {
            cachedRegion = nil
            return
        }
        guard let bounds = locator.iosScreenRegionInScreen() else {
            cachedRegion = nil
            return
        }
        let pointSize = (firstWindow.windowFrame ?? firstWindow.frame).cg.size
        cachedRegion = Region(
            screenFrame: bounds.frame,
            iosPointSize: pointSize,
            sceneID: firstScene.id
        )
    }

    private func startRegionRefreshLoop() {
        regionRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                self?.refreshRegion()
            }
        }
    }

    // MARK: - Monitor

    private func installMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.pendingLocation = NSEvent.mouseLocation
                self?.kickThrottle()
            }
        }
    }

    private func kickThrottle() {
        if throttleTask != nil { return }
        throttleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 33_000_000)
            guard let self else { return }
            self.throttleTask = nil
            self.emitHover()
        }
    }

    private func emitHover() {
        guard let loc = pendingLocation else { return }
        guard let region = cachedRegion else {
            session?.measurement.hoverID = nil
            return
        }
        guard region.screenFrame.contains(loc) else {
            session?.measurement.hoverID = nil
            return
        }
        let relX = loc.x - region.screenFrame.minX
        let relY = region.screenFrame.maxY - loc.y
        let scaleX = region.iosPointSize.width  / region.screenFrame.width
        let scaleY = region.iosPointSize.height / region.screenFrame.height
        let iosPoint = CGPoint(x: relX * scaleX, y: relY * scaleY)

        let id = session?.state.hierarchy?.hitTest(at: iosPoint, sceneID: region.sceneID)
        session?.measurement.hoverID = id
    }
}
