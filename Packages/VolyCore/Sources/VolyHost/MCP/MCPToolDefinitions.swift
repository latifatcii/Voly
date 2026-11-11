import Foundation

extension MCPToolbox {
    /// Told to the agent once, when it connects.
    public static let instructions = """
        Voly inspects iOS apps running in the iOS Simulator from the inside. Use it instead of guessing \
        from screenshots: it gives the live view tree with exact frames (in points), text, fonts, colors, \
        Auto Layout constraints, the owning view controllers and the source file behind a view.

        Typical flow: get_screen for the whole current screen → get_view with a #id for one view's \
        constraints, properties and source → screenshot to see pixels. find_views locates a view by text, \
        class, accessibility identifier or point. get_selection reads the view the user picked in Voly.

        View ids (#13) belong to one running app and stay valid while that view lives; after navigation or \
        a relaunch, call get_screen again. Frames are in window points, origin top-left. SwiftUI content \
        shows up as accessibility elements (lines starting with ~) under its hosting view, without font or \
        color. set_property, set_constraint, navigate and set_language change the running app only — use \
        them to try a fix live, then make the real change in source.

        Android apps (debug builds in an emulator, or on a device adb can reach) work through the same \
        tools; list_apps marks them android=. What differs: frames are in dp from the display's top-left \
        corner; a view's id= is its android:id; vc= names the activity or fragment a view is the root of; \
        Jetpack Compose content appears as ~ lines (semantics nodes: text, role, state, test tag), each \
        with a #id that get_view, select_view and screenshot take like a view's; it is read-only, and \
        get_screen with root set to such an id lists the layout nodes inside (Row, Box, Spacer and all); layout \
        params are reported as constraints (fixed sizes, margins, ConstraintLayout connections) and \
        get_view lists padding, margins, layout_width/height, text and the like as class-specific \
        properties; user defaults are SharedPreferences (suite = the preferences file); navigate's dismiss \
        closes a dialog, bottom sheet or popup and pop goes back like the Back button; source is found by \
        class name in the project (Kotlin or Java) and by android:id in layout XML.
        """

    static let definitions: [MCPTool] = [
        MCPTool(
            name: "list_apps",
            title: "List simulators and inspectable apps",
            description: """
                Booted simulators and the apps Voly can inspect in them right now. Start here when a tool \
                says no app is available, or to choose between several apps.
                """,
            inputSchema: schema([])
        ),
        MCPTool(
            name: "get_screen",
            title: "Read the current screen",
            description: """
                The app's live view hierarchy as an indented text tree: every view's class, #id, frame in \
                window points, text, font, colors, corner radius, stack/scroll settings, accessibility \
                identifier, owning view controller, control state, and ⚠ flags for likely layout bugs \
                (truncated text, ambiguous layout, zero size, outside the window). Use this to understand \
                or debug what is on screen instead of reading it off a screenshot.
                """,
            inputSchema: schema([
                ("root", integer("Only describe the subtree under this view #id. Use it to open a part that was cut for size.")),
                ("max_depth", integer("Levels below the root(s) to include. Default: all that fit.")),
                ("include_hidden", boolean("Also list hidden and fully transparent views. Default false.")),
                ("collapse_wrappers", boolean("Fold chains of same-sized wrapper views onto one line. Default true.")),
                app,
            ])
        ),
        MCPTool(
            name: "get_view",
            title: "Inspect one view",
            description: """
                Everything about one view: its line from get_screen, where it sits (superview chain and \
                view controller), layout inputs (intrinsic size, hugging and compression-resistance \
                priorities, safe area, margins), every Auto Layout constraint that involves it, all readable \
                properties, its direct subviews, and the source file and line of its class or owning view \
                controller.
                """,
            inputSchema: schema([
                ("view", integer("The view's #id from get_screen or find_views.")),
                ("source", boolean("Look up source file and line (takes a second or two). Default true.")),
                app,
            ], required: ["view"])
        ),
        MCPTool(
            name: "find_views",
            title: "Find views",
            description: """
                Search the current screen. Filters combine (all must match): text (substring of a view's \
                text, placeholder, value or accessibility label — also finds SwiftUI content), class_name \
                (substring), accessibility_id (substring), x and y (views containing that point, innermost \
                first), problems_only (views flagged ⚠).
                """,
            inputSchema: schema([
                ("text", string("Case-insensitive substring of visible text or accessibility label.")),
                ("class_name", string("Case-insensitive substring of the class name, e.g. Button.")),
                ("accessibility_id", string("Case-insensitive substring of the accessibility identifier.")),
                ("x", number("Window x in points; give together with y.")),
                ("y", number("Window y in points; give together with x.")),
                ("problems_only", boolean("Only views with a ⚠ flag.")),
                ("include_hidden", boolean("Also search hidden views. Default false.")),
                ("limit", integer("Most matches to return. Default 30.")),
                app,
            ])
        ),
        MCPTool(
            name: "get_selection",
            title: "Read the view selected in Voly",
            description: """
                The view the user has selected in Voly (by clicking it in the simulator in pick mode, or in \
                Voly's tree), with the same detail as get_view. Use it when the user says "this view" or \
                "the one I selected".
                """,
            inputSchema: schema([
                ("source", boolean("Look up source file and line. Default true.")),
            ])
        ),
        MCPTool(
            name: "select_view",
            title: "Select a view in Voly",
            description: """
                Select a view in Voly's window and highlight it in the simulator, so the user can see which \
                view you mean. Changes nothing in the app.
                """,
            inputSchema: schema([
                ("view", integer("The view's #id.")),
                app,
            ], required: ["view"])
        ),
        MCPTool(
            name: "screenshot",
            title: "Take a screenshot",
            description: """
                A PNG of the app (target=app, the default: the app's own windows, without Voly's \
                highlight), of one view (target=view with view=<#id>), or of the whole simulator display \
                including system UI such as alerts and the keyboard (target=simulator). The caption gives \
                the points-to-pixels factor for matching frames from get_screen.
                """,
            inputSchema: schema([
                ("target", string("app, view or simulator (the whole display; also for an Android emulator). Default app, or view when view is given.", options: ["app", "view", "simulator"])),
                ("view", integer("The view's #id, for target=view.")),
                ("max_dimension", integer("Longest side of the returned image in pixels; larger captures are scaled down. Default 1568.")),
                app,
            ])
        ),
        MCPTool(
            name: "get_app_state",
            title: "Read app state",
            description: """
                Orientation, the top view controller and navigation stack, which navigate actions are \
                possible, the languages the app ships and the one in use.
                """,
            inputSchema: schema([app])
        ),
        MCPTool(
            name: "get_user_defaults",
            title: "Read user defaults",
            description: "The app's UserDefaults keys and values. For an Android app: its SharedPreferences, every file unless suite names one.",
            inputSchema: schema([
                ("contains", string("Only keys containing this text (case-insensitive).")),
                ("suite", string("A suite name; default is the app's standard defaults.")),
                ("limit", integer("Most keys to return. Default 100.")),
                app,
            ])
        ),
        MCPTool(
            name: "set_property",
            title: "Change a view property (live)",
            description: """
                Set a property on a view in the running app to try a change without rebuilding: alpha, \
                isHidden, backgroundColor, tintColor, clipsToBounds, cornerRadius, borderWidth, \
                borderColor, shadow settings, and the class-specific properties get_view lists (text, \
                numberOfLines, …). Colors are "#RRGGBB" or "#RRGGBBAA". Not saved to source.
                """,
            inputSchema: schema([
                ("view", integer("The view's #id.")),
                ("property", string("Property name exactly as get_view shows it.")),
                ("value", ["description": "New value: boolean, number, string, a color string, or an object for rect/size/point."]),
                ("scope", string("Only needed when a name exists in more than one group.", options: ["view", "layer", "custom"])),
                app,
            ], required: ["view", "property", "value"]),
            changesApp: true
        ),
        MCPTool(
            name: "set_constraint",
            title: "Change a constraint (live)",
            description: """
                Change an Auto Layout constraint's constant or priority, or activate/deactivate it, in the \
                running app, and report the view's resulting frame. Constraint ids come from get_view. Not \
                saved to source.
                """,
            inputSchema: schema([
                ("view", integer("#id of the view whose constraint list (from get_view) contains the constraint.")),
                ("constraint", integer("The constraint's #id.")),
                ("constant", number("New constant, in points.")),
                ("priority", number("New priority, 1–1000.")),
                ("active", boolean("Activate or deactivate it.")),
                app,
            ], required: ["view", "constraint"]),
            changesApp: true
        ),
        MCPTool(
            name: "navigate",
            title: "Go back or dismiss",
            description: """
                Leave the current screen: pop the top view controller, pop to the navigation root, or \
                dismiss what is presented. get_app_state says which are possible.
                """,
            inputSchema: schema([
                ("action", string("What to do.", options: ["pop", "pop_to_root", "dismiss"])),
                app,
            ], required: ["action"]),
            changesApp: true
        ),
        MCPTool(
            name: "set_language",
            title: "Switch the app's language (live)",
            description: """
                Make the running app load its strings in another of its languages, without relaunching, to \
                check translations, text that no longer fits and right-to-left layout. language="system" \
                goes back to normal. get_app_state lists the languages the app has.
                """,
            inputSchema: schema([
                ("language", string("A language code the app ships, e.g. fr, ar, pt-BR — or system.")),
                ("layout_direction", string(
                    "Layout direction. Default follows the language.",
                    options: ["follow_language", "system", "left_to_right", "right_to_left"]
                )),
                app,
            ], required: ["language"]),
            changesApp: true
        ),
        MCPTool(
            name: "open_url",
            title: "Open a URL in the app",
            description: "Ask the app to open a URL — a deep link or universal link — as if it had been tapped.",
            inputSchema: schema([
                ("url", string("The full URL, e.g. myapp://settings/profile.")),
                app,
            ], required: ["url"]),
            changesApp: true
        ),
        MCPTool(
            name: "set_user_default",
            title: "Write a user default",
            description: "Set a key in the app's UserDefaults to a string, number or boolean, or remove it with value=null.",
            inputSchema: schema([
                ("key", string("The key.")),
                ("value", ["description": "String, number or boolean; null removes the key."]),
                ("suite", string("A suite name; default is the app's standard defaults.")),
                app,
            ], required: ["key", "value"]),
            changesApp: true
        ),
        MCPTool(
            name: "relaunch_app",
            title: "Relaunch an app so Voly can inspect it",
            description: """
                Terminate an app and start it again with Voly's agent loaded. Only needed for an app that \
                was already running when Voly started (list_apps says so); apps launched afterwards are \
                inspectable without this. The app loses its in-memory state and any attached debugger. \
                Android apps never need it to become inspectable; there it simply restarts the app.
                """,
            inputSchema: schema([
                ("bundle_id", string("The app's bundle identifier (Android: its package name).")),
                ("simulator", string("Simulator name or UDID (or Android emulator name or adb serial), when more than one is running.")),
            ], required: ["bundle_id"]),
            changesApp: true
        ),
    ]

    // MARK: - Schema helpers

    private static let app: (String, JSONValue) = (
        "app",
        string("Bundle identifier, name or pid of the app, when several are inspectable. Default: the app shown in Voly.")
    )

    private static func schema(_ properties: [(String, JSONValue)], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": "object",
            "properties": .object(Dictionary(properties, uniquingKeysWith: { _, last in last })),
        ]
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        return .object(schema)
    }

    private static func string(_ description: String, options: [String]? = nil) -> JSONValue {
        var property: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if let options { property["enum"] = .array(options.map(JSONValue.string)) }
        return .object(property)
    }

    private static func integer(_ description: String) -> JSONValue {
        ["type": "integer", "description": .string(description)]
    }

    private static func number(_ description: String) -> JSONValue {
        ["type": "number", "description": .string(description)]
    }

    private static func boolean(_ description: String) -> JSONValue {
        ["type": "boolean", "description": .string(description)]
    }
}
