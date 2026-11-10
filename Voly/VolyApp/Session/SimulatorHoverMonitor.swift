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
    /// Reset on every Voly launch. We prompt at most once per session — if the
    /// user dismisses the dialog we don't re-spam them when they toggle Pick
    /// again, but we still guide them the first time hover is needed after a
    /// fresh install where TCC hasn't been granted yet.
    private var hasPromptedThisSession = false

    init(locator: SimulatorLocator = AXSimulatorLocator()) {
        self.locator = locator
    }

    /// Called by `InspectorSession.enterPickMode`. Returns false if
    /// Accessibility permission is not granted; the caller should silently
    /// proceed with click-only pick (no hover measurement).
    ///
    /// - Parameter announceIfUntrusted: explain the missing permission (and
    ///   prompt once per session). Off when pick mode starts by itself, so
    ///   merely showing Voly never nags about a permission that only hover
    ///   measurement needs.
    func start(announceIfUntrusted: Bool = true) -> Bool {
        if !AccessibilityTrust.isTrusted(prompt: false) {
            log.error("start: Accessibility not trusted — cannot monitor cursor")
            guard announceIfUntrusted else { return false }
            session?.lastError = "Voly needs Accessibility to track the cursor for live measurements. Grant Voly in System Settings → Privacy & Security → Accessibility, then restart Voly. Clicks still work without it."
            if !hasPromptedThisSession {
                hasPromptedThisSession = true
                // `prompt: true` shows the system dialog + deep-links into
                // Privacy settings. One nudge per session keeps it helpful
                // without being spammy if the grant isn't sticking.
                _ = AccessibilityTrust.isTrusted(prompt: true)
            }
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
        guard let state = session?.state else {
            if cachedRegion != nil { log.info("refreshRegion: no session") }
            cachedRegion = nil
            return
        }
        // The region is the iOS Simulator's screen. An Android app measures
        // on its own, in the emulator: drag from the selection in pick mode.
        if session?.isActiveAgentAndroid == true {
            cachedRegion = nil
            return
        }
        guard let snapshot = state.hierarchy else {
            if cachedRegion != nil { log.info("refreshRegion: no snapshot (not connected?)") }
            cachedRegion = nil
            return
        }
        guard let firstScene = snapshot.scenes.first,
              let firstWindow = firstScene.windowsInline.first
        else {
            if cachedRegion != nil { log.info("refreshRegion: snapshot has no scene/window") }
            cachedRegion = nil
            return
        }
        guard let bounds = locator.iosScreenRegionInScreen() else {
            if cachedRegion != nil { log.info("refreshRegion: AXSimulatorLocator.iosScreenRegionInScreen returned nil") }
            cachedRegion = nil
            return
        }
        let pointSize = (firstWindow.windowFrame ?? firstWindow.frame).cg.size
        let newRegion = Region(
            screenFrame: bounds.frame,
            iosPointSize: pointSize,
            sceneID: firstScene.id
        )
        let changed = cachedRegion?.screenFrame != newRegion.screenFrame
            || cachedRegion?.iosPointSize != newRegion.iosPointSize
            || cachedRegion?.sceneID != newRegion.sceneID
        cachedRegion = newRegion
        if changed {
            log.notice("refreshRegion: screen=\(String(describing: newRegion.screenFrame), privacy: .public) pt=\(String(describing: newRegion.iosPointSize), privacy: .public) scene=\(newRegion.sceneID)")
        }
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
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingLocation = NSEvent.mouseLocation
                self.kickThrottle()
            }
        }
        if eventMonitor == nil {
            log.error("installMonitor: NSEvent.addGlobalMonitorForEvents returned nil (Accessibility permission denied?)")
        } else {
            log.notice("installMonitor: NSEvent monitor installed")
        }
    }

    private func kickThrottle() {
        if throttleTask != nil { return }
        throttleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 33_000_000)
            guard let self else { return }
            self.throttleTask = nil
            await self.emitHover()
        }
    }

    private var emitCount: Int = 0
    private var lastLoggedOutOfRegion: Bool = false

    private func emitHover() async {
        guard let loc = pendingLocation else { return }
        guard let region = cachedRegion else {
            log.info("emitHover: no cached region (refreshRegion failed)")
            session?.measurement.hoverID = nil
            return
        }
        guard region.screenFrame.contains(loc) else {
            if !lastLoggedOutOfRegion {
                log.info("emitHover: cursor \(String(describing: loc), privacy: .public) outside region \(String(describing: region.screenFrame), privacy: .public)")
                lastLoggedOutOfRegion = true
            }
            session?.measurement.hoverID = nil
            return
        }
        lastLoggedOutOfRegion = false
        let relX = loc.x - region.screenFrame.minX
        let relY = region.screenFrame.maxY - loc.y
        let scaleX = region.iosPointSize.width  / region.screenFrame.width
        let scaleY = region.iosPointSize.height / region.screenFrame.height
        let iosPoint = CGPoint(x: relX * scaleX, y: relY * scaleY)

        // Live end-to-end measurement on the agent. Bypasses client-side
        // FrameMeasurement + snapshot frames (stale / wrong for views in
        // reused collection cells, orthogonal scroll sections, etc.).
        guard let session = self.session,
              let anchor = session.state.selectedViewID
        else {
            session?.measurement.hoverID = nil
            return
        }
        let result = await session.liveMeasureHover(
            anchor: anchor,
            x: iosPoint.x,
            y: iosPoint.y,
            sceneID: region.sceneID
        )
        emitCount += 1
        if emitCount == 1 || emitCount % 20 == 0 {
            log.notice("emitHover #\(self.emitCount): loc=\(String(describing: loc), privacy: .public) → iosPt=\(String(describing: iosPoint), privacy: .public) → other=\(result.otherID.map(String.init) ?? "nil", privacy: .public) kind=\(result.summary.map { String(describing: $0.kind) } ?? "nil", privacy: .public)")
        }
        session.measurement.hoverID = result.otherID
        session.lastMeasurementSummary = result.summary
    }

    private var lastLoggedHitID: ObjectID?
}
