#if canImport(UIKit)
import XCTest
import UIKit
@testable import VolyAgent

final class SnapshotBuilderInheritanceTests: XCTestCase {
    @MainActor
    func test_snapshot_includes_class_inheritance_chain() {
        let registry = ObjectRegistry()
        let builder = SnapshotBuilder(registry: registry)
        let view = UIImageView()
        let node = builder.snapshot(view: view, remainingDepth: 0)
        let chain = node.classInheritance ?? []
        XCTAssertEqual(chain.first, "UIImageView")
        XCTAssertTrue(chain.contains("UIView"),
                      "chain must include UIView; got \(chain)")
    }
}
#endif
