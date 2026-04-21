#if canImport(UIKit)
import UIKit

@MainActor
public final class URLExecutor {
    public init() {}

    public func open(_ url: URL) async -> (Bool, String?) {
        guard UIApplication.shared.canOpenURL(url) else {
            return (false, "No handler registered for scheme '\(url.scheme ?? "")'.")
        }
        let success = await UIApplication.shared.open(url, options: [:])
        return (success, success ? nil : "UIApplication.open returned false")
    }
}
#endif
