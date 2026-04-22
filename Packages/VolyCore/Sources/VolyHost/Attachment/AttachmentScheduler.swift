import Foundation

/// Periodic tick source. Abstracted so tests can drive time manually.
public protocol AttachmentScheduler: Sendable {
    /// Schedule `block` to fire every `interval` seconds on the main actor.
    /// Returns a handle; calling `cancel()` stops future invocations.
    @MainActor
    func schedule(every interval: TimeInterval, _ block: @escaping @MainActor () -> Void) -> AttachmentSchedulerHandle
}

public protocol AttachmentSchedulerHandle: AnyObject {
    func cancel()
}

/// Production scheduler backed by a repeating `Timer` on the main runloop.
@MainActor
public final class TimerAttachmentScheduler: AttachmentScheduler {
    public init() {}

    public func schedule(
        every interval: TimeInterval,
        _ block: @escaping @MainActor () -> Void
    ) -> AttachmentSchedulerHandle {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { block() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return TimerHandle(timer: timer)
    }
}

private final class TimerHandle: AttachmentSchedulerHandle {
    private var timer: Timer?
    init(timer: Timer) { self.timer = timer }
    func cancel() { timer?.invalidate(); timer = nil }
}

/// Test scheduler. Tests call `fire()` to drive ticks manually.
@MainActor
public final class ManualAttachmentScheduler: AttachmentScheduler {
    private var pending: [() -> Void] = []
    public private(set) var scheduleCallCount = 0
    public init() {}

    public func schedule(
        every interval: TimeInterval,
        _ block: @escaping @MainActor () -> Void
    ) -> AttachmentSchedulerHandle {
        scheduleCallCount += 1
        pending.append({ MainActor.assumeIsolated { block() } })
        return ManualHandle { [weak self] in
            self?.pending.removeAll()
        }
    }

    public func fire() {
        pending.forEach { $0() }
    }
}

private final class ManualHandle: AttachmentSchedulerHandle {
    private var onCancel: (() -> Void)?
    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    func cancel() { onCancel?(); onCancel = nil }
}
