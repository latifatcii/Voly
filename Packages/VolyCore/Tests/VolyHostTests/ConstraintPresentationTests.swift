import XCTest
import VolyModels
@testable import VolyHost

final class ConstraintPresentationTests: XCTestCase {
    private func constraint(
        _ first: LayoutAttribute, _ second: LayoutAttribute, relation: LayoutRelation = .equal,
        constant: Double = 0, multiplier: Double = 1, summary: String
    ) -> ConstraintNode {
        ConstraintNode(
            id: 1, firstItemID: 2, firstAttribute: first, relation: relation,
            secondItemID: second == .notAnAttribute ? nil : 3, secondAttribute: second,
            constant: constant, multiplier: multiplier, priority: 1000, identifier: nil,
            isActive: true, ownerID: 4, isSystemGenerated: false, summary: summary
        )
    }

    func test_alignment_to_another_view() {
        let p = ConstraintPresentation(constraint(
            .leading, .trailing, constant: 33,
            summary: "UILabel.leading = UIImageView.trailing × 1.0 + 33.0 @1000.0"))
        XCTAssertEqual(p.label, "Leading to")
        XCTAssertEqual(p.value, "UIImageView.trailing + 33")
    }

    func test_fixed_dimension() {
        let p = ConstraintPresentation(constraint(
            .width, .notAnAttribute, constant: 173,
            summary: "UILabel.width = nil.notAnAttribute × 1.0 + 173.0 @1000.0"))
        XCTAssertEqual(p.label, "Width equals")
        XCTAssertEqual(p.value, "173")
    }

    func test_plain_alignment_has_no_arithmetic() {
        let p = ConstraintPresentation(constraint(
            .centerY, .centerY, summary: "UILabel.centerY = UIImageView.centerY × 1.0 + 0.0 @1000.0"))
        XCTAssertEqual(p.label, "Center Y to")
        XCTAssertEqual(p.value, "UIImageView.centerY")
    }

    func test_inequality_multiplier_and_negative_constant() {
        let p = ConstraintPresentation(constraint(
            .trailing, .trailingMargin, relation: .lessThanOrEqual, constant: -8.5, multiplier: 0.5,
            summary: "UIButton.trailing ≤ UIView.trailingMargin × 0.5 + -8.5 @750.0"))
        XCTAssertEqual(p.label, "Trailing ≤")
        XCTAssertEqual(p.value, "UIView.trailingMargin × 0.5 − 8.5")
    }

    func test_falls_back_to_the_attribute_when_the_summary_is_unreadable() {
        let p = ConstraintPresentation(constraint(.top, .bottom, summary: "?"))
        XCTAssertEqual(p.value, "bottom")
    }

    func test_attribute_names_read_as_words() {
        XCTAssertEqual(ConstraintPresentation.name(of: .lastBaseline), "last baseline")
        XCTAssertEqual(ConstraintPresentation.name(of: .centerXWithinMargins), "center X within margins")
        XCTAssertEqual(ConstraintPresentation.number(17.3333333), "17.333")
    }
}
