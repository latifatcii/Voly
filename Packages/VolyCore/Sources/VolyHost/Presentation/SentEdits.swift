import Foundation

/// The values an editor sent to the app that the app hasn't reported back
/// yet. An editor that sends as the user types or drags keeps showing what
/// the user did while replies to earlier edits are still arriving; this
/// tells such a reply from a report that something else changed the value.
public struct SentEdits<Value> {
    private var pending: [Value] = []
    private let same: (Value, Value) -> Bool

    /// - Parameter same: whether a reported value is a sent one coming back.
    public init(same: @escaping (Value, Value) -> Bool) {
        self.same = same
    }

    /// The edit the app will end up with once it has answered them all.
    public var latest: Value? { pending.last }

    public mutating func send(_ value: Value) {
        pending.append(value)
    }

    /// The app reported `value`.
    ///
    /// - Returns: true when that is an edit sent from here arriving (it and
    ///   the ones before it are no longer awaited); false when it is not,
    ///   so the value changed some other way and nothing sent counts any more.
    public mutating func report(_ value: Value) -> Bool {
        guard let index = pending.firstIndex(where: { same($0, value) }) else {
            pending.removeAll()
            return false
        }
        pending.removeSubrange(...index)
        return true
    }

    public mutating func reset() {
        pending.removeAll()
    }
}

public extension SentEdits where Value: Equatable {
    init() {
        self.init(same: ==)
    }
}
