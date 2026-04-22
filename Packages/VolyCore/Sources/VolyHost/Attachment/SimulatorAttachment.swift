import CoreGraphics
import Foundation
import Observation

/// Live tracker. Polls a `SimulatorLocator` at a fixed interval and publishes
/// the calculated `AttachmentResult` via `@Observable`. Inspector window
/// controller observes `currentResult` and repositions.
@MainActor
@Observable
public final class SimulatorAttachment {
    public private(set) var currentResult: AttachmentResult?

    private let locator: SimulatorLocator
    private let scheduler: AttachmentScheduler
    private let voly: SizeSpec
    private let screenProvider: (CGRect?) -> CGRect
    private let interval: TimeInterval
    private let gap: CGFloat
    private var handle: AttachmentSchedulerHandle?

    public init(
        locator: SimulatorLocator,
        scheduler: AttachmentScheduler,
        voly: SizeSpec = .voly,
        screenProvider: @escaping (CGRect?) -> CGRect,
        interval: TimeInterval = 1.0 / 15.0,
        gap: CGFloat = 6
    ) {
        self.locator = locator
        self.scheduler = scheduler
        self.voly = voly
        self.screenProvider = screenProvider
        self.interval = interval
        self.gap = gap
    }

    public func start() {
        guard handle == nil else { return }
        handle = scheduler.schedule(every: interval) { [weak self] in
            self?.tick()
        }
    }

    public func stop() {
        handle?.cancel()
        handle = nil
        currentResult = nil
    }

    private func tick() {
        let frame = locator.frontmostSimulatorFrame()
        let screen = screenProvider(frame)
        let result = AttachmentCalculator.attach(
            simulatorFrame: frame, voly: voly, screen: screen, gap: gap
        )
        if result != currentResult {
            currentResult = result
        }
    }
}
