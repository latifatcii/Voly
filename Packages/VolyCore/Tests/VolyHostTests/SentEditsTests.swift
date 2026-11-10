import XCTest
@testable import VolyHost

final class SentEditsTests: XCTestCase {
    func test_a_reply_to_an_earlier_keystroke_is_recognised() {
        var sent = SentEdits<String>()
        sent.send("a")
        sent.send("ab")

        XCTAssertTrue(sent.report("a"))
        XCTAssertEqual(sent.latest, "ab")
        XCTAssertTrue(sent.report("ab"))
        XCTAssertNil(sent.latest)
    }

    func test_a_value_that_was_never_sent_is_a_change_from_elsewhere() {
        var sent = SentEdits<String>()
        sent.send("a")
        sent.send("ab")

        XCTAssertFalse(sent.report("AB"))
        // Nothing sent is awaited after that: the late reply is news too.
        XCTAssertNil(sent.latest)
        XCTAssertFalse(sent.report("ab"))
    }

    func test_a_report_with_nothing_sent_is_a_change_from_elsewhere() {
        var sent = SentEdits<String>()

        XCTAssertFalse(sent.report("a"))
    }

    func test_a_reply_that_skips_earlier_edits_drops_them() {
        var sent = SentEdits<String>()
        sent.send("a")
        sent.send("ab")
        sent.send("abc")

        XCTAssertTrue(sent.report("ab"))
        XCTAssertEqual(sent.latest, "abc")
    }

    func test_the_same_value_sent_twice_is_awaited_twice() {
        var sent = SentEdits<String>()
        sent.send("a")
        sent.send("ab")
        sent.send("a")

        XCTAssertTrue(sent.report("a"))
        XCTAssertTrue(sent.report("ab"))
        XCTAssertEqual(sent.latest, "a")
        XCTAssertTrue(sent.report("a"))
        XCTAssertNil(sent.latest)
    }

    func test_reported_values_are_matched_with_the_given_comparison() {
        var sent = SentEdits<Double>(same: { abs($0 - $1) < 0.01 })
        sent.send(0.5)

        XCTAssertTrue(sent.report(0.501))
    }

    func test_reset_forgets_what_was_sent() {
        var sent = SentEdits<String>()
        sent.send("a")
        sent.reset()

        XCTAssertNil(sent.latest)
        XCTAssertFalse(sent.report("a"))
    }
}
