import Foundation
import VolyCodables
import VolyModels
import VolyProtocol

/// The tools Voly offers to AI agents, on top of whatever `MCPInspecting`
/// it is given. Everything an agent reads comes back as compact text (plus
/// PNGs for screenshots); see `ScreenDescriptionFormatter` for the format.
public struct MCPToolbox: MCPToolProviding {
    public typealias SourceResolver = @Sendable (SourceInfo) async -> SourceLookup
    public typealias SimulatorCapture = @Sendable (_ udid: String) async throws -> Data

    private let inspector: MCPInspecting
    private let resolveSource: SourceResolver
    private let captureSimulator: SimulatorCapture
    private let formatter: ScreenDescriptionFormatter
    /// How long an app gets to answer one command.
    private let commandTimeout: Duration
    /// Which apps can describe their screen, as far as it has been found out.
    private let screenSupport = ScreenSupport()

    public init(
        inspector: MCPInspecting,
        formatter: ScreenDescriptionFormatter = ScreenDescriptionFormatter(),
        commandTimeout: Duration = .seconds(15),
        resolveSource: SourceResolver? = nil,
        captureSimulator: SimulatorCapture? = nil
    ) {
        self.inspector = inspector
        self.formatter = formatter
        self.commandTimeout = commandTimeout
        self.resolveSource = resolveSource ?? { await VolySourceNavigator().resolve($0) }
        self.captureSimulator = captureSimulator ?? { try await SimulatorScreenshot().capturePNG(deviceUDID: $0) }
    }

    public var tools: [MCPTool] { Self.definitions }

    public func call(_ name: String, arguments: JSONValue) async -> MCPToolResult? {
        guard let tool = Self.definitions.first(where: { $0.name == name }) else { return nil }
        switch await inspector.access {
        case .off:
            return .error("""
                AI agent access is turned off in Voly. The user can turn it on from the Voly menu bar \
                icon → AI Agents → Allow Agents to Inspect Apps.
                """)
        case .readOnly where tool.changesApp:
            return .error("""
                Voly is set to read-only for AI agents, and \(name) changes the running app. The user can \
                allow it from the Voly menu bar icon → AI Agents → Allow Agents to Change the App.
                """)
        default:
            break
        }
        await inspector.noteToolCall(name)
        do {
            return try await run(name, Arguments(arguments))
        } catch {
            return .error(Self.message(error))
        }
    }

    // MARK: - Dispatch

    private func run(_ name: String, _ arguments: Arguments) async throws -> MCPToolResult {
        switch name {
        case "list_apps": return try await listApps()
        case "get_screen": return try await getScreen(arguments)
        case "get_view": return try await getView(arguments)
        case "find_views": return try await findViews(arguments)
        case "get_selection": return try await getSelection(arguments)
        case "select_view": return try await selectView(arguments)
        case "screenshot": return try await screenshot(arguments)
        case "get_app_state": return try await getAppState(arguments)
        case "get_user_defaults": return try await getUserDefaults(arguments)
        case "set_property": return try await setProperty(arguments)
        case "set_constraint": return try await setConstraint(arguments)
        case "navigate": return try await navigate(arguments)
        case "set_language": return try await setLanguage(arguments)
        case "open_url": return try await openURL(arguments)
        case "set_user_default": return try await setUserDefault(arguments)
        case "relaunch_app": return try await relaunchApp(arguments)
        default: throw ToolError("Unknown tool: \(name)")
        }
    }

    // MARK: - Apps

    private func listApps() async throws -> MCPToolResult {
        let overview = await inspector.overview()
        let simulators = overview.simulators.filter { $0.platform == .iOS }
        let androidDevices = overview.simulators.filter { $0.platform == .android }
        var lines: [String] = []
        if simulators.isEmpty {
            lines.append(androidDevices.isEmpty ? "No simulator is booted." : "No iOS simulator is booted.")
        } else {
            lines.append("Booted simulators:")
            for simulator in simulators {
                lines.append("- \(simulator.name), \(simulator.runtime) (\(simulator.udid)): \(simulator.integration)")
                if !simulator.appsWithoutAgent.isEmpty {
                    lines.append("    running but not inspectable (started before Voly): "
                        + simulator.appsWithoutAgent.joined(separator: ", ")
                        + " — relaunch_app makes them inspectable")
                }
            }
        }
        if !androidDevices.isEmpty {
            lines.append("Android emulators and devices:")
            for device in androidDevices {
                lines.append("- \(device.name), \(device.runtime) (\(device.udid)): \(device.integration)")
                if !device.appsWithoutAgent.isEmpty {
                    lines.append("    running but not inspectable: "
                        + device.appsWithoutAgent.joined(separator: ", ")
                        + " — Voly can only inspect debuggable (debug) builds on Android")
                }
            }
        }
        lines.append("")
        if overview.apps.isEmpty {
            lines.append("""
                No inspectable app is running. Apps launched in a booted simulator while Voly is running \
                (from Xcode, simctl or the home screen) are picked up automatically, usually within a \
                couple of seconds of launch.
                """ + (androidDevices.isEmpty ? "" : """
                 On Android, debug builds running in an emulator are picked up the same way, whether \
                they were started before or after Voly.
                """))
        } else {
            let outdated = await appsWithOutdatedAgent(among: overview.apps)
            lines.append("Inspectable apps:")
            for app in overview.apps {
                lines.append("- " + Self.describe(app)
                    + (outdated.contains(app.id) ? "  [older Voly agent: relaunch to read its screen]" : ""))
            }
            if overview.apps.count > 1 {
                lines.append("Pass app=<bundle id> to a tool to pick one; without it the app shown in Voly is used.")
            }
            if !outdated.isEmpty {
                lines.append("""
                    An app marked "older Voly agent" was launched before Voly was updated and still runs the \
                    agent it started with, so get_screen, get_view and find_views don't work on it yet. \
                    Launching it again fixes that: Run from Xcode (keeps the debugger), or relaunch_app (ends \
                    an attached debug session and the app's current state). screenshot and get_app_state work \
                    on it as it is.
                    """)
            }
        }
        return .text(lines.joined(separator: "\n"))
    }

    private static func describe(_ app: MCPApp) -> String {
        var parts = [app.name]
        if let bundle = app.bundleIdentifier { parts.append("bundle=\(bundle)") }
        if let pid = app.pid { parts.append("pid=\(pid)") }
        if let simulator = app.simulatorName ?? app.simulatorUDID {
            parts.append(app.platform == .android ? "android=\(simulator)" : "simulator=\(simulator)")
        }
        if app.isShownInVoly { parts.append("[shown in Voly]") }
        return parts.joined(separator: "  ")
    }

    /// The app a tool call is about: the one named by `app`, else the one
    /// Voly is showing, else the only one there is.
    private func targetApp(_ arguments: Arguments) async throws -> MCPApp {
        var apps = await inspector.apps()
        if apps.isEmpty { apps = await inspector.overview().apps }
        guard !apps.isEmpty else {
            throw ToolError("""
                No inspectable app is running. Launch the app in a booted simulator (apps started while \
                Voly is running are picked up automatically), then try again. list_apps shows what Voly sees.
                """)
        }
        if let wanted = arguments.string("app") {
            let needle = wanted.lowercased()
            let matches = apps.filter {
                $0.bundleIdentifier?.lowercased() == needle || $0.name.lowercased() == needle
                    || $0.pid.map(String.init) == wanted || $0.id == wanted
            }
            if matches.isEmpty {
                throw ToolError("No inspectable app matches \"\(wanted)\". Running: "
                    + apps.map(Self.describe).joined(separator: "; "))
            }
            return matches.first(where: \.isShownInVoly) ?? matches[0]
        }
        if let shown = apps.first(where: \.isShownInVoly) { return shown }
        if apps.count == 1 { return apps[0] }
        throw ToolError("Several apps are inspectable — say which with app=<bundle id>: "
            + apps.map(Self.describe).joined(separator: "; "))
    }

    /// One command, with a bound on how long the app may take: an app
    /// stopped at a breakpoint never answers.
    private func send(_ command: Command, to app: MCPApp, timeout: Duration? = nil) async throws -> Response {
        let inspector = self.inspector
        let timeout = timeout ?? commandTimeout
        return try await withCheckedThrowingContinuation { continuation in
            let gate = OnceGate()
            Task {
                do {
                    let response = try await inspector.send(command, to: app.id)
                    if gate.claim() { continuation.resume(returning: response) }
                } catch {
                    if gate.claim() { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if gate.claim() {
                    continuation.resume(throwing: ToolError("""
                        \(app.name) didn't answer in time. It may be paused in the debugger or busy on its \
                        main thread.
                        """))
                }
            }
        }
    }

    // MARK: - Apps still running an older agent

    /// A request no agent can fulfil, which still tells the two kinds
    /// apart: a current agent looks for the view and says it doesn't exist,
    /// one from before screen descriptions can't even read the request.
    /// Nothing in the app is touched either way.
    private static let screenSupportProbe = Command.describeScreen(ScreenDescriptionRequest(
        rootID: .max, maxDepth: 0, checkLayout: false, includeAccessibility: false
    ))

    /// Nil when it can't be told right now (the app didn't answer).
    private func canDescribeScreen(_ app: MCPApp) async -> Bool? {
        if let known = screenSupport[app.id] { return known }
        let answer: Bool?
        do {
            _ = try await send(Self.screenSupportProbe, to: app, timeout: .seconds(3))
            answer = true
        } catch InspectorError.objectGone {
            answer = true
        } catch InspectorError.internal {
            answer = false
        } catch {
            answer = nil
        }
        if let answer { screenSupport[app.id] = answer }
        return answer
    }

    private func appsWithOutdatedAgent(among apps: [MCPApp]) async -> Set<String> {
        await withTaskGroup(of: String?.self) { group in
            for app in apps {
                group.addTask { await canDescribeScreen(app) == false ? app.id : nil }
            }
            var outdated: Set<String> = []
            for await id in group {
                if let id { outdated.insert(id) }
            }
            return outdated
        }
    }

    private static func outdatedAgentMessage(_ app: MCPApp) -> String {
        """
        \(app.name) is still running the Voly agent it was launched with, from before Voly was updated, and \
        that agent can't describe screens. Launch the app again to load the current agent: Run it again from \
        Xcode (keeps the debugger), or call relaunch_app (ends an attached debug session and the app's \
        current state). If VolyAgent is linked into the app as a Swift package instead, update the package. \
        screenshot and get_app_state work on the app as it is.
        """
    }

    private func describeScreen(_ request: ScreenDescriptionRequest, in app: MCPApp) async throws -> ScreenDescription {
        // Known already: say so without bothering the app again.
        if screenSupport[app.id] == false { throw ToolError(Self.outdatedAgentMessage(app)) }
        let response: Response
        do {
            response = try await send(.describeScreen(request), to: app)
        } catch InspectorError.internal(let detail) {
            if await canDescribeScreen(app) == false { throw ToolError(Self.outdatedAgentMessage(app)) }
            throw ToolError("\(app.name) couldn't describe its screen: \(detail)")
        }
        guard case .screenDescription(let screen) = response else {
            throw ToolError("\(app.name) gave an unexpected answer.")
        }
        return screen
    }

    // MARK: - Reading the screen

    private func getScreen(_ arguments: Arguments) async throws -> MCPToolResult {
        let app = try await targetApp(arguments)
        let request = ScreenDescriptionRequest(
            rootID: try arguments.viewID("root"),
            maxDepth: arguments.int("max_depth").map { max(0, $0) },
            includeHidden: arguments.bool("include_hidden") ?? false
        )
        let screen = try await describeScreen(request, in: app)
        var formatter = self.formatter
        formatter.collapsesWrappers = arguments.bool("collapse_wrappers") ?? true
        let tree = formatter.tree(for: screen)

        var sections = [formatter.header(for: screen, simulator: app.simulatorName, platform: app.platform)]
        var counts = "\(screen.viewCount) views."
        if screen.isTruncated { counts += " The app has more; this is the first \(screen.viewCount)." }
        if let levels = tree.levelsShown {
            counts += " Too large to show whole: cut to \(levels) levels. Ask for a part with root=<id>."
        }
        sections.append(counts + " " + ScreenDescriptionFormatter.legend(for: app.platform))
        if let ancestors = screen.ancestors, !ancestors.isEmpty {
            sections.append("Inside: " + Self.path(ancestors))
        }
        sections.append(tree.text)
        if let problems = formatter.problems(in: screen) { sections.append(problems) }
        return .text(sections.joined(separator: "\n\n"))
    }

    private static func path(_ ancestors: [ViewAncestor], last count: Int = 8) -> String {
        let shown = ancestors.suffix(count).map { ancestor in
            "\(ScreenDescriptionFormatter.shortClassName(ancestor.className)) #\(ancestor.id)"
                + (ancestor.viewController.map { " (\(ScreenDescriptionFormatter.shortClassName($0)))" } ?? "")
        }
        return (ancestors.count > count ? "… › " : "") + shown.joined(separator: " › ")
    }

    private func getView(_ arguments: Arguments) async throws -> MCPToolResult {
        let app = try await targetApp(arguments)
        guard let id = try arguments.viewID("view") else { throw ToolError("view is required: the #id of a view.") }
        let text = try await viewReport(id, in: app, includeSource: arguments.bool("source") ?? true)
        return .text(text)
    }

    private func viewReport(_ id: ObjectID, in app: MCPApp, includeSource: Bool) async throws -> String {
        let screen = try await describeScreen(ScreenDescriptionRequest(rootID: id, maxDepth: 1), in: app)
        guard let node = screen.roots.first else { throw InspectorError.objectGone(id) }

        var sections: [String] = []
        var summary = [formatter.line(for: node)]
        if let ancestors = screen.ancestors, !ancestors.isEmpty {
            summary.append("Inside: " + Self.path(ancestors))
            if node.viewController == nil,
               let controller = ancestors.last(where: { $0.viewController != nil })?.viewController {
                summary.append((app.platform == .android ? "Screen: " : "View controller: ")
                    + ScreenDescriptionFormatter.shortClassName(controller))
            }
        }
        if let layout = node.layout { summary.append(Self.describe(layout)) }
        sections.append(summary.joined(separator: "\n"))

        if let elements = node.accessibilityElements, !elements.isEmpty {
            sections.append((app.platform == .android ? "Compose semantics nodes inside:\n" : "Accessibility elements inside:\n")
                + elements.map { formatter.line(for: $0) }.joined(separator: "\n"))
        }
        if !node.children.isEmpty || node.omittedChildren > 0 {
            var lines = formatter.lines(for: node.children, maxLevels: 1)
            if node.omittedChildren > 0 { lines += (lines.isEmpty ? "" : "\n") + "(+\(node.omittedChildren) hidden subviews not listed)" }
            sections.append("Subviews (\(node.children.count)):\n" + lines)
        }

        do {
            guard case .constraints(let constraints) = try await send(.getConstraints(objectID: id), to: app) else {
                throw ToolError("unexpected answer")
            }
            sections.append(Self.describe(constraints, for: id, platform: app.platform))
        } catch {
            sections.append("Constraints: could not be read (\(Self.message(error))).")
        }

        do {
            guard case .properties(let bag) = try await send(.getProperties(objectID: id), to: app) else {
                throw ToolError("unexpected answer")
            }
            sections.append(Self.describe(bag, hidingTypedText: node.state.contains("secure")))
        } catch {
            sections.append("Properties: could not be read (\(Self.message(error))).")
        }

        if includeSource {
            sections.append(await sourceReport(id, in: app))
        }
        return sections.joined(separator: "\n\n")
    }

    private static func describe(_ layout: LayoutDetails) -> String {
        // An agent that describes layout in its platform's own terms.
        if let summary = layout.summary, !summary.isEmpty { return "Layout: " + summary }
        let number = ScreenDescriptionFormatter.number
        var parts = [layout.usesAutoLayout ? "Auto Layout" : "frame-based (autoresizing mask)"]
        parts.append("bounds \(ScreenDescriptionFormatter.frame(layout.bounds))")
        let width = layout.intrinsicWidth.map(number) ?? "none"
        let height = layout.intrinsicHeight.map(number) ?? "none"
        parts.append("intrinsic size \(width)×\(height)")
        parts.append("hugging H\(number(Double(layout.huggingHorizontal))) V\(number(Double(layout.huggingVertical)))")
        parts.append("compression resistance H\(number(Double(layout.compressionResistanceHorizontal)))"
            + " V\(number(Double(layout.compressionResistanceVertical)))")
        func insets(_ value: UIEdgeInsetsCodable) -> String {
            "top \(number(value.top)) left \(number(value.left)) bottom \(number(value.bottom)) right \(number(value.right))"
        }
        if layout.safeAreaInsets != .zero { parts.append("safe area \(insets(layout.safeAreaInsets))") }
        if layout.layoutMargins != .zero { parts.append("margins \(insets(layout.layoutMargins))") }
        return "Layout: " + parts.joined(separator: "; ")
    }

    private static func describe(
        _ constraints: [ConstraintNode], for viewID: ObjectID, platform: MCPPlatform = .iOS
    ) -> String {
        guard !constraints.isEmpty else {
            return platform == .android
                ? "Constraints: none (no fixed size, margin or ConstraintLayout connection)."
                : "Constraints: none."
        }
        let lines = constraints.map { constraint -> String in
            let presentation = ConstraintPresentation(constraint)
            var line = "- #\(constraint.id) "
            if let first = constraint.firstItemID, first != viewID { line += "(of view #\(first)) " }
            line += "\(presentation.label) \(presentation.value)"
            if let second = constraint.secondItemID {
                line += second == viewID ? " (this view)" : " (view #\(second))"
            }
            if constraint.priority != 1000 { line += " @\(ScreenDescriptionFormatter.number(Double(constraint.priority)))" }
            if let identifier = constraint.identifier, !identifier.isEmpty { line += " \"\(identifier)\"" }
            if constraint.isSystemGenerated { line += " [system]" }
            if !constraint.isActive { line += " [inactive]" }
            return line
        }
        let limit = 60
        let title = platform == .android
            ? "Layout params as constraints (\(constraints.count)): fixed sizes, margins and ConstraintLayout "
                + "connections, each with the #id set_constraint takes to change its constant (dp):\n"
            : "Constraints (\(constraints.count)), each with the #id set_constraint takes:\n"
        return title
            + lines.prefix(limit).joined(separator: "\n")
            + (lines.count > limit ? "\n…and \(lines.count - limit) more" : "")
    }

    private static func describe(_ bag: PropertyBag, hidingTypedText isSecure: Bool) -> String {
        func group(_ title: String, _ values: [String: PropValue]) -> String? {
            guard !values.isEmpty else { return nil }
            return "\(title): " + values.sorted { $0.key < $1.key }
                .map { "\($0.key)=\(describe($0.value))" }
                .joined(separator: ", ")
        }
        var lines = [group("view", bag.view), group("layer", bag.layer)].compactMap { $0 }
        let custom = bag.custom.filter { $0.currentValue != .null }
        // What is typed into a password field is not passed on to an agent.
        if !custom.isEmpty {
            lines.append("class-specific: " + custom.map {
                let value = isSecure && typedTextNames.contains($0.name) ? "(hidden: secure text)" : describe($0.currentValue)
                return "\($0.name)=\(value)" + ($0.isReadOnly ? " (read-only)" : "")
            }.joined(separator: ", "))
        }
        return "Properties (settable with set_property unless read-only):\n" + lines.joined(separator: "\n")
    }

    private static let typedTextNames: Set<String> = ["text", "attributedText", "ab_text", "searchText"]

    static func describe(_ value: PropValue) -> String {
        let number = ScreenDescriptionFormatter.number
        switch value {
        case .null: return "nil"
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return String((value * 1000).rounded() / 1000)
            .replacingOccurrences(of: #"\.0$"#, with: "", options: .regularExpression)
        case .string(let value):
            let shown = value.count > 200 ? String(value.prefix(200)) + "…" : value
            return "\"\(shown.replacingOccurrences(of: "\n", with: "\\n"))\""
        case .color(let value): return ScreenDescriptionFormatter.color(value)
        case .rect(let value): return ScreenDescriptionFormatter.frame(value)
        case .size(let value): return "\(number(value.width))×\(number(value.height))"
        case .point(let value): return "\(number(value.x)),\(number(value.y))"
        case .url(let value): return value.absoluteString
        case .arrayOf(let values):
            let shown = values.prefix(20).map(describe).joined(separator: ", ")
            return "[\(shown)\(values.count > 20 ? ", …+\(values.count - 20)" : "")]"
        case .dictOf(let values):
            let shown = values.sorted { $0.key < $1.key }.prefix(20)
                .map { "\($0.key): \(describe($0.value))" }.joined(separator: ", ")
            return "{\(shown)\(values.count > 20 ? ", …+\(values.count - 20)" : "")}"
        }
    }

    private func sourceReport(_ id: ObjectID, in app: MCPApp) async -> String {
        do {
            guard case .sourceInfo(let info) = try await send(.resolveSource(objectID: id), to: app) else {
                throw ToolError("unexpected answer")
            }
            let lookup = await resolveSource(info)
            guard !lookup.locations.isEmpty else {
                return "Source: not found" + (lookup.note.map { " — \($0)" } ?? ".")
            }
            let lines = lookup.locations.prefix(8).map { location -> String in
                var line = "- \(location.path)" + (location.line.map { ":\($0)" } ?? "")
                line += "  \(location.className)"
                switch location.role {
                case .viewClass?: line += " (this view's class)"
                case .superclass?: line += " (its app-defined superclass)"
                case .viewController?:
                    line += app.platform == .android
                        ? " (the fragment or activity that owns it)"
                        : " (the view controller that owns it)"
                case .ancestorView?: line += " (nearest app-defined view above it)"
                case nil: break
                }
                return line
            }
            return "Source (most specific first):\n" + lines.joined(separator: "\n")
                + (lookup.note.map { "\n\($0)" } ?? "")
        } catch {
            return "Source: could not be looked up (\(Self.message(error)))."
        }
    }

    static func message(_ error: Error) -> String {
        if let error = error as? ToolError { return error.message }
        if let error = error as? InspectorError {
            if case .objectGone(let id) = error {
                return """
                    The app has no view or constraint #\(id) (any more). Ids stop working when their view \
                    goes away or the app is relaunched — call get_screen for the current ones.
                    """
            }
            return error.humanDescription
        }
        return error.localizedDescription
    }

    private func findViews(_ arguments: Arguments) async throws -> MCPToolResult {
        let app = try await targetApp(arguments)
        let text = arguments.string("text")?.lowercased()
        let className = arguments.string("class_name")?.lowercased()
        let identifier = arguments.string("accessibility_id")?.lowercased()
        let x = arguments.double("x"), y = arguments.double("y")
        let problemsOnly = arguments.bool("problems_only") ?? false
        let limit = min(max(arguments.int("limit") ?? 30, 1), 200)
        guard text != nil || className != nil || identifier != nil || (x != nil && y != nil) || problemsOnly else {
            throw ToolError("Give at least one of: text, class_name, accessibility_id, x and y, problems_only.")
        }
        let screen = try await describeScreen(
            ScreenDescriptionRequest(includeHidden: arguments.bool("include_hidden") ?? false), in: app
        )

        struct Match { let line: String; let depth: Int }
        var matches: [Match] = []
        func contains(_ frame: CGRectCodable) -> Bool {
            guard let x, let y else { return true }
            return frame.cg.contains(CGPoint(x: x, y: y))
        }
        func visit(_ node: ViewDescription, path: [ViewDescription]) {
            let container = path.last(where: { $0.viewController != nil })?.viewController
                .map { " — in \(ScreenDescriptionFormatter.shortClassName($0))" }
                ?? path.last.map { " — in \(ScreenDescriptionFormatter.shortClassName($0.className)) #\($0.id)" } ?? ""
            let viewMatches = contains(node.frame)
                && (className.map { node.className.lowercased().contains($0) } ?? true)
                && (identifier.map { node.accessibilityIdentifier?.lowercased().contains($0) ?? false } ?? true)
                && (text.map { needle in
                    [node.text, node.placeholder, node.accessibilityLabel, node.value]
                        .contains { $0?.lowercased().contains(needle) ?? false }
                } ?? true)
                && (!problemsOnly || !node.flags.isEmpty)
            if viewMatches {
                matches.append(Match(line: formatter.line(for: node) + container, depth: path.count))
            }
            // SwiftUI content only exists as accessibility elements.
            if className == nil, !problemsOnly, text != nil || identifier != nil || x != nil {
                for element in node.accessibilityElements ?? [] {
                    let elementMatches = contains(element.frame)
                        && (identifier.map { element.identifier?.lowercased().contains($0) ?? false } ?? true)
                        && (text.map { needle in
                            [element.label, element.value].contains { $0?.lowercased().contains(needle) ?? false }
                        } ?? true)
                    if elementMatches {
                        matches.append(Match(
                            line: formatter.line(for: element)
                                + " — inside \(ScreenDescriptionFormatter.shortClassName(node.className)) #\(node.id)",
                            depth: path.count + 1
                        ))
                    }
                }
            }
            for child in node.children { visit(child, path: path + [node]) }
        }
        for root in screen.roots { visit(root, path: []) }

        guard !matches.isEmpty else { return .text("No matching views on the current screen.") }
        // For "what is at this point", the deepest view is the answer.
        if x != nil, y != nil { matches.sort { $0.depth > $1.depth } }
        var lines = ["\(matches.count) match\(matches.count == 1 ? "" : "es")"
            + (x != nil && y != nil ? ", innermost first" : "") + ":"]
        lines += matches.prefix(limit).map(\.line)
        if matches.count > limit { lines.append("…and \(matches.count - limit) more (raise limit to see them).") }
        return .text(lines.joined(separator: "\n"))
    }

    private func getSelection(_ arguments: Arguments) async throws -> MCPToolResult {
        guard let selection = await inspector.selection() else {
            return .text("""
                Nothing is selected in Voly. The user selects a view by clicking it in the simulator while \
                Voly's pick mode is on, or in Voly's tree.
                """)
        }
        guard let app = await inspector.apps().first(where: { $0.id == selection.appID }) else {
            throw ToolError("The app the selection belongs to is no longer running.")
        }
        let report = try await viewReport(selection.viewID, in: app, includeSource: arguments.bool("source") ?? true)
        return .text("Selected in Voly (\(app.name)):\n" + report)
    }

    private func selectView(_ arguments: Arguments) async throws -> MCPToolResult {
        let app = try await targetApp(arguments)
        guard let id = try arguments.viewID("view") else { throw ToolError("view is required: the #id of a view.") }
        let screen = try await describeScreen(ScreenDescriptionRequest(rootID: id, maxDepth: 0), in: app)
        try await inspector.select(view: id, in: app.id)
        let line = screen.roots.first.map { formatter.line(for: $0) } ?? "#\(id)"
        return .text("Selected in Voly and highlighted in the \(app.platform == .android ? "emulator" : "simulator"): \(line)")
    }

    // MARK: - Screenshots

    private func screenshot(_ arguments: Arguments) async throws -> MCPToolResult {
        let app = try await targetApp(arguments)
        let maxDimension = min(max(arguments.int("max_dimension") ?? 1568, 200), 4096)
        let viewID = try arguments.viewID("view")
        let target = arguments.string("target") ?? (viewID == nil ? "app" : "view")

        let png: Data
        var subject: String
        // Points per pixel of the capture, when known.
        var scale: Double?
        switch target {
        case "app":
            guard case .screenshot(let shot) = try await send(.captureScreenshot(.application), to: app) else {
                throw ToolError("\(app.name) gave an unexpected answer.")
            }
            png = shot.png
            scale = shot.scale
            subject = "\(app.name), the app's own windows"
        case "view":
            guard let viewID else { throw ToolError("target=view needs view=<#id>.") }
            guard case .screenshot(let shot) = try await send(.captureScreenshot(.view(viewID)), to: app) else {
                throw ToolError("\(app.name) gave an unexpected answer.")
            }
            png = shot.png
            scale = shot.scale
            subject = "view #\(viewID) of \(app.name)"
        case "simulator", "device", "emulator":
            guard let udid = app.simulatorUDID else {
                throw ToolError("\(app.name) isn't running in a simulator Voly knows; use target=app.")
            }
            var orientation = InterfaceOrientation.unknown
            if case .screenInfo(let info)? = try? await send(.screenInfo, to: app) {
                orientation = info.orientation
                scale = info.scale
            }
            if let display = try await inspector.captureDisplay(of: app) {
                // Captured as it is shown: nothing to turn upright.
                png = display
            } else {
                let raw = try await captureSimulator(udid)
                png = (try? SimulatorScreenshot.upright(png: raw, orientation: orientation).png) ?? raw
            }
            subject = "the whole display of \(app.simulatorName ?? udid), system UI included"
        default:
            throw ToolError("target must be app, view or simulator.")
        }

        guard let fitted = MCPImage.fit(png: png, maxDimension: maxDimension) else {
            throw ToolError("The capture could not be decoded.")
        }
        var caption = "Screenshot of \(subject): \(fitted.width)×\(fitted.height) px"
        if fitted.width != fitted.originalWidth {
            caption += " (scaled down from \(fitted.originalWidth)×\(fitted.originalHeight))"
        }
        if let scale, scale > 0 {
            let pixelsPerPoint = scale * Double(fitted.width) / Double(fitted.originalWidth)
            caption += ". 1 \(app.platform == .android ? "dp" : "pt") = \(String(format: "%.2f", pixelsPerPoint)) px in this image"
            if target == "view" {
                caption += ", with the view's top-left corner at 0,0"
            } else {
                caption += ", so a frame from get_screen maps to pixels by multiplying by that"
            }
        }
        return MCPToolResult(content: [
            .text(caption + "."),
            .image(base64: fitted.png.base64EncodedString(), mimeType: "image/png"),
        ])
    }

    // MARK: - App state

    private func getAppState(_ arguments: Arguments) async throws -> MCPToolResult {
        let app = try await targetApp(arguments)
        var lines = [Self.describe(app)]

        if case .screenInfo(let info)? = try? await send(.screenInfo, to: app) {
            lines.append("Orientation: \(info.orientation.rawValue), display scale @\(ScreenDescriptionFormatter.number(info.scale))x")
        }
        if case .navigationState(let navigation)? = try? await send(.navigationState, to: app) {
            lines.append(Self.describe(navigation, platform: app.platform))
        }
        if case .localization(let localization)? = try? await send(.localizationState, to: app) {
            lines.append(Self.describe(localization, platform: app.platform))
        }
        return .text(lines.joined(separator: "\n"))
    }

    private static func describe(_ navigation: NavigationState, platform: MCPPlatform = .iOS) -> String {
        var parts: [String] = []
        if let top = navigation.topViewController {
            parts.append((platform == .android ? "Top screen: " : "Top view controller: ")
                + ScreenDescriptionFormatter.shortClassName(top))
        }
        if let depth = navigation.navigationStackDepth {
            parts.append(platform == .android ? "back stack depth \(depth)" : "navigation stack depth \(depth)")
        }
        if navigation.isTransitioning { parts.append("a transition is in progress") }
        let actions = NavigationAction.allCases.map { action -> String in
            let name = Self.toolName(of: action)
            if navigation.isAvailable(action) { return "\(name): available" }
            let reason = navigation.unavailableReasons[action.rawValue]
            return "\(name): not available" + (reason.map { " (\($0))" } ?? "")
        }
        return parts.joined(separator: "; ") + (parts.isEmpty ? "" : "\n") + "navigate — " + actions.joined(separator: "; ")
    }

    private static func toolName(of action: NavigationAction) -> String {
        switch action {
        case .dismiss: return "dismiss"
        case .pop: return "pop"
        case .popToRoot: return "pop_to_root"
        }
    }

    private static func describe(_ localization: LocalizationState, platform: MCPPlatform = .iOS) -> String {
        let languages = localization.available.map { language -> String in
            var entry = "\(language.code) (\(language.displayName)"
            if language.isRightToLeft { entry += ", right-to-left" }
            if language.code == localization.developmentLanguage { entry += ", development language" }
            return entry + ")"
        }
        var lines = ["Languages in the app: " + (languages.isEmpty
            ? (platform == .android ? "none besides its default resources" : "none found")
            : languages.joined(separator: ", "))]
        var current = "Language: " + (localization.activeOverride.map { "\($0) (set through Voly)" }
            ?? "the system's (\(localization.systemLanguage ?? "unknown"))")
        current += "; layout is \(localization.isLayoutRightToLeft ? "right-to-left" : "left-to-right")"
        lines.append(current)
        if let refresh = localization.lastRefresh {
            var summary = "Last language switch: \(refresh.updated) texts updated in place"
            if refresh.unresolved > 0 { summary += ", \(refresh.unresolved) could not be (formatted, hard-coded or user-entered text)" }
            if refresh.ambiguous > 0 { summary += ", \(refresh.ambiguous) ambiguous" }
            lines.append(summary + ".")
            lines += refresh.notes.map { "  \($0)" }
        }
        return lines.joined(separator: "\n")
    }

    private func getUserDefaults(_ arguments: Arguments) async throws -> MCPToolResult {
        let app = try await targetApp(arguments)
        guard case .userDefaults(var items) = try await send(.userDefaultsList(suite: arguments.string("suite")), to: app) else {
            throw ToolError("\(app.name) gave an unexpected answer.")
        }
        let total = items.count
        if let needle = arguments.string("contains")?.lowercased() {
            items = items.filter { $0.key.lowercased().contains(needle) }
        }
        let limit = min(max(arguments.int("limit") ?? 100, 1), 1000)
        guard !items.isEmpty else {
            return .text(total == 0
                ? (app.platform == .android ? "No SharedPreferences values." : "No user defaults.")
                : "None of the \(total) keys match.")
        }
        var lines = ["\(items.count) of \(total) keys" + (items.count > limit ? ", first \(limit)" : "") + ":"]
        // Android lists every SharedPreferences file when no suite is named;
        // say which file a key is in then.
        let severalSuites = Set(items.map(\.suite)).count > 1
        if severalSuites {
            lines[0] = "\(items.count) of \(total) keys, as file/key (pass suite=<file> to read or write one file)"
                + (items.count > limit ? ", first \(limit)" : "") + ":"
        }
        lines += items.sorted { ($0.suite, $0.key) < ($1.suite, $1.key) }.prefix(limit).map {
            "\(severalSuites ? $0.suite + "/" : "")\($0.key) (\($0.type.rawValue)) = \(Self.describe($0.value))"
        }
        return .text(lines.joined(separator: "\n"))
    }

    // MARK: - Changing the app

    private static let liveChangeNote = "This changed the running app only — nothing was written to source."

    private func setProperty(_ arguments: Arguments) async throws -> MCPToolResult {
        let app = try await targetApp(arguments)
        guard let id = try arguments.viewID("view") else { throw ToolError("view is required: the #id of a view.") }
        guard let property = arguments.string("property") else { throw ToolError("property is required.") }
        guard let value = arguments.raw["value"] else { throw ToolError("value is required.") }
        guard case .properties(let bag) = try await send(.getProperties(objectID: id), to: app) else {
            throw ToolError("\(app.name) gave an unexpected answer.")
        }

        let scope: SetPropertyRequest.Scope
        let converted: PropValue
        let wanted = arguments.string("scope")
        if wanted != "layer", wanted != "custom", let current = bag.view[property] {
            scope = .view
            converted = try Self.convert(value, like: current, declared: nil, property: property)
        } else if wanted != "custom", wanted != "view", let current = bag.layer[property] {
            scope = .layer
            converted = try Self.convert(value, like: current, declared: nil, property: property)
        } else if wanted != "layer", wanted != "view", let descriptor = bag.custom.first(where: { $0.name == property }) {
            guard !descriptor.isReadOnly else { throw ToolError("\(property) is read-only.") }
            scope = .custom
            converted = try Self.convert(value, like: descriptor.currentValue, declared: descriptor.declaredType, property: property)
        } else {
            let names = (bag.view.keys.sorted() + bag.layer.keys.sorted()
                + bag.custom.filter { !$0.isReadOnly }.map(\.name)).joined(separator: ", ")
            throw ToolError("This view has no settable property \"\(property)\". It has: \(names)")
        }

        let request = SetPropertyRequest(objectID: id, scope: scope, change: PropertyChange(property: property, value: converted))
        _ = try await send(.setProperty(request), to: app)
        await inspector.appDidChange(app.id)
        return .text("Set \(property) = \(Self.describe(converted)) on view #\(id). \(Self.liveChangeNote)")
    }

    /// Shape a JSON value like the property's current value, so `"#FF0000"`
    /// becomes a color for a color property and stays a string for a string.
    static func convert(
        _ json: JSONValue,
        like current: PropValue,
        declared: CustomPropDescriptor.DeclaredType?,
        property: String
    ) throws -> PropValue {
        func mismatch(_ expected: String) -> ToolError {
            ToolError("\(property) takes \(expected).")
        }
        enum Kind { case bool, int, double, string, color, rect, size, point, url, unknown }
        let kind: Kind
        switch (current, declared) {
        case (.bool, _), (_, .bool?): kind = .bool
        case (.int, _), (_, .int?), (_, .enumCase?): kind = .int
        case (.double, _), (_, .double?): kind = .double
        case (.string, _), (_, .string?): kind = .string
        case (.color, _), (_, .color?): kind = .color
        case (.rect, _), (_, .cgRect?): kind = .rect
        case (.size, _), (_, .cgSize?): kind = .size
        case (.point, _), (_, .cgPoint?): kind = .point
        case (.url, _), (_, .url?): kind = .url
        default: kind = .unknown
        }

        func numbers(_ keys: [String]) -> [Double]? {
            if let array = json.arrayValue, array.count == keys.count {
                let values = array.compactMap(\.doubleValue)
                return values.count == keys.count ? values : nil
            }
            let values = keys.compactMap { json[$0]?.doubleValue }
            return values.count == keys.count ? values : nil
        }

        switch kind {
        case .bool:
            if let value = json.boolValue { return .bool(value) }
            if let value = json.intValue, value == 0 || value == 1 { return .bool(value == 1) }
            throw mismatch("true or false")
        case .int:
            guard let value = json.intValue else { throw mismatch("a whole number") }
            return .int(value)
        case .double:
            guard let value = json.doubleValue else { throw mismatch("a number") }
            return .double(value)
        case .string:
            guard let value = json.stringValue else { throw mismatch("a string") }
            return .string(value)
        case .color:
            if json.isNull { return .null }
            guard let color = json.stringValue.flatMap(Self.color(hex:)) else {
                throw mismatch("a color like \"#FF3B30\" or \"#FF3B3080\" (or null to clear it)")
            }
            return .color(color)
        case .rect:
            guard let v = numbers(["x", "y", "width", "height"]) else {
                throw mismatch("{\"x\":…,\"y\":…,\"width\":…,\"height\":…}")
            }
            return .rect(CGRectCodable(x: v[0], y: v[1], width: v[2], height: v[3]))
        case .size:
            guard let v = numbers(["width", "height"]) else { throw mismatch("{\"width\":…,\"height\":…}") }
            return .size(CGSizeCodable(width: v[0], height: v[1]))
        case .point:
            guard let v = numbers(["x", "y"]) else { throw mismatch("{\"x\":…,\"y\":…}") }
            return .point(CGPointCodable(x: v[0], y: v[1]))
        case .url:
            guard let url = json.stringValue.flatMap(URL.init(string:)) else { throw mismatch("a URL string") }
            return .url(url)
        case .unknown:
            // Nothing to go by but the value itself.
            switch json {
            case .null: return .null
            case .bool(let value): return .bool(value)
            case .int(let value): return .int(value)
            case .double(let value): return .double(value)
            case .string(let value): return Self.color(hex: value).map(PropValue.color) ?? .string(value)
            default: throw mismatch("a simple value")
            }
        }
    }

    /// `#RGB`, `#RGBA`, `#RRGGBB` or `#RRGGBBAA`.
    static func color(hex: String) -> CGColorCodable? {
        guard hex.hasPrefix("#") else { return nil }
        var digits = String(hex.dropFirst())
        if digits.count == 3 || digits.count == 4 { digits = digits.map { "\($0)\($0)" }.joined() }
        if digits.count == 6 { digits += "FF" }
        guard digits.count == 8, let value = UInt32(digits, radix: 16) else { return nil }
        return CGColorCodable(
            red: Double((value >> 24) & 0xFF) / 255,
            green: Double((value >> 16) & 0xFF) / 255,
            blue: Double((value >> 8) & 0xFF) / 255,
            alpha: Double(value & 0xFF) / 255
        )
    }

    private func setConstraint(_ arguments: Arguments) async throws -> MCPToolResult {
        let app = try await targetApp(arguments)
        guard let viewID = try arguments.viewID("view"), let constraintID = try arguments.viewID("constraint") else {
            throw ToolError("view and constraint are required: the view's #id and the constraint's #id from get_view.")
        }
        let change = ConstraintChange(
            constant: arguments.double("constant"),
            priority: arguments.double("priority").map(Float.init),
            isActive: arguments.bool("active")
        )
        guard change.constant != nil || change.priority != nil || change.isActive != nil else {
            throw ToolError("Give at least one of constant, priority, active.")
        }
        let request = SetConstraintRequest(constraintID: constraintID, anchorObjectID: viewID, change: change)
        _ = try await send(.setConstraint(request), to: app)
        await inspector.appDidChange(app.id)

        var result = "Changed constraint #\(constraintID). \(Self.liveChangeNote)"
        if case .screenDescription(let screen)? = try? await send(
            .describeScreen(ScreenDescriptionRequest(rootID: viewID, maxDepth: 0)), to: app
        ), let node = screen.roots.first {
            result += "\nThe view is now: " + formatter.line(for: node)
        }
        return .text(result)
    }

    private func navigate(_ arguments: Arguments) async throws -> MCPToolResult {
        let app = try await targetApp(arguments)
        let action: NavigationAction
        switch arguments.string("action") {
        case "pop": action = .pop
        case "pop_to_root": action = .popToRoot
        case "dismiss": action = .dismiss
        default: throw ToolError("action must be pop, pop_to_root or dismiss.")
        }
        guard case .navigationResult(let result) = try await send(.navigate(action), to: app) else {
            throw ToolError("\(app.name) gave an unexpected answer.")
        }
        guard result.performed else {
            return .error("Not done: " + (result.message ?? "that isn't possible on this screen."))
        }
        // The transition animates; report where it lands.
        try? await Task.sleep(for: .milliseconds(700))
        await inspector.appDidChange(app.id)
        var text = "Done."
        if case .navigationState(let state)? = try? await send(.navigationState, to: app),
           let top = state.topViewController {
            text += " Now showing \(ScreenDescriptionFormatter.shortClassName(top))."
        }
        return .text(text)
    }

    private func setLanguage(_ arguments: Arguments) async throws -> MCPToolResult {
        let app = try await targetApp(arguments)
        var language = arguments.string("language")
        if language == "system" || language == "" { language = nil }
        let direction: LayoutDirectionMode
        switch arguments.string("layout_direction") {
        case nil: direction = language == nil ? .system : .followLanguage
        case "system": direction = .system
        case "follow_language": direction = .followLanguage
        case "left_to_right": direction = .leftToRight
        case "right_to_left": direction = .rightToLeft
        default: throw ToolError("layout_direction must be system, follow_language, left_to_right or right_to_left.")
        }
        let request = LocalizationOverrideRequest(language: language, layoutDirectionMode: direction, refreshUI: true)
        guard case .localization(let state) = try await send(.setLocalizationOverride(request), to: app) else {
            throw ToolError("\(app.name) gave an unexpected answer.")
        }
        await inspector.appDidChange(app.id)
        if app.platform == .android {
            return .text(Self.describe(state, platform: .android) + """

                The app's activities were recreated in this language, so view ids from before no longer \
                apply — call get_screen again. On Android 13 and later the choice is the system's per-app \
                language and stays until set back with language="system".
                """)
        }
        return .text(Self.describe(state) + """

            Screens opened from now on load in this language. Text that was already on screen is \
            swapped where it could be matched to a localized string.
            """)
    }

    private func openURL(_ arguments: Arguments) async throws -> MCPToolResult {
        let app = try await targetApp(arguments)
        guard let url = arguments.string("url").flatMap(URL.init(string:)), url.scheme != nil else {
            throw ToolError("url must be a full URL, e.g. myapp://settings.")
        }
        guard case .urlResult(let success, let error) = try await send(.openURL(url: url), to: app) else {
            throw ToolError("\(app.name) gave an unexpected answer.")
        }
        guard success else { return .error("The app did not open \(url.absoluteString)" + (error.map { ": \($0)" } ?? ".")) }
        await inspector.appDidChange(app.id)
        return .text("Opened \(url.absoluteString) in \(app.name).")
    }

    private func setUserDefault(_ arguments: Arguments) async throws -> MCPToolResult {
        let app = try await targetApp(arguments)
        guard let key = arguments.string("key"), !key.isEmpty else { throw ToolError("key is required.") }
        let suite = arguments.string("suite")
        guard let value = arguments.raw["value"], !value.isNull else {
            _ = try await send(.userDefaultsDelete(suite: suite, key: key), to: app)
            return .text("Removed \(key) from \(app.name)'s \(Self.defaultsName(app)).")
        }
        let converted: PropValue
        switch value {
        case .bool(let value): converted = .bool(value)
        case .int(let value): converted = .int(value)
        case .double(let value): converted = .double(value)
        case .string(let value): converted = .string(value)
        default: throw ToolError("value must be a string, number or boolean (or null to remove the key).")
        }
        _ = try await send(.userDefaultsSet(UserDefaultsSetRequest(suite: suite, key: key, value: converted)), to: app)
        return .text("Set \(key) = \(Self.describe(converted)) in \(app.name)'s \(Self.defaultsName(app)).")
    }

    private static func defaultsName(_ app: MCPApp) -> String {
        app.platform == .android ? "SharedPreferences" : "user defaults"
    }

    private func relaunchApp(_ arguments: Arguments) async throws -> MCPToolResult {
        guard let bundle = arguments.string("bundle_id"), !bundle.isEmpty else { throw ToolError("bundle_id is required.") }
        let overview = await inspector.overview()
        guard !overview.simulators.isEmpty else { throw ToolError("No simulator is booted.") }

        let simulator: MCPSimulator
        if let wanted = arguments.string("simulator") {
            guard let match = overview.simulators.first(where: {
                $0.udid.caseInsensitiveCompare(wanted) == .orderedSame || $0.name.caseInsensitiveCompare(wanted) == .orderedSame
            }) else {
                throw ToolError("No booted simulator matches \"\(wanted)\". Booted: "
                    + overview.simulators.map { "\($0.name) (\($0.udid))" }.joined(separator: ", "))
            }
            simulator = match
        } else if let running = overview.apps.first(where: { $0.bundleIdentifier == bundle })?.simulatorUDID
                    .flatMap({ udid in overview.simulators.first { $0.udid == udid } })
                    ?? overview.simulators.first(where: { $0.appsWithoutAgent.contains(bundle) }) {
            simulator = running
        } else if overview.simulators.count == 1 {
            simulator = overview.simulators[0]
        } else {
            throw ToolError("Say which simulator with simulator=<name or udid>. Booted: "
                + overview.simulators.map { "\($0.name) (\($0.udid))" }.joined(separator: ", "))
        }

        func instances(in apps: [MCPApp]) -> [MCPApp] {
            apps.filter { $0.bundleIdentifier == bundle && $0.simulatorUDID == simulator.udid }
        }
        // The process being replaced can stay listed for a moment; only a
        // new one counts as back.
        let replaced = Set(instances(in: overview.apps).map(\.id))
        try await inspector.relaunch(bundleIdentifier: bundle, simulatorUDID: simulator.udid)
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(500))
            let apps = await inspector.overview().apps
            if let app = instances(in: apps).first(where: { !replaced.contains($0.id) }) {
                return .text("Relaunched. Now inspectable: \(Self.describe(app))")
            }
        }
        return .error("""
            \(bundle) was relaunched in \(simulator.name), but its Voly agent hasn't shown up after 20 s. \
            list_apps shows the current state.
            """)
    }
}

// MARK: - Support

struct ToolError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Tool arguments, read leniently: a number sent as a string still counts.
struct Arguments {
    let raw: [String: JSONValue]

    init(_ value: JSONValue) {
        raw = value.objectValue ?? [:]
    }

    func string(_ key: String) -> String? {
        switch raw[key] {
        case .string(let value)?: return value
        case .int(let value)?: return String(value)
        default: return nil
        }
    }

    func int(_ key: String) -> Int? {
        if let value = raw[key]?.intValue { return Int(value) }
        return raw[key]?.stringValue.flatMap(Int.init)
    }

    func double(_ key: String) -> Double? {
        raw[key]?.doubleValue ?? raw[key]?.stringValue.flatMap(Double.init)
    }

    func bool(_ key: String) -> Bool? {
        if let value = raw[key]?.boolValue { return value }
        switch raw[key]?.stringValue?.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// A view or constraint id: `13`, `"13"` or `"#13"`.
    func viewID(_ key: String) throws -> ObjectID? {
        guard let value = raw[key], !value.isNull else { return nil }
        if let number = value.intValue, number > 0 { return ObjectID(number) }
        if let text = value.stringValue,
           let number = ObjectID(text.hasPrefix("#") ? String(text.dropFirst()) : text) {
            return number
        }
        throw ToolError("\(key) must be an id number as shown after # (e.g. 13).")
    }
}

/// What has been learned about each app's agent, by app id. An id belongs
/// to one process, so an entry never goes stale: a relaunched app is a new
/// id.
private final class ScreenSupport: @unchecked Sendable {
    private let lock = NSLock()
    private var known: [String: Bool] = [:]

    subscript(appID: String) -> Bool? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return known[appID]
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            known[appID] = newValue
        }
    }
}

/// Lets exactly one of several racing tasks finish a continuation.
private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
