#if canImport(UIKit)
import UIKit
#if canImport(VolyModels)
import VolyModels
#endif
#if canImport(VolyCodables)
import VolyCodables
#endif
#if canImport(VolyProtocol)
import VolyProtocol
#endif

@MainActor
public final class MutationExecutor {
    unowned let registry: ObjectRegistry

    public init(registry: ObjectRegistry) {
        self.registry = registry
    }

    public func applyProperty(_ request: SetPropertyRequest) throws {
        guard let target = registry.object(for: request.objectID) else {
            throw InspectorError.objectGone(request.objectID)
        }
        switch request.scope {
        case .view:
            guard let view = target as? UIView else { throw InspectorError.objectGone(request.objectID) }
            try ViewOps.apply(request.change, to: view)
            view.setNeedsLayout()
        case .layer:
            guard let view = target as? UIView else { throw InspectorError.objectGone(request.objectID) }
            try LayerOps.apply(request.change, to: view.layer)
        case .custom:
            guard let view = target as? UIView else { throw InspectorError.objectGone(request.objectID) }
            try CustomOps.apply(request.change, to: view)
        }
    }

    public func applyConstraint(_ request: SetConstraintRequest) throws {
        guard let constraint = registry.object(for: request.constraintID) as? NSLayoutConstraint else {
            throw InspectorError.objectGone(request.constraintID)
        }
        let anchor = registry.object(for: request.anchorObjectID) as? UIView
        if let c = request.change.constant {
            constraint.constant = CGFloat(c)
        }
        if let p = request.change.priority {
            constraint.priority = UILayoutPriority(p)
        }
        if let active = request.change.isActive {
            constraint.isActive = active
        }
        anchor?.setNeedsLayout()
        anchor?.layoutIfNeeded()
    }
}

@MainActor
enum ViewOps {
    static func apply(_ change: PropertyChange, to view: UIView) throws {
        switch change.property {
        case "alpha":
            view.alpha = CGFloat(try change.value.asDouble())
        case "isHidden":
            view.isHidden = try change.value.asBool()
        case "clipsToBounds":
            view.clipsToBounds = try change.value.asBool()
        case "backgroundColor":
            view.backgroundColor = UIColor(cgColor: try change.value.asColor().cg)
        case "tintColor":
            view.tintColor = UIColor(cgColor: try change.value.asColor().cg)
        case "contentMode":
            let raw = Int(try change.value.asInt())
            if let mode = UIView.ContentMode(rawValue: raw) {
                view.contentMode = mode
            } else {
                throw InspectorError.unsupportedValue
            }
        case "isUserInteractionEnabled":
            view.isUserInteractionEnabled = try change.value.asBool()
        default:
            throw InspectorError.unsupportedProperty(change.property)
        }
    }
}

@MainActor
enum LayerOps {
    static func apply(_ change: PropertyChange, to layer: CALayer) throws {
        switch change.property {
        case "cornerRadius":
            layer.cornerRadius = CGFloat(try change.value.asDouble())
        case "borderWidth":
            layer.borderWidth = CGFloat(try change.value.asDouble())
        case "borderColor":
            layer.borderColor = try change.value.asColor().cg
        case "shadowColor":
            layer.shadowColor = try change.value.asColor().cg
        case "shadowOpacity":
            layer.shadowOpacity = Float(try change.value.asDouble())
        case "shadowRadius":
            layer.shadowRadius = CGFloat(try change.value.asDouble())
        case "shadowOffset":
            layer.shadowOffset = try change.value.asSize().cg
        case "masksToBounds":
            layer.masksToBounds = try change.value.asBool()
        case "shouldRasterize":
            layer.shouldRasterize = try change.value.asBool()
        case "rasterizationScale":
            layer.rasterizationScale = CGFloat(try change.value.asDouble())
        case "opacity":
            layer.opacity = Float(try change.value.asDouble())
        case "isOpaque":
            layer.isOpaque = try change.value.asBool()
        default:
            throw InspectorError.unsupportedProperty(change.property)
        }
    }
}

@MainActor
enum CustomOps {
    static func apply(_ change: PropertyChange, to view: UIView) throws {
        if let setter = CustomInspectableRegistry.shared.setter(for: view, named: change.property) {
            setter(view, change.value)
            view.setNeedsLayout()
            return
        }
        // Fall back to KVC.
        let sel = NSSelectorFromString("set\(change.property.volyCapitalizedFirst):")
        guard view.responds(to: sel) else {
            throw InspectorError.unsupportedProperty(change.property)
        }
        switch change.value {
        case .string(let s): view.setValue(s, forKey: change.property)
        case .bool(let b):   view.setValue(b, forKey: change.property)
        case .int(let i):    view.setValue(i, forKey: change.property)
        case .double(let d): view.setValue(d, forKey: change.property)
        case .color(let c):  view.setValue(UIColor(cgColor: c.cg), forKey: change.property)
        case .url(let u):    view.setValue(u, forKey: change.property)
        case .rect(let r):   view.setValue(NSValue(cgRect: r.cg), forKey: change.property)
        case .size(let s):   view.setValue(NSValue(cgSize: s.cg), forKey: change.property)
        case .point(let p):  view.setValue(NSValue(cgPoint: p.cg), forKey: change.property)
        case .null:          view.setValue(nil, forKey: change.property)
        default: throw InspectorError.unsupportedValue
        }
        view.setNeedsLayout()
    }
}

extension String {
    var volyCapitalizedFirst: String {
        guard let first = first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
#endif
