import XCTest
import VolyCodables
import VolyModels
@testable import VolyHost

final class ScreenDescriptionFormatterTests: XCTestCase {
    private let formatter = ScreenDescriptionFormatter()

    private func view(
        _ id: ObjectID, _ className: String, _ x: Double = 0, _ y: Double = 0, _ width: Double = 393, _ height: Double = 852,
        children: [ViewDescription] = [], configure: (inout ViewDescription) -> Void = { _ in }
    ) -> ViewDescription {
        var node = ViewDescription(
            id: id, className: className, frame: CGRectCodable(x: x, y: y, width: width, height: height),
            isHidden: false, alpha: 1, clipsToBounds: false
        )
        node.children = children
        configure(&node)
        return node
    }

    private func screen(_ roots: [ViewDescription], count: Int = 1) -> ScreenDescription {
        ScreenDescription(
            appName: "Shop", bundleIdentifier: "com.example.shop", screenSize: CGSizeCodable(width: 393, height: 852),
            scale: 3, orientation: .portrait, appearance: "dark", contentSizeCategory: "XL",
            topViewController: "CartViewController", roots: roots, viewCount: count, isTruncated: false
        )
    }

    func test_a_line_says_what_the_view_shows_and_how() {
        let label = view(13, "UILabel", 16, 117.666, 158.7, 26.33) {
            $0.text = "Welcome"
            $0.font = "System Semibold 22"
            $0.textColor = "#000000FF"
            $0.backgroundColor = "#3C3C4399"
            $0.numberOfLines = 0
            $0.cornerRadius = 8
            $0.accessibilityIdentifier = "greeting"
            $0.accessibilityLabel = "Welcome"          // same as the text: not repeated
            $0.alpha = 0.5
            $0.state = ["disabled"]
            $0.flags = [.truncated]
        }
        XCTAssertEqual(
            formatter.line(for: label),
            "UILabel #13 16,117.7 158.7×26.3 \"Welcome\" font=System Semibold 22 color=#000000 bg=#3C3C43@60% "
                + "lines=0 radius=8 id=greeting alpha=0.5 [disabled] ⚠ text truncated"
        )
    }

    func test_one_line_labels_and_default_values_stay_quiet() {
        let label = view(2, "UILabel", 0, 0, 10, 10) {
            $0.text = "A"
            $0.numberOfLines = 1
        }
        XCTAssertEqual(formatter.line(for: label), "UILabel #2 0,0 10×10 \"A\"")
    }

    func test_text_is_quoted_on_one_line_and_cut_when_long() {
        let label = view(2, "UILabel") { $0.text = "two\nlines \"quoted\"" }
        XCTAssertTrue(formatter.line(for: label).contains(#""two\nlines \"quoted\"""#))
        let long = view(3, "UITextView") { $0.text = String(repeating: "x", count: 500) }
        let line = formatter.line(for: long)
        XCTAssertTrue(line.contains("…(+360 chars)"), line)
        XCTAssertLessThan(line.count, 260)
    }

    func test_accessibility_elements_are_marked_apart_from_views() {
        let element = AccessibilityElementDescription(
            label: "Add to cart", value: "2", identifier: "cart.add", traits: ["button", "selected"],
            frame: CGRectCodable(x: 20, y: 150, width: 353, height: 44)
        )
        XCTAssertEqual(formatter.line(for: element), "~ \"Add to cart\" value=\"2\" button,selected 20,150 353×44 id=cart.add")

        // Jetpack Compose content is in the tree too, and says under which id.
        let node = AccessibilityElementDescription(
            id: 22, label: "Clicked 0 times", value: nil, identifier: "compose.button", traits: ["button"],
            frame: CGRectCodable(x: 16, y: 152, width: 144, height: 40)
        )
        XCTAssertEqual(formatter.line(for: node), "~ #22 \"Clicked 0 times\" button 16,152 144×40 id=compose.button")
    }

    func test_plain_wrappers_of_the_same_size_fold_onto_one_line() {
        let tree = view(1, "UIWindow", children: [
            view(2, "UITransitionView", children: [
                view(3, "UIView", children: [view(4, "UILabel", 10, 10, 50, 20) { $0.text = "Hi" }]) {
                    $0.viewController = "HomeViewController"
                },
            ]),
        ])
        let text = formatter.tree(for: screen([tree])).text
        XCTAssertEqual(text, """
            UIWindow #1 › UITransitionView #2 › UIView #3 0,0 393×852 vc=HomeViewController
              UILabel #4 10,10 50×20 "Hi"
            """)
    }

    func test_folding_can_be_turned_off_and_never_hides_a_different_frame() {
        let tree = view(1, "UIWindow", children: [
            view(2, "UIView", 0, 100, 393, 600, children: [view(3, "UILabel", 10, 110, 50, 20)]),
        ])
        var unfolded = formatter
        unfolded.collapsesWrappers = false
        XCTAssertEqual(unfolded.tree(for: screen([tree])).text.split(separator: "\n").count, 3)
        // #1 and #2 differ in frame, so even with folding on they keep their own lines.
        XCTAssertEqual(formatter.tree(for: screen([tree])).text.split(separator: "\n").count, 3)
    }

    func test_a_tree_too_large_is_cut_by_depth_and_says_how_to_get_the_rest() {
        func rows(_ depth: Int, _ id: inout ObjectID) -> ViewDescription {
            id += 1
            let own = id
            let children = depth == 0 ? [] : (0..<4).map { _ in rows(depth - 1, &id) }
            return view(own, "UIView", Double(own), 0, 10, 10, children: children) { $0.text = "row \(own)" }
        }
        var id: ObjectID = 0
        let root = rows(5, &id)       // 1365 views
        var small = formatter
        small.characterBudget = 3_000
        let cut = small.tree(for: screen([root]))
        XCTAssertNotNil(cut.levelsShown)
        XCTAssertLessThanOrEqual(cut.text.count, 3_000)
        XCTAssertTrue(cut.text.contains("views inside, get_screen root="), cut.text)
        XCTAssertNil(formatter.tree(for: screen([view(1, "UIView")])).levelsShown)
    }

    func test_children_left_out_by_the_app_are_counted() {
        let host = view(5, "UIStackView") { $0.omittedChildren = 3 }
        XCTAssertTrue(formatter.tree(for: screen([host])).text.contains("+3 hidden or deeper subviews not listed"))
    }

    func test_problems_are_gathered_from_any_depth() {
        let tree = view(1, "UIWindow", children: [
            view(2, "UIView", 0, 0, 100, 100, children: [
                view(3, "UILabel", 0, 0, 40, 20) {
                    $0.text = "Total"
                    $0.flags = [.truncated]
                },
                view(4, "CartBadge", 0, 0, 0, 0) { $0.flags = [.zeroSize, .ambiguousLayout] },
            ]),
        ])
        XCTAssertEqual(formatter.problems(in: screen([tree])), """
            Possible problems (2):
            - text truncated: UILabel #3 "Total"
            - zero size, ambiguous layout: CartBadge #4
            """)
        XCTAssertNil(formatter.problems(in: screen([view(1, "UIWindow")])))
    }

    func test_header_names_the_app_the_device_and_the_screen() {
        let header = formatter.header(for: screen([]), simulator: "iPhone 16 Pro")
        XCTAssertEqual(header, """
            Shop (com.example.shop) in iPhone 16 Pro
            Screen 393×852 pt @3x, portrait, dark mode, text size XL. Top view controller: CartViewController.
            """)
    }

    func test_colors_numbers_and_long_generic_names() {
        XCTAssertEqual(ScreenDescriptionFormatter.color("#FF3B30FF"), "#FF3B30")
        XCTAssertEqual(ScreenDescriptionFormatter.color("#FF3B3080"), "#FF3B30@50%")
        XCTAssertEqual(ScreenDescriptionFormatter.color("systemRed"), "systemRed")
        XCTAssertEqual(ScreenDescriptionFormatter.number(20), "20")
        XCTAssertEqual(ScreenDescriptionFormatter.number(20.333), "20.3")
        XCTAssertEqual(ScreenDescriptionFormatter.number(-0.04), "0")
        XCTAssertEqual(
            ScreenDescriptionFormatter.shortClassName("CellHostingView<ModifiedContent<_ViewList_View, CollectionViewCellModifier>>"),
            "CellHostingView<…>"
        )
        XCTAssertEqual(ScreenDescriptionFormatter.shortClassName("_UIHostingView<Row>"), "_UIHostingView<Row>")
    }
}
