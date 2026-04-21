#if canImport(UIKit)
import Foundation
#if !VOLY_UNIFIED_BUILD
import VolyModels
#endif
#if !VOLY_UNIFIED_BUILD
import VolyCodables
#endif
#if !VOLY_UNIFIED_BUILD
import VolyProtocol
#endif

@MainActor
public final class UserDefaultsProvider {
    public init() {}

    public func list(suite: String?) -> [UserDefaultsItem] {
        let d = defaults(for: suite)
        let representation = d.dictionaryRepresentation()
        return representation.compactMap { key, value in
            describe(suite: suite ?? "", key: key, value: value)
        }.sorted { $0.key < $1.key }
    }

    public func set(_ req: UserDefaultsSetRequest) throws {
        let d = defaults(for: req.suite)
        switch req.value {
        case .string(let s): d.set(s, forKey: req.key)
        case .int(let i):    d.set(Int(i), forKey: req.key)
        case .double(let x): d.set(x, forKey: req.key)
        case .bool(let b):   d.set(b, forKey: req.key)
        case .url(let u):    d.set(u, forKey: req.key)
        case .arrayOf(let a):
            d.set(a.map { $0.toFoundation() }, forKey: req.key)
        case .dictOf(let m):
            d.set(m.mapValues { $0.toFoundation() }, forKey: req.key)
        case .null:
            d.removeObject(forKey: req.key)
        default:
            throw InspectorError.unsupportedValue
        }
    }

    public func delete(suite: String?, key: String) {
        defaults(for: suite).removeObject(forKey: key)
    }

    private func defaults(for suite: String?) -> UserDefaults {
        guard let s = suite, !s.isEmpty, let d = UserDefaults(suiteName: s) else {
            return .standard
        }
        return d
    }

    private func describe(suite: String, key: String, value: Any) -> UserDefaultsItem? {
        // Skip Apple system keys to keep the UI focused on app-authored keys.
        if isSystemKey(key) { return nil }
        if let s = value as? String {
            return UserDefaultsItem(suite: suite, key: key, type: .string, value: .string(s))
        }
        if let n = value as? NSNumber {
            let type = String(cString: n.objCType)
            if type == "c" || type == "B" {
                return UserDefaultsItem(suite: suite, key: key, type: .bool, value: .bool(n.boolValue))
            }
            if type == "d" || type == "f" {
                return UserDefaultsItem(suite: suite, key: key, type: .double, value: .double(n.doubleValue))
            }
            return UserDefaultsItem(suite: suite, key: key, type: .int, value: .int(n.int64Value))
        }
        if let b = value as? Bool {
            return UserDefaultsItem(suite: suite, key: key, type: .bool, value: .bool(b))
        }
        if let u = value as? URL {
            return UserDefaultsItem(suite: suite, key: key, type: .url, value: .url(u))
        }
        if let arr = value as? [Any] {
            let mapped = arr.map { fromFoundation($0) }
            return UserDefaultsItem(suite: suite, key: key, type: .array, value: .arrayOf(mapped))
        }
        if let dict = value as? [String: Any] {
            let mapped = dict.mapValues { fromFoundation($0) }
            return UserDefaultsItem(suite: suite, key: key, type: .dict, value: .dictOf(mapped))
        }
        if value is Date {
            return UserDefaultsItem(suite: suite, key: key, type: .date, value: .null)
        }
        if value is Data {
            return UserDefaultsItem(suite: suite, key: key, type: .data, value: .null)
        }
        return nil
    }

    private func isSystemKey(_ key: String) -> Bool {
        key.hasPrefix("AK") ||
        key.hasPrefix("NS") ||
        key.hasPrefix("Apple") ||
        key.hasPrefix("com.apple.") ||
        key.hasPrefix("PK") ||
        key.hasPrefix("MK") ||
        key.hasPrefix("WebKit")
    }

    private func fromFoundation(_ value: Any) -> PropValue {
        if let s = value as? String { return .string(s) }
        if let n = value as? NSNumber {
            let type = String(cString: n.objCType)
            if type == "c" || type == "B" { return .bool(n.boolValue) }
            if type == "d" || type == "f" { return .double(n.doubleValue) }
            return .int(n.int64Value)
        }
        if let b = value as? Bool { return .bool(b) }
        if let u = value as? URL { return .url(u) }
        if let arr = value as? [Any] { return .arrayOf(arr.map { fromFoundation($0) }) }
        if let dict = value as? [String: Any] { return .dictOf(dict.mapValues { fromFoundation($0) }) }
        return .null
    }
}

extension PropValue {
    public func toFoundation() -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .url(let u): return u
        case .color: return NSNull()
        case .rect, .size, .point: return NSNull()
        case .arrayOf(let a): return a.map { $0.toFoundation() }
        case .dictOf(let d): return d.mapValues { $0.toFoundation() }
        }
    }
}
#endif
