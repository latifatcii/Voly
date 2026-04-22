#if canImport(UIKit)
import XCTest
import UIKit
@testable import VolyAgent

final class SnapshotBuilderTransformTests: XCTestCase {
    @MainActor
    func test_identity_transform_is_false() {
        let registry = ObjectRegistry()
        let builder = SnapshotBuilder(registry: registry)
        let view = UIView()
        let node = builder.snapshot(view: view, remainingDepth: 0)
        XCTAssertEqual(node.hasNonIdentityTransform, false)
    }

    @MainActor
    func test_rotated_transform_is_true() {
        let registry = ObjectRegistry()
        let builder = SnapshotBuilder(registry: registry)
        let view = UIView()
        view.transform = CGAffineTransform(rotationAngle: .pi / 4)
        let node = builder.snapshot(view: view, remainingDepth: 0)
        XCTAssertEqual(node.hasNonIdentityTransform, true)
    }

    @MainActor
    func test_scaled_transform_is_true() {
        let registry = ObjectRegistry()
        let builder = SnapshotBuilder(registry: registry)
        let view = UIView()
        view.layer.transform = CATransform3DMakeScale(1.5, 1.5, 1)
        let node = builder.snapshot(view: view, remainingDepth: 0)
        XCTAssertEqual(node.hasNonIdentityTransform, true)
    }
}
#endif
