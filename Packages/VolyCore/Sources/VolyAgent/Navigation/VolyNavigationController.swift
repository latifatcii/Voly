#if canImport(UIKit)
import UIKit
import OSLog
#if !VOLY_UNIFIED_BUILD
import VolyModels
#endif

nonisolated(unsafe) private let log = Logger(subsystem: "com.latifatci.VolyAgent", category: "Navigation")

/// Dismiss / pop / pop-to-root for the app's *currently visible* UIKit
/// navigation context.
///
/// Works on whatever is on top right now — the deepest presented controller
/// and the navigation stack inside it — never on `rootViewController` by
/// assumption. Every action re-checks availability, refuses to run during a
/// transition, and reports why when it does nothing.
@MainActor
public final class VolyNavigationController {
    /// Set while an action we started is still animating, so a double click
    /// in the inspector can't stack two pops.
    private var actionInFlight = false

    public init() {}

    // MARK: - State

    public func state() -> NavigationState {
        guard let context = Context.current() else {
            let reason = "The app has no active window with a view controller."
            return NavigationState(
                canDismiss: false, canPop: false, canPopToRoot: false,
                unavailableReasons: Dictionary(uniqueKeysWithValues: NavigationAction.allCases.map { ($0.rawValue, reason) }),
                topViewController: nil, navigationStackDepth: nil, isTransitioning: false
            )
        }
        let transitioning = actionInFlight || context.isTransitioning
        var reasons: [String: String] = [:]
        for action in NavigationAction.allCases {
            if transitioning {
                reasons[action.rawValue] = "A transition is in progress."
            } else if let reason = context.unavailableReason(for: action) {
                reasons[action.rawValue] = reason
            }
        }
        return NavigationState(
            canDismiss: reasons[NavigationAction.dismiss.rawValue] == nil,
            canPop: reasons[NavigationAction.pop.rawValue] == nil,
            canPopToRoot: reasons[NavigationAction.popToRoot.rawValue] == nil,
            unavailableReasons: reasons,
            topViewController: String(describing: type(of: context.navigation?.topViewController ?? context.visibleLeaf)),
            navigationStackDepth: context.navigation?.viewControllers.count,
            isTransitioning: transitioning
        )
    }

    // MARK: - Actions

    public func perform(_ action: NavigationAction) -> NavigationResult {
        let before = state()
        guard before.isAvailable(action), let context = Context.current() else {
            let reason = before.unavailableReasons[action.rawValue] ?? "Not available right now."
            log.info("navigate \(action.rawValue, privacy: .public): refused — \(reason, privacy: .public)")
            return NavigationResult(action: action, performed: false, message: reason, state: before)
        }

        actionInFlight = true
        let coordinatorOwner: UIViewController
        switch action {
        case .dismiss:
            if let search = context.top as? UISearchController {
                search.isActive = false
                coordinatorOwner = search
            } else {
                // Asking the presenter dismisses exactly this presentation
                // (and anything it presented), nothing beneath it.
                let presenter = context.top.presentingViewController ?? context.top
                presenter.dismiss(animated: true)
                coordinatorOwner = context.top
            }
        case .pop:
            guard let navigation = context.navigation else { return finishWithoutTransition(action) }
            navigation.popViewController(animated: true)
            coordinatorOwner = navigation
        case .popToRoot:
            guard let navigation = context.navigation else { return finishWithoutTransition(action) }
            navigation.popToRootViewController(animated: true)
            coordinatorOwner = navigation
        }
        releaseWhenSettled(coordinatorOwner)
        log.notice("navigate \(action.rawValue, privacy: .public): started")
        return NavigationResult(action: action, performed: true, message: nil, state: state())
    }

    private func finishWithoutTransition(_ action: NavigationAction) -> NavigationResult {
        actionInFlight = false
        return NavigationResult(
            action: action, performed: false,
            message: "No navigation controller is visible.", state: state()
        )
    }

    private func releaseWhenSettled(_ controller: UIViewController) {
        if let coordinator = controller.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.actionInFlight = false }
            }
        }
        // Belt and braces: an interrupted or non-animated transition may
        // never call the coordinator completion.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            MainActor.assumeIsolated { self?.actionInFlight = false }
        }
    }

    // MARK: - Visible context

    /// Snapshot of "what is on screen" used by both the availability check
    /// and the action itself, so they can't disagree.
    @MainActor
    private struct Context {
        let root: UIViewController
        /// Deepest presented controller (== `root` when nothing is presented).
        let top: UIViewController
        /// Navigation stack the user is looking at inside `top`.
        let navigation: UINavigationController?
        let visibleLeaf: UIViewController

        static func current() -> Context? {
            guard let root = activeWindow()?.rootViewController else { return nil }
            var top = root
            while let presented = top.presentedViewController, !presented.isBeingDismissed {
                top = presented
            }
            let (navigation, leaf) = visibleNavigation(in: top)
            return Context(root: root, top: top, navigation: navigation, visibleLeaf: leaf)
        }

        var isTransitioning: Bool {
            top.isBeingPresented || top.isBeingDismissed
                || top.transitionCoordinator != nil
                || navigation?.transitionCoordinator != nil
        }

        func unavailableReason(for action: NavigationAction) -> String? {
            switch action {
            case .dismiss:
                guard top !== root, top.presentingViewController != nil else {
                    return "Nothing is presented."
                }
                if top is UIAlertController {
                    // Dismissing would skip the alert's action handlers and
                    // can leave the app waiting on an answer that never comes.
                    return "An alert is showing — answer it in the simulator."
                }
                return nil
            case .pop, .popToRoot:
                guard let navigation else { return "No navigation controller is visible." }
                guard navigation.viewControllers.count > 1 else { return "Already at the root screen." }
                return nil
            }
        }

        private static func activeWindow() -> UIWindow? {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let ordered = scenes.filter { $0.activationState == .foregroundActive }
                + scenes.filter { $0.activationState != .foregroundActive }
            for scene in ordered {
                let candidates = scene.windows.filter {
                    !$0.isVolyOverlay && !$0.isHidden && !SelectionHitTest.isSystemWindow($0)
                        && $0.rootViewController != nil
                }
                if let key = candidates.first(where: { $0.isKeyWindow }) { return key }
                // Pick mode makes Voly's overlay key; fall back to the
                // lowest-level app window, which is the app's main one.
                if let main = candidates.min(by: { $0.windowLevel.rawValue < $1.windowLevel.rawValue }) {
                    return main
                }
            }
            return nil
        }

        /// Follow the visible branch (selected tab, top of stack, on-screen
        /// child) and return the innermost navigation controller that can
        /// actually pop, falling back to the innermost one.
        private static func visibleNavigation(in start: UIViewController) -> (UINavigationController?, UIViewController) {
            var stacks: [UINavigationController] = []
            var current = start
            var hops = 0
            while hops < 32 {
                hops += 1
                let next: UIViewController?
                if let navigation = current as? UINavigationController {
                    stacks.append(navigation)
                    next = navigation.topViewController
                } else if let tabs = current as? UITabBarController {
                    next = tabs.selectedViewController
                } else if let split = current as? UISplitViewController {
                    next = split.viewControllers.last
                } else if let pages = current as? UIPageViewController {
                    next = pages.viewControllers?.first
                } else {
                    next = current.children.last { $0.isViewLoaded && $0.view.window != nil }
                }
                guard let next else { break }
                current = next
            }
            let poppable = stacks.last { $0.viewControllers.count > 1 }
            return (poppable ?? stacks.last ?? current.navigationController, current)
        }
    }
}
#endif
