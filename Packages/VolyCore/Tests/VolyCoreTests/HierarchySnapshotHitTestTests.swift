import XCTest
@testable import VolyModels
@testable import VolyCodables

final class HierarchySnapshotHitTestTests: XCTestCase {
    private func node(
        id: ObjectID,
        windowFrame: CGRect,
        children: [ViewNode] = [],
        hidden: Bool = false,
        alpha: Double = 1
    ) -> ViewNode {
        ViewNode(
            id: id,
            className: "UIView",
            moduleName: nil,
            accessibilityIdentifier: nil,
            owningViewControllerID: nil,
            frame: CGRectCodable(windowFrame),
            bounds: CGRectCodable(CGRect(origin: .zero, size: windowFrame.size)),
            center: CGPointCodable(CGPoint(x: windowFrame.midX, y: windowFrame.midY)),
            isHidden: hidden,
            alpha: alpha,
            layer: LayerProps(cornerRadius: 0, borderWidth: 0, borderColor: nil,
                              shadowColor: nil, shadowOpacity: 0, shadowRadius: 0,
                              shadowOffset: CGSizeCodable(.zero), masksToBounds: false,
                              shouldRasterize: false, rasterizationScale: 1,
                              opacity: 1, isOpaque: false,
                              backgroundColor: nil, contentsScale: 1),
            tintColor: nil,
            clipsToBounds: false,
            contentMode: 0,
            constraintIDs: [],
            childIDs: children.map(\.id),
            childrenInline: children,
            classInheritance: nil,
            hasNonIdentityTransform: false,
            windowFrame: CGRectCodable(windowFrame)
        )
    }

    private func snapshot(sceneID: ObjectID, windows: [ViewNode]) -> HierarchySnapshot {
        HierarchySnapshot(
            scenes: [SceneNode(
                id: sceneID, role: "normal", title: nil,
                windowIDs: windows.map(\.id), windowsInline: windows
            )],
            issuedAt: Date()
        )
    }

    func test_point_inside_nested_descendant_returns_deepest() {
        let leaf = node(id: 30, windowFrame: CGRect(x: 10, y: 10, width: 50, height: 50))
        let middle = node(id: 20, windowFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                          children: [leaf])
        let window = node(id: 10, windowFrame: CGRect(x: 0, y: 0, width: 200, height: 200),
                          children: [middle])
        let snap = snapshot(sceneID: 1, windows: [window])
        XCTAssertEqual(snap.hitTest(at: CGPoint(x: 30, y: 30), sceneID: 1), 30)
    }

    func test_point_in_parent_area_outside_children_returns_parent() {
        let child = node(id: 20, windowFrame: CGRect(x: 50, y: 50, width: 30, height: 30))
        let window = node(id: 10, windowFrame: CGRect(x: 0, y: 0, width: 200, height: 200),
                          children: [child])
        let snap = snapshot(sceneID: 1, windows: [window])
        XCTAssertEqual(snap.hitTest(at: CGPoint(x: 10, y: 10), sceneID: 1), 10)
    }

    func test_point_outside_all_views_returns_nil() {
        let window = node(id: 10, windowFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let snap = snapshot(sceneID: 1, windows: [window])
        XCTAssertNil(snap.hitTest(at: CGPoint(x: 500, y: 500), sceneID: 1))
    }

    func test_hidden_view_is_skipped_in_favor_of_sibling_beneath() {
        let hidden = node(id: 30, windowFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                          hidden: true)
        let visible = node(id: 20, windowFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let window = node(id: 10, windowFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                          children: [visible, hidden])
        let snap = snapshot(sceneID: 1, windows: [window])
        XCTAssertEqual(snap.hitTest(at: CGPoint(x: 50, y: 50), sceneID: 1), 20)
    }

    func test_zero_alpha_view_is_skipped() {
        let transparent = node(id: 30, windowFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                               alpha: 0)
        let visible = node(id: 20, windowFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let window = node(id: 10, windowFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                          children: [visible, transparent])
        let snap = snapshot(sceneID: 1, windows: [window])
        XCTAssertEqual(snap.hitTest(at: CGPoint(x: 50, y: 50), sceneID: 1), 20)
    }

    func test_wrong_sceneID_returns_nil() {
        let window = node(id: 10, windowFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let snap = snapshot(sceneID: 1, windows: [window])
        XCTAssertNil(snap.hitTest(at: CGPoint(x: 50, y: 50), sceneID: 999))
    }
}
