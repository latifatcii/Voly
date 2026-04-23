#if canImport(UIKit)
import UIKit
import Foundation
import OSLog
#if !VOLY_UNIFIED_BUILD
import VolyProtocol
#endif
#if !VOLY_UNIFIED_BUILD
import VolyModels
#endif

nonisolated(unsafe) private let log = Logger(subsystem: "com.latifatci.VolyAgent", category: "Runtime")

@MainActor
public final class VolyAgentRuntime: PreviewHostProvider {
    public static let shared = VolyAgentRuntime()

    public private(set) var registry: ObjectRegistry!
    public private(set) var snapshots: SnapshotBuilder!
    public private(set) var mutations: MutationExecutor!
    public private(set) var pick: PickEngine!
    public private(set) var hover: HoverEngine!
    public private(set) var overlay: OverlayHost!
    public private(set) var defaults: UserDefaultsProvider!
    public private(set) var urls: URLExecutor!
    public private(set) var dispatcher: CommandDispatcher!
    public private(set) var source: DefaultSourceInfoProvider!

    public weak var previewHost: PreviewHostVC?

    public enum Mode: Sendable {
        case sdk        // linked via SPM; Bonjour advertising on
        case injected   // loaded via DYLD_INSERT_LIBRARIES; port file only
    }

    private var server: WebSocketServer?
    private var portFilePublisher: PortFilePublisher?
    private var bootstrapped = false
    private var mode: Mode = .sdk

    public func bootstrap(mode: Mode = .sdk) {
        guard !bootstrapped else { return }
        bootstrapped = true
        self.mode = mode

        self.registry = ObjectRegistry()
        self.snapshots = SnapshotBuilder(registry: registry)
        self.mutations = MutationExecutor(registry: registry)
        self.overlay = OverlayHost(registry: registry)
        self.pick = PickEngine(registry: registry, overlay: overlay)
        self.hover = HoverEngine(registry: registry)
        self.defaults = UserDefaultsProvider()
        self.urls = URLExecutor()
        self.source = DefaultSourceInfoProvider()
        self.dispatcher = CommandDispatcher(
            registry: registry,
            snapshots: snapshots,
            mutations: mutations,
            pick: pick,
            hover: hover,
            overlay: overlay,
            defaults: defaults,
            urls: urls,
            preview: self,
            source: source
        )
        startServer()
        observePickNotifications()
    }

    private func startServer() {
        let deviceName = UIDevice.current.name
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "App"
        let name = "\(appName) — \(deviceName)"
        let server = WebSocketServer(serviceName: name)
        self.server = server
        let advertise = (mode == .sdk)
        let shouldPublishPortFile = (mode == .injected)
        Task {
            try? await server.start(advertise: advertise)
            if shouldPublishPortFile {
                await self.publishPortFileIfReady()
            }
            await self.pumpIncoming(server: server)
        }
    }

    private func publishPortFileIfReady() async {
        // Poll briefly for the listener to bind.
        for _ in 0..<20 {
            if let port = await server?.boundPort {
                let publisher = PortFilePublisher()
                let pid = ProcessInfo.processInfo.processIdentifier
                let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
                let processName = ProcessInfo.processInfo.processName
                do {
                    try publisher.publish(
                        port: port, pid: pid,
                        bundleIdentifier: bundleID, processName: processName
                    )
                    self.portFilePublisher = publisher
                    installTerminationObserver()
                } catch {
                    log.error("failed to publish port file: \(String(describing: error), privacy: .public)")
                }
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        log.error("server never bound to a port; port file not published")
    }

    private func installTerminationObserver() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.portFilePublisher?.remove()
            }
        }
    }

    private func pumpIncoming(server: WebSocketServer) async {
        for await envelope in server.incoming {
            let response = await dispatcher.handle(envelope: envelope)
            try? await server.send(response)
        }
    }

    private func observePickNotifications() {
        NotificationCenter.default.addObserver(
            forName: PickEngine.Notification.didPick,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // We put the ObjectID in note.object as NSNumber to avoid userInfo bridging bugs.
            let id = (note.object as? NSNumber)?.uint64Value
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let id, id != 0 else {
                    log.error("pick notification with no id — ignoring")
                    return
                }
                // Keep pick mode active so the user can select another view
                // without round-tripping through the toolbar. The inspector
                // sends Command.exitPickMode when the user explicitly toggles off.
                log.notice("pick id=\(id) — highlight + send event (pick stays active)")
                self.overlay.highlight(viewID: id)
                if let server = self.server {
                    let event = Event.selectionChanged(id)
                    if let envelope = try? Framing.encodeEvent(event, id: 0) {
                        do {
                            try await server.send(envelope)
                            log.notice("selectionChanged(\(id)) event sent")
                        } catch {
                            log.error("failed to send selectionChanged event: \(String(describing: error), privacy: .public)")
                        }
                    }
                }
            }
        }
    }
}

public enum VolyAgent {
    /// Install the agent. Safe to call unconditionally — becomes a no-op when the
    /// DEBUG / env-var gate is not satisfied or when called on a non-iOS build.
    public static func start() {
        #if DEBUG
        guard AgentGate.isSDKEnabled else { return }
        MainActor.assumeIsolated {
            VolyAgentRuntime.shared.bootstrap()
        }
        #endif
    }

    /// Wrap the app's root view controller with the preview host. Pass-through
    /// when the agent isn't enabled, so production code stays untouched.
    @MainActor
    public static func wrap(original: UIViewController) -> UIViewController {
        guard AgentGate.isSDKEnabled else { return original }
        let host = PreviewHostVC(wrapping: original)
        VolyAgentRuntime.shared.bootstrap()
        VolyAgentRuntime.shared.previewHost = host
        return host
    }

    /// Register an explicit inspectable property for a custom view type.
    @MainActor
    public static func register<T: UIKit.UIView>(
        _ viewType: T.Type,
        property name: String,
        type: CustomPropDescriptor.DeclaredType,
        get: @escaping @MainActor (T) -> PropValue,
        set: (@MainActor (T, PropValue) -> Void)? = nil
    ) {
        guard AgentGate.isSDKEnabled else { return }
        CustomInspectableRegistry.shared.register(viewType, property: name, type: type, get: get, set: set)
    }
}
#endif
