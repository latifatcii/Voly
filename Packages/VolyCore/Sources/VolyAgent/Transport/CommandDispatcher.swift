#if canImport(UIKit)
import UIKit
import Foundation
#if !VOLY_UNIFIED_BUILD
import VolyProtocol
#endif
#if !VOLY_UNIFIED_BUILD
import VolyModels
#endif

@MainActor
public final class CommandDispatcher {
    public let snapshots: SnapshotBuilder
    public let mutations: MutationExecutor
    public let registry: ObjectRegistry
    public let pick: PickEngine
    public let overlay: OverlayHost
    public let defaults: UserDefaultsProvider
    public let urls: URLExecutor
    public let preview: PreviewHostProvider
    public let source: SourceInfoProvider

    public init(
        registry: ObjectRegistry,
        snapshots: SnapshotBuilder,
        mutations: MutationExecutor,
        pick: PickEngine,
        overlay: OverlayHost,
        defaults: UserDefaultsProvider,
        urls: URLExecutor,
        preview: PreviewHostProvider,
        source: SourceInfoProvider
    ) {
        self.registry = registry
        self.snapshots = snapshots
        self.mutations = mutations
        self.pick = pick
        self.overlay = overlay
        self.defaults = defaults
        self.urls = urls
        self.preview = preview
        self.source = source
    }

    public func handle(envelope: MessageEnvelope) async -> MessageEnvelope {
        do {
            let command = try Framing.decodeCommand(envelope)
            let response = try await handle(command)
            return try Framing.encodeResponse(response, id: envelope.id)
        } catch let error as InspectorError {
            let response = Response.error(error)
            return (try? Framing.encodeResponse(response, id: envelope.id))
                ?? MessageEnvelope(id: envelope.id, kind: .error, payload: Data())
        } catch {
            let wrapped = InspectorError.internal(error.localizedDescription)
            let response = Response.error(wrapped)
            return (try? Framing.encodeResponse(response, id: envelope.id))
                ?? MessageEnvelope(id: envelope.id, kind: .error, payload: Data())
        }
    }

    private func handle(_ command: Command) async throws -> Response {
        switch command {
        case .handshake:
            let bundle = Bundle.main
            let accepted = HandshakeAccepted(
                protocolVersion: ProtocolVersion.current,
                sessionID: UUID(),
                agentName: "VolyAgent",
                agentVersion: "0.1.0",
                bundleIdentifier: bundle.bundleIdentifier,
                processName: ProcessInfo.processInfo.processName
            )
            return .handshakeAccepted(accepted)

        case .getHierarchy:
            return .hierarchy(snapshots.snapshotAllScenes())

        case .getSubtree(let id, let depth):
            return .subtree(try snapshots.snapshot(for: id, maxDepth: depth))

        case .getProperties(let id):
            return .properties(try snapshots.propertyBag(for: id))

        case .setProperty(let req):
            try mutations.applyProperty(req)
            let refreshed = try snapshots.snapshot(for: req.objectID, maxDepth: 1)
            return .subtree(refreshed)

        case .getConstraints(let id):
            return .constraints(try snapshots.constraints(for: id))

        case .setConstraint(let req):
            try mutations.applyConstraint(req)
            let refreshed = try snapshots.snapshot(for: req.anchorObjectID, maxDepth: 1)
            return .subtree(refreshed)

        case .enterPickMode:
            pick.enter()
            return .pickModeChanged(true)

        case .exitPickMode:
            pick.exit()
            return .pickModeChanged(false)

        case .selectAt(let x, let y, let sceneID):
            let id = try pick.select(at: CGPoint(x: x, y: y), sceneID: sceneID)
            overlay.highlight(viewID: id)
            return .selection(id)

        case .userDefaultsList(let suite):
            return .userDefaults(defaults.list(suite: suite))

        case .userDefaultsSet(let req):
            try defaults.set(req)
            return .ack

        case .userDefaultsDelete(let suite, let key):
            defaults.delete(suite: suite, key: key)
            return .ack

        case .openURL(let url):
            let (ok, err) = await urls.open(url)
            return .urlResult(success: ok, error: err)

        case .setPreviewConfig(let config):
            guard let host = preview.previewHost else {
                return .error(.internal("Preview host not installed. Call VolyAgent.wrap(original:) at scene setup."))
            }
            return .previewApplied(host.apply(config))

        case .clearPreview:
            preview.previewHost?.teardown()
            return .ack

        case .resolveSource(let id):
            return .sourceInfo(try source.info(for: id, registry: registry))

        case .ping:
            return .pong

        case .clearSelection:
            overlay.clear()
            return .ack

        case .highlight(let id):
            overlay.highlight(viewID: id)
            return .ack

        case .measure(let overlay):
            self.overlay.showMeasurement(overlay)
            return .ack
        case .clearMeasure:
            self.overlay.clearMeasurement()
            return .ack

        case .hoverAt(let x, let y, let sceneID):
            // Live hit-test on the agent so passthrough views (e.g. iOS 26's
            // floating tab bar container) and hitTest overrides are respected.
            // Snapshot-based client walk can't replicate those.
            guard let scene = registry.object(for: sceneID) as? UIWindowScene else {
                return .hoverResult(nil)
            }
            let id = SelectionHitTest.hitTest(in: scene, at: CGPoint(x: x, y: y), registry: registry)
            return .hoverResult(id == 0 ? nil : id)

        case .measureHover(let anchorID, let x, let y, let sceneID):
            return measureHover(anchorID: anchorID, x: x, y: y, sceneID: sceneID)
        }
    }

    /// Live hit-test + measurement + draw, in one round-trip.
    /// Uses live `view.convert(bounds, to: nil)` for both views so the drawn
    /// overlay always matches what's visible on the simulator, regardless of
    /// snapshot staleness.
    private func measureHover(anchorID: ObjectID, x: Double, y: Double, sceneID: ObjectID) -> Response {
        guard let scene = registry.object(for: sceneID) as? UIWindowScene else {
            overlay.clearMeasurement()
            return .measureHoverResult(otherID: nil, summary: nil)
        }
        guard let anchorView = registry.object(for: anchorID) as? UIView else {
            overlay.clearMeasurement()
            return .measureHoverResult(otherID: nil, summary: nil)
        }
        let otherID = SelectionHitTest.hitTest(in: scene, at: CGPoint(x: x, y: y), registry: registry)
        guard otherID != 0,
              let otherView = registry.object(for: otherID) as? UIView
        else {
            overlay.clearMeasurement()
            return .measureHoverResult(otherID: nil, summary: nil)
        }

        // Fresh window-coord frames — the whole point of routing through the
        // agent is to avoid stale snapshot frames.
        let anchorFrame = anchorView.convert(anchorView.bounds, to: nil)
        let otherFrame = otherView.convert(otherView.bounds, to: nil)
        let anchorTransformed = !CATransform3DIsIdentity(anchorView.layer.transform)
        let otherTransformed = !CATransform3DIsIdentity(otherView.layer.transform)
        let sharedWindow = anchorView.window === otherView.window

        guard let result = FrameMeasurement.compute(
            anchorFrame: anchorFrame,
            otherFrame: otherFrame,
            anchorTransformed: anchorTransformed,
            otherTransformed: otherTransformed,
            sharedWindow: sharedWindow
        ) else {
            overlay.clearMeasurement()
            let summary = sharedWindow
                ? nil
                : MeasurementSummary(kind: .crossWindow, horizontal: nil, vertical: nil)
            return .measureHoverResult(otherID: otherID, summary: summary)
        }

        // sameView: clear on-sim guides, surface summary for header badge.
        if result.summary.kind == .sameView {
            overlay.clearMeasurement()
            return .measureHoverResult(otherID: otherID, summary: result.summary)
        }

        overlay.showMeasurement(result)
        return .measureHoverResult(otherID: otherID, summary: result.summary)
    }
}

public protocol PreviewHostProvider: AnyObject, Sendable {
    @MainActor var previewHost: PreviewHostVC? { get }
}

@MainActor
public protocol SourceInfoProvider: AnyObject {
    func info(for id: ObjectID, registry: ObjectRegistry) throws -> SourceInfo
}

@MainActor
public final class DefaultSourceInfoProvider: SourceInfoProvider {
    public init() {}

    public func info(for id: ObjectID, registry: ObjectRegistry) throws -> SourceInfo {
        guard let object = registry.object(for: id) else {
            throw InspectorError.objectGone(id)
        }
        let full = String(reflecting: type(of: object))
        let parts = full.split(separator: ".")
        let className = parts.last.map(String.init) ?? full
        let moduleName = parts.dropLast().joined(separator: ".")
        return SourceInfo(
            className: className,
            moduleName: moduleName.isEmpty ? nil : moduleName,
            dsymUUID: nil,
            guessedRelativePath: ClassIndex.shared.path(for: className)
        )
    }
}

@MainActor
public final class ClassIndex {
    public static let shared = ClassIndex()
    private var index: [String: String] = [:]
    public init() { loadBundled() }

    public func path(for className: String) -> String? { index[className] }

    private func loadBundled() {
        guard let url = Bundle.main.url(forResource: "VolyClassIndex", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        self.index = decoded
    }
}
#endif
