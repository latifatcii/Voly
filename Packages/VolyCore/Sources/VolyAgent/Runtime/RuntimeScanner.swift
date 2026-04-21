#if canImport(UIKit)
import UIKit
import ObjectiveC.runtime
import VolyModels
import VolyCodables

/// Scans a UIView for runtime-visible custom properties via the Objective-C runtime
/// (class_copyPropertyList + property attribute strings). Merges results with
/// anything registered explicitly through `CustomInspectableRegistry`.
@MainActor
public enum RuntimeScanner {
    public static func scan(view: UIView) -> [CustomPropDescriptor] {
        var results: [String: CustomPropDescriptor] = [:]
        let excluded = Self.excludedNames

        var cls: AnyClass? = type(of: view)
        let stopClass: AnyClass = UIView.self

        while let current = cls, current != stopClass.superclass() {
            var count: UInt32 = 0
            if let properties = class_copyPropertyList(current, &count) {
                for i in 0..<Int(count) {
                    let property = properties[i]
                    let nameCStr = property_getName(property)
                    let name = String(cString: nameCStr)
                    guard !excluded.contains(name) else { continue }
                    guard !name.hasPrefix("_") else { continue }
                    if results[name] != nil { continue }
                    guard let attrs = property_getAttributes(property).map({ String(cString: $0) }) else { continue }
                    guard let descriptor = describe(view: view, name: name, attributes: attrs) else { continue }
                    results[name] = descriptor
                }
                free(properties)
            }
            cls = current.superclass()
            if cls == stopClass { break }
        }

        // Merge explicit registrations
        for descriptor in CustomInspectableRegistry.shared.descriptors(for: view) {
            results[descriptor.name] = descriptor
        }

        return results.values.sorted { $0.name < $1.name }
    }

    private static func describe(view: UIView, name: String, attributes: String) -> CustomPropDescriptor? {
        // ObjC property attribute string: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtPropertyIntrospection.html
        // Format examples: "T@\"NSString\",&,N,V_foo" ; "Td,N,V_bar" (d = double)
        let parts = attributes.split(separator: ",")
        guard let typeAttr = parts.first, typeAttr.hasPrefix("T") else { return nil }
        let encoded = String(typeAttr.dropFirst())
        let readOnly = parts.contains("R")

        let declaredType: CustomPropDescriptor.DeclaredType
        switch encoded {
        case "B", "c": declaredType = .bool          // BOOL or char
        case "i", "l", "q", "I", "L", "Q", "s", "S": declaredType = .int
        case "d", "f": declaredType = .double
        case "@\"NSString\"": declaredType = .string
        case "@\"NSURL\"": declaredType = .url
        case "@\"UIColor\"": declaredType = .color
        case "{CGRect={CGPoint=dd}{CGSize=dd}}", "{CGRect={CGPoint=ff}{CGSize=ff}}": declaredType = .cgRect
        case "{CGSize=dd}", "{CGSize=ff}": declaredType = .cgSize
        case "{CGPoint=dd}", "{CGPoint=ff}": declaredType = .cgPoint
        default:
            // Fall through to KVC probe for unknown object types
            if encoded.hasPrefix("@") {
                declaredType = .unknown
            } else {
                return nil
            }
        }

        guard view.responds(to: NSSelectorFromString(name)) else { return nil }
        let raw = view.value(forKey: name)
        let value = Self.toPropValue(raw, declaredType: declaredType)
        guard case .null = value, declaredType == .unknown else {
            return CustomPropDescriptor(
                name: name,
                declaredType: declaredType,
                isReadOnly: readOnly,
                source: .runtimeObjC,
                currentValue: value
            )
        }
        return CustomPropDescriptor(
            name: name,
            declaredType: declaredType,
            isReadOnly: readOnly,
            source: .runtimeObjC,
            currentValue: .null
        )
    }

    static func toPropValue(_ raw: Any?, declaredType: CustomPropDescriptor.DeclaredType) -> PropValue {
        switch (declaredType, raw) {
        case (_, nil): return .null
        case (.bool, let v as Bool): return .bool(v)
        case (.bool, let v as NSNumber): return .bool(v.boolValue)
        case (.int, let v as NSNumber): return .int(v.int64Value)
        case (.int, let v as Int): return .int(Int64(v))
        case (.double, let v as NSNumber): return .double(v.doubleValue)
        case (.double, let v as Double): return .double(v)
        case (.string, let v as String): return .string(v)
        case (.url, let v as URL): return .url(v)
        case (.color, let v as UIColor):
            return CGColorCodable(v.cgColor).map(PropValue.color) ?? .null
        case (.cgRect, let v as NSValue):
            return .rect(CGRectCodable(v.cgRectValue))
        case (.cgSize, let v as NSValue):
            return .size(CGSizeCodable(v.cgSizeValue))
        case (.cgPoint, let v as NSValue):
            return .point(CGPointCodable(v.cgPointValue))
        default: return .null
        }
    }

    /// Names we never surface (too noisy / dangerous / system-only).
    static let excludedNames: Set<String> = [
        "nextResponder", "undoManager", "inputView", "inputAccessoryView",
        "window", "superview", "subviews", "constraints", "gestureRecognizers",
        "layer", "mask", "transform", "transform3D", "frame", "bounds", "center",
        "description", "debugDescription", "hash", "superclass", "classForCoder",
        "traitCollection", "safeAreaInsets", "safeAreaLayoutGuide", "layoutMarginsGuide",
        "directionalLayoutMargins", "readableContentGuide", "keyboardLayoutGuide",
        "accessibilityElements", "accessibilityActivationPoint", "accessibilityFrame",
        "accessibilityPath", "accessibilityCustomActions", "accessibilityCustomRotors",
    ]
}

@MainActor
public final class CustomInspectableRegistry {
    public static let shared = CustomInspectableRegistry()

    private struct Entry {
        let type: AnyObject.Type
        let name: String
        let declaredType: CustomPropDescriptor.DeclaredType
        let isReadOnly: Bool
        let get: @MainActor (AnyObject) -> PropValue
        let set: (@MainActor (AnyObject, PropValue) -> Void)?
    }

    private var entries: [Entry] = []

    private init() {}

    public func register<T: UIView>(
        _ viewType: T.Type,
        property name: String,
        type: CustomPropDescriptor.DeclaredType,
        get: @escaping @MainActor (T) -> PropValue,
        set: (@MainActor (T, PropValue) -> Void)?
    ) {
        let readOnly = (set == nil)
        let getAny: @MainActor (AnyObject) -> PropValue = { obj in
            guard let t = obj as? T else { return .null }
            return get(t)
        }
        let setAny: (@MainActor (AnyObject, PropValue) -> Void)?
        if let s = set {
            setAny = { obj, v in
                guard let t = obj as? T else { return }
                s(t, v)
            }
        } else {
            setAny = nil
        }
        entries.append(Entry(type: viewType, name: name, declaredType: type, isReadOnly: readOnly, get: getAny, set: setAny))
    }

    func descriptors(for view: UIView) -> [CustomPropDescriptor] {
        entries.compactMap { entry in
            guard view.isKind(of: entry.type) else { return nil }
            return CustomPropDescriptor(
                name: entry.name,
                declaredType: entry.declaredType,
                isReadOnly: entry.isReadOnly,
                source: .registered,
                currentValue: entry.get(view)
            )
        }
    }

    func setter(for view: UIView, named name: String) -> (@MainActor (AnyObject, PropValue) -> Void)? {
        entries.first { $0.name == name && view.isKind(of: $0.type) }?.set
    }
}
#endif
