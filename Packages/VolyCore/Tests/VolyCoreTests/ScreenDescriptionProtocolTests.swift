import XCTest
@testable import VolyCodables
@testable import VolyModels
@testable import VolyProtocol

final class ScreenDescriptionProtocolTests: XCTestCase {
    func test_a_bare_request_means_the_whole_visible_screen_with_checks_on() throws {
        let request = try Framing.decoder.decode(ScreenDescriptionRequest.self, from: Data("{}".utf8))
        XCTAssertNil(request.rootID)
        XCTAssertNil(request.maxDepth)
        XCTAssertFalse(request.includeHidden)
        XCTAssertTrue(request.checkLayout)
        XCTAssertTrue(request.includeAccessibility)
    }

    func test_the_command_round_trips() throws {
        let request = ScreenDescriptionRequest(rootID: 42, maxDepth: 2, includeHidden: true, checkLayout: false)
        let envelope = try Framing.encodeCommand(.describeScreen(request), id: 3)
        let decoded = try Framing.decodeCommand(try Framing.decodeEnvelope(try Framing.encodeEnvelope(envelope)))
        guard case .describeScreen(let back) = decoded else { return XCTFail("\(decoded)") }
        XCTAssertEqual(back, request)
    }

    func test_a_description_round_trips_with_everything_a_view_can_carry() throws {
        var label = ViewDescription(
            id: 7, className: "UILabel", frame: CGRectCodable(x: 16, y: 120.5, width: 200, height: 20),
            isHidden: false, alpha: 0.5, clipsToBounds: true
        )
        label.text = "Hello"
        label.font = "System Semibold 17"
        label.textColor = "#112233FF"
        label.flags = [.truncated, .ambiguousLayout]
        label.state = ["disabled"]
        label.accessibilityElements = [
            AccessibilityElementDescription(
                label: "Row", value: "On", identifier: "row.1", traits: ["button"],
                frame: CGRectCodable(x: 0, y: 0, width: 10, height: 10)
            ),
            AccessibilityElementDescription(
                id: 22, label: "Compose", value: nil, traits: [], frame: CGRectCodable(x: 0, y: 0, width: 10, height: 10)
            ),
        ]
        label.layout = LayoutDetails(
            bounds: CGRectCodable(x: 0, y: 0, width: 200, height: 20), usesAutoLayout: true,
            intrinsicWidth: 180, intrinsicHeight: nil, huggingHorizontal: 251, huggingVertical: 250,
            compressionResistanceHorizontal: 750, compressionResistanceVertical: 749,
            safeAreaInsets: .zero, layoutMargins: UIEdgeInsetsCodable(top: 8, left: 8, bottom: 8, right: 8)
        )
        var root = ViewDescription(
            id: 1, className: "UIWindow", frame: CGRectCodable(x: 0, y: 0, width: 393, height: 852),
            isHidden: false, alpha: 1, clipsToBounds: false
        )
        root.children = [label]
        root.omittedChildren = 2
        let screen = ScreenDescription(
            appName: "Demo", bundleIdentifier: "com.example.demo",
            screenSize: CGSizeCodable(width: 393, height: 852), scale: 3, orientation: .portrait,
            appearance: "dark", contentSizeCategory: "L", topViewController: "HomeVC", roots: [root],
            ancestors: [ViewAncestor(id: 1, className: "UIWindow", viewController: nil)],
            viewCount: 2, isTruncated: false
        )
        let envelope = try Framing.encodeResponse(.screenDescription(screen), id: 9)
        let decoded = try Framing.decodeResponse(try Framing.decodeEnvelope(try Framing.encodeEnvelope(envelope)))
        guard case .screenDescription(let back) = decoded else { return XCTFail("\(decoded)") }
        XCTAssertEqual(back, screen)
    }

    func test_an_element_from_an_agent_that_sends_no_id_still_reads() throws {
        let json = #"{"label":"Row","traits":["button"],"frame":{"x":0,"y":0,"width":10,"height":10}}"#
        let element = try Framing.decoder.decode(AccessibilityElementDescription.self, from: Data(json.utf8))
        XCTAssertNil(element.id)
        XCTAssertEqual(element.label, "Row")
    }
}
