import XCTest
@testable import VolyHost

@MainActor
final class SimulatorAttachmentTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let voly = SizeSpec.voly

    func test_start_schedules_and_first_tick_publishes_frame() {
        let locator = StubSimulatorLocator(
            frame: CGRect(x: 200, y: 100, width: 400, height: 800)
        )
        let scheduler = ManualAttachmentScheduler()
        let subject = SimulatorAttachment(
            locator: locator, scheduler: scheduler, voly: voly, screenProvider: { _ in self.screen }
        )

        XCTAssertNil(subject.currentResult)
        subject.start()
        XCTAssertEqual(scheduler.scheduleCallCount, 1)

        scheduler.fire()
        XCTAssertNotNil(subject.currentResult)
        XCTAssertEqual(subject.currentResult?.edge, .right)
    }

    func test_stop_cancels_scheduler_and_clears_result() {
        let locator = StubSimulatorLocator(
            frame: CGRect(x: 200, y: 100, width: 400, height: 800)
        )
        let scheduler = ManualAttachmentScheduler()
        let subject = SimulatorAttachment(
            locator: locator, scheduler: scheduler, voly: voly, screenProvider: { _ in self.screen }
        )

        subject.start()
        scheduler.fire()
        XCTAssertNotNil(subject.currentResult)

        subject.stop()
        XCTAssertNil(subject.currentResult)

        // After stop, further fires must NOT republish.
        scheduler.fire()
        XCTAssertNil(subject.currentResult)
    }

    func test_unchanged_frame_doesnt_republish() {
        let locator = StubSimulatorLocator(
            frame: CGRect(x: 200, y: 100, width: 400, height: 800)
        )
        let scheduler = ManualAttachmentScheduler()
        let subject = SimulatorAttachment(
            locator: locator, scheduler: scheduler, voly: voly, screenProvider: { _ in self.screen }
        )

        subject.start()
        scheduler.fire()
        let first = subject.currentResult

        scheduler.fire()
        let second = subject.currentResult
        XCTAssertEqual(first, second)
    }

    func test_nil_frame_publishes_detached_result() {
        let locator = StubSimulatorLocator(frame: nil)
        let scheduler = ManualAttachmentScheduler()
        let subject = SimulatorAttachment(
            locator: locator, scheduler: scheduler, voly: voly, screenProvider: { _ in self.screen }
        )

        subject.start()
        scheduler.fire()
        XCTAssertEqual(subject.currentResult?.edge, .detached)
    }
}
