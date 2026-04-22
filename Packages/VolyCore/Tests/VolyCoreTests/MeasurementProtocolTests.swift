import XCTest
@testable import VolyProtocol
@testable import VolyModels
@testable import VolyCodables

final class MeasurementProtocolTests: XCTestCase {
    func test_measurementOverlay_roundtrips_through_codable() throws {
        let overlay = MeasurementOverlay(
            anchor: CGRectCodable(x: 0, y: 0, width: 100, height: 100),
            other: CGRectCodable(x: 200, y: 0, width: 100, height: 100),
            otherIsTransformed: false,
            guides: [
                .horizontal(y: 50, x1: 100, x2: 200, label: "100"),
                .vertical(x: 250, y1: 100, y2: 150, label: "50")
            ],
            summary: MeasurementSummary(kind: .sideBySide, horizontal: 100, vertical: 50)
        )

        let data = try JSONEncoder().encode(overlay)
        let decoded = try JSONDecoder().decode(MeasurementOverlay.self, from: data)

        XCTAssertEqual(decoded.anchor, overlay.anchor)
        XCTAssertEqual(decoded.other, overlay.other)
        XCTAssertEqual(decoded.otherIsTransformed, false)
        XCTAssertEqual(decoded.guides.count, 2)
        XCTAssertEqual(decoded.summary.kind, .sideBySide)
        XCTAssertEqual(decoded.summary.horizontal, 100)
        XCTAssertEqual(decoded.summary.vertical, 50)
    }

    func test_measurementGuide_horizontal_roundtrip() throws {
        let g = MeasurementGuide.horizontal(y: 10, x1: 0, x2: 20, label: "20")
        let data = try JSONEncoder().encode(g)
        let decoded = try JSONDecoder().decode(MeasurementGuide.self, from: data)
        if case .horizontal(let y, let x1, let x2, let label) = decoded {
            XCTAssertEqual(y, 10)
            XCTAssertEqual(x1, 0)
            XCTAssertEqual(x2, 20)
            XCTAssertEqual(label, "20")
        } else {
            XCTFail("expected .horizontal, got \(decoded)")
        }
    }

    func test_measurementSummary_allKinds_roundtrip() throws {
        for kind in MeasurementSummary.Kind.allCases {
            let s = MeasurementSummary(kind: kind, horizontal: nil, vertical: nil)
            let data = try JSONEncoder().encode(s)
            let decoded = try JSONDecoder().decode(MeasurementSummary.self, from: data)
            XCTAssertEqual(decoded.kind, kind)
        }
    }
}
