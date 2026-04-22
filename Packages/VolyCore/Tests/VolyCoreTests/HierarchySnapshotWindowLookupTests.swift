import XCTest
@testable import VolyModels
@testable import VolyCodables

final class HierarchySnapshotWindowLookupTests: XCTestCase {
    private func makeLeaf(id: ObjectID) -> ViewNode {
        ViewNode(
            id: id, className: "UIView", moduleName: nil,
            accessibilityIdentifier: nil, owningViewControllerID: nil,
            frame: CGRectCodable(.zero), bounds: CGRectCodable(.zero),
            center: CGPointCodable(.zero),
            isHidden: false, alpha: 1,
            layer: LayerProps(cornerRadius: 0, borderWidth: 0, borderColor: nil,
                              shadowColor: nil, shadowOpacity: 0, shadowRadius: 0,
                              shadowOffset: CGSizeCodable(.zero), masksToBounds: false,
                              shouldRasterize: false, rasterizationScale: 1,
                              opacity: 1, isOpaque: false,
                              backgroundColor: nil, contentsScale: 1),
            tintColor: nil, clipsToBounds: false, contentMode: 0,
            constraintIDs: [], childIDs: [], childrenInline: nil
        )
    }

    private func makeWithChildren(id: ObjectID, children: [ViewNode]) -> ViewNode {
        ViewNode(
            id: id, className: "UIView", moduleName: nil,
            accessibilityIdentifier: nil, owningViewControllerID: nil,
            frame: CGRectCodable(.zero), bounds: CGRectCodable(.zero),
            center: CGPointCodable(.zero),
            isHidden: false, alpha: 1,
            layer: LayerProps(cornerRadius: 0, borderWidth: 0, borderColor: nil,
                              shadowColor: nil, shadowOpacity: 0, shadowRadius: 0,
                              shadowOffset: CGSizeCodable(.zero), masksToBounds: false,
                              shouldRasterize: false, rasterizationScale: 1,
                              opacity: 1, isOpaque: false,
                              backgroundColor: nil, contentsScale: 1),
            tintColor: nil, clipsToBounds: false, contentMode: 0,
            constraintIDs: [], childIDs: children.map(\.id), childrenInline: children
        )
    }

    private func makeSnapshot(sceneID: ObjectID, windows: [ViewNode]) -> HierarchySnapshot {
        HierarchySnapshot(
            scenes: [SceneNode(id: sceneID, role: "normal", title: nil,
                               windowIDs: windows.map(\.id), windowsInline: windows)],
            issuedAt: Date()
        )
    }

    func test_returns_window_id_for_nested_descendant() {
        let leaf = makeLeaf(id: 42)
        let window = makeWithChildren(id: 10, children: [
            makeWithChildren(id: 11, children: [leaf])
        ])
        let snap = makeSnapshot(sceneID: 1, windows: [window])
        XCTAssertEqual(snap.containingWindowID(of: 42), 10)
    }

    func test_returns_window_id_for_window_itself() {
        let window = makeWithChildren(id: 10, children: [])
        let snap = makeSnapshot(sceneID: 1, windows: [window])
        XCTAssertEqual(snap.containingWindowID(of: 10), 10)
    }

    func test_returns_nil_for_unknown_id() {
        let window = makeWithChildren(id: 10, children: [makeLeaf(id: 20)])
        let snap = makeSnapshot(sceneID: 1, windows: [window])
        XCTAssertNil(snap.containingWindowID(of: 99))
    }

    func test_distinguishes_between_windows() {
        let w1 = makeWithChildren(id: 10, children: [makeLeaf(id: 101)])
        let w2 = makeWithChildren(id: 20, children: [makeLeaf(id: 201)])
        let snap = makeSnapshot(sceneID: 1, windows: [w1, w2])
        XCTAssertEqual(snap.containingWindowID(of: 101), 10)
        XCTAssertEqual(snap.containingWindowID(of: 201), 20)
        XCTAssertNotEqual(snap.containingWindowID(of: 101), snap.containingWindowID(of: 201))
    }
}
