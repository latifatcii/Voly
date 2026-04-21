#if canImport(UIKit)
import Foundation
#if !VOLY_UNIFIED_BUILD
import VolyModels
#endif

/// Bidirectional registry that maps opaque `ObjectID`s to weakly-retained UIKit objects.
///
/// - Keys are handed out monotonically, local to the current session.
/// - Backing store is an `NSMapTable` with weak values so deallocated objects are
///   silently dropped without crashing the agent.
/// - Thread-affinity: `@MainActor` — all UIKit access happens on main, so we inherit that.
@MainActor
public final class ObjectRegistry {
    private let forward = NSMapTable<NSNumber, AnyObject>(keyOptions: .strongMemory, valueOptions: .weakMemory)
    private let reverse = NSMapTable<AnyObject, NSNumber>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private var nextID: UInt64 = 1

    public init() {}

    @discardableResult
    public func id(for object: AnyObject) -> ObjectID {
        if let existing = reverse.object(forKey: object) {
            return existing.uint64Value
        }
        let id = nextID
        nextID &+= 1
        let key = NSNumber(value: id)
        forward.setObject(object, forKey: key)
        reverse.setObject(key, forKey: object)
        return id
    }

    public func object(for id: ObjectID) -> AnyObject? {
        forward.object(forKey: NSNumber(value: id))
    }

    public func drop(id: ObjectID) {
        forward.removeObject(forKey: NSNumber(value: id))
    }

    public func reset() {
        forward.removeAllObjects()
        reverse.removeAllObjects()
        nextID = 1
    }
}
#endif
