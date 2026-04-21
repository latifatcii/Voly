import Foundation

public struct UserDefaultsItem: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let suite: String
    public let key: String
    public let type: ValueType
    public let value: PropValue

    public enum ValueType: String, Codable, Sendable {
        case string, int, double, bool, data, date, array, dict, url
    }

    public init(suite: String, key: String, type: ValueType, value: PropValue) {
        self.suite = suite
        self.key = key
        self.type = type
        self.value = value
        self.id = "\(suite)::\(key)"
    }
}
