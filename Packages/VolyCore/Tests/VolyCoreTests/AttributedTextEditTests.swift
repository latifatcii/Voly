import XCTest
@testable import VolyAgent

final class AttributedTextEditTests: XCTestCase {
    private let weight = NSAttributedString.Key("voly.test.weight")
    private let spacing = NSAttributedString.Key("voly.test.spacing")

    /// "Hello " regular, "World" bold, the whole string spaced.
    private func greeting() -> NSAttributedString {
        let text = NSMutableAttributedString(string: "Hello World", attributes: [weight: "regular", spacing: 2])
        text.addAttribute(weight, value: "bold", range: NSRange(location: 6, length: 5))
        return text
    }

    private func weights(_ text: NSAttributedString) -> [String] {
        (0..<text.length).map { text.attribute(weight, at: $0, effectiveRange: nil) as? String ?? "none" }
    }

    func test_uniform_text_keeps_all_its_attributes() {
        let styled = NSAttributedString(string: "Total", attributes: [weight: "bold", spacing: 2])
        let result = AttributedTextEdit.replacingText(in: styled, with: "Subtotal due")

        XCTAssertEqual(result, NSAttributedString(string: "Subtotal due", attributes: [weight: "bold", spacing: 2]))
    }

    func test_typing_at_the_end_continues_the_last_run() {
        let result = AttributedTextEdit.replacingText(in: greeting(), with: "Hello World!")

        XCTAssertEqual(result.string, "Hello World!")
        XCTAssertEqual(weights(result), Array(repeating: "regular", count: 6) + Array(repeating: "bold", count: 6))
    }

    func test_an_edit_inside_one_run_leaves_the_other_runs_alone() {
        let result = AttributedTextEdit.replacingText(in: greeting(), with: "Hey World")

        XCTAssertEqual(result.string, "Hey World")
        XCTAssertEqual(weights(result), Array(repeating: "regular", count: 4) + Array(repeating: "bold", count: 5))
        XCTAssertEqual(result.attribute(spacing, at: 2, effectiveRange: nil) as? Int, 2)
    }

    func test_deleting_characters_keeps_the_runs_around_them() {
        let result = AttributedTextEdit.replacingText(in: greeting(), with: "Hello Wd")

        XCTAssertEqual(weights(result), Array(repeating: "regular", count: 6) + Array(repeating: "bold", count: 2))
    }

    func test_replacing_everything_takes_the_styling_the_text_started_with() {
        let result = AttributedTextEdit.replacingText(in: greeting(), with: "Bye")

        XCTAssertEqual(result, NSAttributedString(string: "Bye", attributes: [weight: "regular", spacing: 2]))
    }

    func test_typing_at_the_start_takes_the_styling_of_what_follows() {
        let styled = NSAttributedString(string: "World", attributes: [weight: "bold"])
        let result = AttributedTextEdit.replacingText(in: styled, with: "Hello World")

        XCTAssertEqual(result, NSAttributedString(string: "Hello World", attributes: [weight: "bold"]))
    }

    func test_unchanged_text_is_returned_as_it_was() {
        XCTAssertEqual(AttributedTextEdit.replacingText(in: greeting(), with: "Hello World"), greeting())
    }

    func test_clearing_the_text_gives_an_empty_string() {
        XCTAssertEqual(AttributedTextEdit.replacingText(in: greeting(), with: "").length, 0)
    }

    func test_text_with_no_styling_to_keep_is_just_the_new_text() {
        let result = AttributedTextEdit.replacingText(in: NSAttributedString(string: ""), with: "New")

        XCTAssertEqual(result, NSAttributedString(string: "New"))
    }

    func test_an_emoji_swapped_for_another_is_replaced_whole() {
        // 😀 and 😁 share their first UTF-16 unit; the edit must not split it.
        let styled = NSMutableAttributedString(string: "a😀b", attributes: [weight: "regular"])
        styled.addAttribute(weight, value: "bold", range: NSRange(location: 1, length: 2))
        let result = AttributedTextEdit.replacingText(in: styled, with: "a😁b")

        XCTAssertEqual(result.string, "a😁b")
        XCTAssertEqual(weights(result), ["regular", "bold", "bold", "regular"])
    }
}
