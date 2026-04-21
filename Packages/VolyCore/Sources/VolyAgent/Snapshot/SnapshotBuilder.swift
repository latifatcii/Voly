#if canImport(UIKit)
import UIKit
import Foundation
#if !VOLY_UNIFIED_BUILD
import VolyModels
#endif
#if !VOLY_UNIFIED_BUILD
import VolyCodables
#endif

@MainActor
public final class SnapshotBuilder {
    public static let overlayIdentifier = "__voly_overlay__"

    unowned let registry: ObjectRegistry

    public init(registry: ObjectRegistry) {
        self.registry = registry
    }

    public func snapshotAllScenes(topDepth: Int = 6) -> HierarchySnapshot {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let sceneNodes: [SceneNode] = scenes.map { scene in
            let windows = scene.windows.filter { !$0.isVolyOverlay }
            let windowIDs = windows.map { registry.id(for: $0) }
            let inline = windows.map { snapshot(view: $0, remainingDepth: topDepth) }
            return SceneNode(
                id: registry.id(for: scene),
                role: scene.session.role.rawValue,
                title: scene.title,
                windowIDs: windowIDs,
                windowsInline: inline
            )
        }
        return HierarchySnapshot(scenes: sceneNodes, issuedAt: Date())
    }

    public func snapshot(for id: ObjectID, maxDepth: Int) throws -> ViewNode {
        guard let view = registry.object(for: id) as? UIView else {
            throw InspectorError.objectGone(id)
        }
        return snapshot(view: view, remainingDepth: maxDepth)
    }

    public func snapshot(view: UIView, remainingDepth: Int) -> ViewNode {
        let visibleSubviews = view.subviews.filter { !$0.isVolyOverlay }
        let childIDs = visibleSubviews.map { registry.id(for: $0) }
        let inline: [ViewNode]? = remainingDepth > 0
            ? visibleSubviews.map { snapshot(view: $0, remainingDepth: remainingDepth - 1) }
            : nil

        return ViewNode(
            id: registry.id(for: view),
            className: String(describing: type(of: view)),
            moduleName: Self.module(for: view),
            accessibilityIdentifier: view.accessibilityIdentifier,
            owningViewControllerID: view.volyOwningVC.map { registry.id(for: $0) },
            frame: CGRectCodable(view.frame),
            bounds: CGRectCodable(view.bounds),
            center: CGPointCodable(view.center),
            isHidden: view.isHidden,
            alpha: Double(view.alpha),
            layer: LayerProps(caLayer: view.layer),
            tintColor: CGColorCodable(view.tintColor?.cgColor),
            clipsToBounds: view.clipsToBounds,
            contentMode: view.contentMode.rawValue,
            constraintIDs: view.constraints.map { registry.id(for: $0) },
            childIDs: childIDs,
            childrenInline: inline
        )
    }

    public func propertyBag(for id: ObjectID) throws -> PropertyBag {
        guard let view = registry.object(for: id) as? UIView else {
            throw InspectorError.objectGone(id)
        }
        let viewDict: [String: PropValue] = [
            "alpha": .double(Double(view.alpha)),
            "isHidden": .bool(view.isHidden),
            "clipsToBounds": .bool(view.clipsToBounds),
            "backgroundColor": CGColorCodable(view.backgroundColor?.cgColor).map(PropValue.color) ?? .null,
            "tintColor": CGColorCodable(view.tintColor?.cgColor).map(PropValue.color) ?? .null,
            "contentMode": .int(Int64(view.contentMode.rawValue)),
            "isUserInteractionEnabled": .bool(view.isUserInteractionEnabled),
        ]
        let layer = view.layer
        let layerDict: [String: PropValue] = [
            "cornerRadius": .double(Double(layer.cornerRadius)),
            "borderWidth": .double(Double(layer.borderWidth)),
            "borderColor": CGColorCodable(layer.borderColor).map(PropValue.color) ?? .null,
            "shadowColor": CGColorCodable(layer.shadowColor).map(PropValue.color) ?? .null,
            "shadowOpacity": .double(Double(layer.shadowOpacity)),
            "shadowRadius": .double(Double(layer.shadowRadius)),
            "shadowOffset": .size(CGSizeCodable(layer.shadowOffset)),
            "masksToBounds": .bool(layer.masksToBounds),
            "shouldRasterize": .bool(layer.shouldRasterize),
            "rasterizationScale": .double(Double(layer.rasterizationScale)),
            "opacity": .double(Double(layer.opacity)),
            "isOpaque": .bool(layer.isOpaque),
        ]
        let custom = RuntimeScanner.scan(view: view)
        return PropertyBag(objectID: id, view: viewDict, layer: layerDict, custom: custom)
    }

    public func constraints(for id: ObjectID) throws -> [ConstraintNode] {
        guard let view = registry.object(for: id) as? UIView else {
            throw InspectorError.objectGone(id)
        }
        var results: [ObjectID: ConstraintNode] = [:]

        func collect(from host: UIView) {
            for constraint in host.constraints {
                let involvesSelected = constraint.firstItem === view || constraint.secondItem === view
                let isSelfHost = host === view
                guard involvesSelected || isSelfHost else { continue }
                let node = makeNode(constraint, owner: host)
                results[node.id] = node
            }
        }

        collect(from: view)
        var superview = view.superview
        while let s = superview {
            collect(from: s)
            superview = s.superview
        }

        return results.values.sorted { $0.id < $1.id }
    }

    private func makeNode(_ c: NSLayoutConstraint, owner: UIView) -> ConstraintNode {
        let firstID = (c.firstItem as AnyObject?).map { registry.id(for: $0) }
        let secondID = (c.secondItem as AnyObject?).map { registry.id(for: $0) }
        let firstClass = (c.firstItem as AnyObject?).map { String(describing: type(of: $0)) } ?? "nil"
        let secondClass = (c.secondItem as AnyObject?).map { String(describing: type(of: $0)) } ?? "nil"
        let isSystem = (c.identifier ?? "").hasPrefix("UIView-Encapsulated") ||
            String(describing: type(of: c)) != "NSLayoutConstraint"
        let summary = "\(firstClass).\(c.firstAttribute.volyName) \(c.relation.volySymbol) \(secondClass).\(c.secondAttribute.volyName) × \(c.multiplier) + \(c.constant) @\(c.priority.rawValue)"

        return ConstraintNode(
            id: registry.id(for: c),
            firstItemID: firstID,
            firstAttribute: c.firstAttribute.volyMapped,
            relation: c.relation.volyMapped,
            secondItemID: secondID,
            secondAttribute: c.secondAttribute.volyMapped,
            constant: Double(c.constant),
            multiplier: Double(c.multiplier),
            priority: c.priority.rawValue,
            identifier: c.identifier,
            isActive: c.isActive,
            ownerID: registry.id(for: owner),
            isSystemGenerated: isSystem,
            summary: summary
        )
    }

    static func module(for object: AnyObject) -> String? {
        let full = String(reflecting: type(of: object))
        let parts = full.split(separator: ".").dropLast()
        let joined = parts.joined(separator: ".")
        return joined.isEmpty ? nil : joined
    }
}

extension UIView {
    var isVolyOverlay: Bool {
        accessibilityIdentifier == SnapshotBuilder.overlayIdentifier
    }

    @MainActor
    var volyOwningVC: UIViewController? {
        var r: UIResponder? = self.next
        while let current = r {
            if let vc = current as? UIViewController { return vc }
            r = current.next
        }
        return nil
    }
}

extension NSLayoutConstraint.Attribute {
    var volyMapped: LayoutAttribute {
        switch self {
        case .left: return .left
        case .right: return .right
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        case .width: return .width
        case .height: return .height
        case .centerX: return .centerX
        case .centerY: return .centerY
        case .lastBaseline: return .lastBaseline
        case .firstBaseline: return .firstBaseline
        case .leftMargin: return .leftMargin
        case .rightMargin: return .rightMargin
        case .topMargin: return .topMargin
        case .bottomMargin: return .bottomMargin
        case .leadingMargin: return .leadingMargin
        case .trailingMargin: return .trailingMargin
        case .centerXWithinMargins: return .centerXWithinMargins
        case .centerYWithinMargins: return .centerYWithinMargins
        case .notAnAttribute: return .notAnAttribute
        @unknown default: return .notAnAttribute
        }
    }
    var volyName: String { volyMapped.rawValue }
}

extension NSLayoutConstraint.Relation {
    var volyMapped: LayoutRelation {
        switch self {
        case .lessThanOrEqual: return .lessThanOrEqual
        case .equal: return .equal
        case .greaterThanOrEqual: return .greaterThanOrEqual
        @unknown default: return .equal
        }
    }
    var volySymbol: String {
        switch self {
        case .lessThanOrEqual: return "≤"
        case .equal: return "="
        case .greaterThanOrEqual: return "≥"
        @unknown default: return "?"
        }
    }
}
#endif
