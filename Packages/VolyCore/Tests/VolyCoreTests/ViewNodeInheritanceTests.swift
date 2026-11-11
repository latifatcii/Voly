import XCTest
@testable import VolyModels
@testable import VolyCodables

final class ViewNodeInheritanceTests: XCTestCase {
    func test_classInheritance_roundtrips_through_codable() throws {
        let node = ViewNode(
            id: 1,
            className: "UIImageView",
            moduleName: "UIKitCore",
            accessibilityIdentifier: nil,
            owningViewControllerID: nil,
            frame: CGRectCodable(.zero),
            bounds: CGRectCodable(.zero),
            center: CGPointCodable(.zero),
            isHidden: false,
            alpha: 1,
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
            childIDs: [],
            childrenInline: nil,
            classInheritance: ["UIImageView", "UIView", "UIResponder", "NSObject"]
        )

        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(ViewNode.self, from: data)

        XCTAssertEqual(decoded.classInheritance,
                       ["UIImageView", "UIView", "UIResponder", "NSObject"])
    }

    func test_classInheritance_is_optional_and_defaults_nil_in_decoding_older_payloads() throws {
        let json = """
        {"id":1,"className":"UIView","moduleName":null,"accessibilityIdentifier":null,
         "owningViewControllerID":null,
         "frame":{"x":0,"y":0,"width":0,"height":0},
         "bounds":{"x":0,"y":0,"width":0,"height":0},
         "center":{"x":0,"y":0},
         "isHidden":false,"alpha":1.0,
         "layer":{"cornerRadius":0,"borderWidth":0,"borderColor":null,
                  "shadowColor":null,"shadowOpacity":0,"shadowRadius":0,
                  "shadowOffset":{"width":0,"height":0},"masksToBounds":false,
                  "shouldRasterize":false,"rasterizationScale":1,"opacity":1,"isOpaque":false,
                  "backgroundColor":null,"contentsScale":1},
         "tintColor":null,"clipsToBounds":false,"contentMode":0,
         "constraintIDs":[],"childIDs":[],"childrenInline":null}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(ViewNode.self, from: data)
        XCTAssertNil(decoded.classInheritance)
    }

    func test_hasNonIdentityTransform_roundtrips_when_set() throws {
        let node = ViewNode(
            id: 2,
            className: "UIView",
            moduleName: nil,
            accessibilityIdentifier: nil,
            owningViewControllerID: nil,
            frame: CGRectCodable(.zero),
            bounds: CGRectCodable(.zero),
            center: CGPointCodable(.zero),
            isHidden: false,
            alpha: 1,
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
            childIDs: [],
            childrenInline: nil,
            classInheritance: nil,
            hasNonIdentityTransform: true
        )
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(ViewNode.self, from: data)
        XCTAssertEqual(decoded.hasNonIdentityTransform, true)
    }

    func test_hasNonIdentityTransform_defaults_nil_in_older_payloads() throws {
        let json = """
        {"id":1,"className":"UIView","moduleName":null,"accessibilityIdentifier":null,
         "owningViewControllerID":null,
         "frame":{"x":0,"y":0,"width":0,"height":0},
         "bounds":{"x":0,"y":0,"width":0,"height":0},
         "center":{"x":0,"y":0},
         "isHidden":false,"alpha":1.0,
         "layer":{"cornerRadius":0,"borderWidth":0,"borderColor":null,
                  "shadowColor":null,"shadowOpacity":0,"shadowRadius":0,
                  "shadowOffset":{"width":0,"height":0},"masksToBounds":false,
                  "shouldRasterize":false,"rasterizationScale":1,"opacity":1,"isOpaque":false,
                  "backgroundColor":null,"contentsScale":1},
         "tintColor":null,"clipsToBounds":false,"contentMode":0,
         "constraintIDs":[],"childIDs":[],"childrenInline":null}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(ViewNode.self, from: data)
        XCTAssertNil(decoded.hasNonIdentityTransform)
    }

    /// A node of Jetpack Compose content, exactly as the Android agent sends
    /// it (`Snapshots.composeNode`): keys without a value are left out.
    func test_a_compose_node_decodes_with_its_label() throws {
        let json = """
        {"id":41,"className":"Text","accessibilityIdentifier":"price","label":"519 TL",
         "frame":{"x":12,"y":179,"width":38.5,"height":17.5},
         "bounds":{"x":0,"y":0,"width":38.5,"height":17.5},
         "center":{"x":31.25,"y":187.75},
         "isHidden":false,"alpha":1,
         "layer":{"cornerRadius":0,"borderWidth":0,"shadowOpacity":0,"shadowRadius":0,
                  "shadowOffset":{"width":0,"height":0},"masksToBounds":false,
                  "shouldRasterize":false,"rasterizationScale":2,"opacity":1,"isOpaque":false,
                  "contentsScale":2},
         "clipsToBounds":false,"contentMode":0,
         "constraintIDs":[],"childIDs":[],"childrenInline":[],
         "classInheritance":["Text"],"hasNonIdentityTransform":false,
         "windowFrame":{"x":20,"y":219,"width":38.5,"height":17.5}}
        """
        let decoded = try JSONDecoder().decode(ViewNode.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.className, "Text")
        XCTAssertEqual(decoded.label, "519 TL")
        XCTAssertEqual(decoded.accessibilityIdentifier, "price")
        XCTAssertEqual(decoded.windowFrame?.x, 20)
        let again = try JSONDecoder().decode(ViewNode.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(again, decoded)
    }

    func test_label_defaults_nil_for_views() throws {
        let json = """
        {"id":1,"className":"UIView","moduleName":null,"accessibilityIdentifier":null,
         "owningViewControllerID":null,
         "frame":{"x":0,"y":0,"width":0,"height":0},
         "bounds":{"x":0,"y":0,"width":0,"height":0},
         "center":{"x":0,"y":0},
         "isHidden":false,"alpha":1.0,
         "layer":{"cornerRadius":0,"borderWidth":0,"borderColor":null,
                  "shadowColor":null,"shadowOpacity":0,"shadowRadius":0,
                  "shadowOffset":{"width":0,"height":0},"masksToBounds":false,
                  "shouldRasterize":false,"rasterizationScale":1,"opacity":1,"isOpaque":false,
                  "backgroundColor":null,"contentsScale":1},
         "tintColor":null,"clipsToBounds":false,"contentMode":0,
         "constraintIDs":[],"childIDs":[],"childrenInline":null}
        """
        let decoded = try JSONDecoder().decode(ViewNode.self, from: Data(json.utf8))
        XCTAssertNil(decoded.label)
    }
}
