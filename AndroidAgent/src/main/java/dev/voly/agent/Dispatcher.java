package dev.voly.agent;

import android.app.Activity;
import android.app.Application;
import android.content.Intent;
import android.content.pm.ResolveInfo;
import android.graphics.RectF;
import android.net.Uri;
import android.os.Process;
import android.view.View;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/**
 * Answers the host's commands. One `Command` in, one `Response` out, both
 * in the JSON Swift's `Codable` gives the enums in VolyProtocol — the same
 * protocol the iOS agent speaks, so the host can't tell the two apart
 * except by what the handshake says.
 *
 * Everything here runs on the main thread.
 */
final class Dispatcher {
    static final int PROTOCOL_VERSION = 1;
    static final String AGENT_VERSION = "0.1.0";

    interface Reply {
        void send(JSONObject response);
    }

    interface EventSink {
        void send(JSONObject event);
    }

    private final ObjectRegistry registry = new ObjectRegistry();
    private final Snapshots snapshots = new Snapshots(registry);
    private final Properties properties = new Properties(registry);
    private final LayoutConstraints constraints = new LayoutConstraints(registry);
    private final Overlay overlay = new Overlay();
    private final Screenshots screenshots = new Screenshots(overlay);
    private Localization localization;

    Dispatcher(EventSink events) {
        overlay.setPickListener(target -> {
            // Pick mode stays on, so the next tap can select another view.
            overlay.highlight(target);
            events.send(Json.enumCase("selectionChanged", registry.idFor(target.key())));
        });
    }

    /** Leave the app as it was found: no pick mode, nothing drawn. */
    void reset() {
        overlay.exitPickMode();
        overlay.clear();
        screenshots.cancelWaiting();
    }

    private Localization localization() throws AgentError {
        if (localization == null) {
            Application app = Ui.application();
            if (app == null) throw AgentError.unavailable("The app has no Application object yet.");
            localization = new Localization(app);
        }
        return localization;
    }

    /** The view or Compose node an id stands for. */
    private Target target(long id) throws AgentError {
        Target target = Target.of(registry.objectFor(id));
        if (target == null) throw AgentError.objectGone(id);
        return target;
    }

    /** `{"error":{"_0":…}}` */
    static JSONObject errorResponse(AgentError error) {
        try {
            return Json.enumCase("error", error.toJson());
        } catch (org.json.JSONException e) {
            return Json.enumCase("error", Json.enumCase("internal", String.valueOf(e)));
        }
    }

    void handle(JSONObject command, Reply reply) {
        try {
            String name = Json.caseName(command);
            JSONObject arguments = command.optJSONObject(name);
            if (arguments == null) arguments = new JSONObject();
            JSONObject response = handle(name, arguments, reply);
            if (response != null) reply.send(response);
        } catch (AgentError error) {
            reply.send(errorResponse(error));
        } catch (Throwable error) {
            Log.e("command failed", error);
            reply.send(errorResponse(AgentError.internal(String.valueOf(error))));
        }
    }

    /** Returns the response, or null when `reply` will be called later. */
    private JSONObject handle(String name, JSONObject arguments, Reply reply) throws AgentError {
        switch (name) {
            case "handshake":
                return Json.enumCase("handshakeAccepted", handshake());
            case "ping":
                return Json.enumCase("pong");

            // The view tree
            case "getHierarchy":
                return Json.enumCase("hierarchy", snapshots.hierarchy(64));
            case "getSubtree":
                return Json.enumCase("subtree", snapshots.subtree(arguments.optLong("objectID"), arguments.optInt("maxDepth", 1)));
            case "describeScreen": {
                JSONObject request = arguments.optJSONObject("_0");
                if (request == null) request = new JSONObject();
                return Json.enumCase("screenDescription",
                    new ScreenDescriber(registry).describe(request, Navigation.topScreenName()));
            }

            // Properties and layout
            case "getProperties":
                return Json.enumCase("properties", properties.bag(arguments.optLong("objectID")));
            case "setProperty": {
                JSONObject request = required(arguments);
                final long id = request.optLong("objectID");
                if (registry.objectFor(id) instanceof ComposeNode) throw ComposeProperties.notEditable();
                properties.apply(request);
                afterLayout(reply, () -> Json.enumCase("subtree", snapshots.subtree(id, 1)));
                return null;
            }
            case "getConstraints":
                return Json.enumCase("constraints", constraints.constraints(arguments.optLong("objectID")));
            case "setConstraint": {
                final View refreshed = constraints.apply(required(arguments));
                afterLayout(reply, () -> Json.enumCase("subtree", snapshots.node(refreshed, 1, Fragments.viewOwners())));
                return null;
            }

            // Selection, highlight, measurement
            case "enterPickMode":
                overlay.enterPickMode();
                return Json.enumCase("pickModeChanged", true);
            case "exitPickMode":
                overlay.exitPickMode();
                return Json.enumCase("pickModeChanged", false);
            case "selectAt": {
                Target found = hit(arguments);
                if (found == null) return Json.enumCase("selection", 0L);
                overlay.highlight(found);
                return Json.enumCase("selection", registry.idFor(found.key()));
            }
            case "hoverAt": {
                Target found = hit(arguments);
                return found == null
                    ? Json.enumCase("hoverResult")
                    : Json.enumCase("hoverResult", registry.idFor(found.key()));
            }
            case "measureHover":
                return measureHover(arguments);
            case "highlight":
                overlay.highlight(target(arguments.optLong("objectID")));
                return Json.enumCase("ack");
            case "clearSelection":
                overlay.clear();
                return Json.enumCase("ack");
            case "measure":
                showMeasurement(arguments.optJSONObject("overlay"));
                return Json.enumCase("ack");
            case "clearMeasure":
                overlay.clearMeasurement();
                return Json.enumCase("ack");

            // Preferences and URLs
            case "userDefaultsList":
                return Json.enumCase("userDefaults", Prefs.list(optionalString(arguments, "suite")));
            case "userDefaultsSet":
                Prefs.set(required(arguments));
                return Json.enumCase("ack");
            case "userDefaultsDelete":
                Prefs.delete(optionalString(arguments, "suite"), arguments.optString("key", ""));
                return Json.enumCase("ack");
            case "openURL":
                return openUrl(arguments.optString("url", ""));

            // Source
            case "resolveSource":
                return Json.enumCase("sourceInfo", Sources.info(target(arguments.optLong("objectID"))));

            // Language
            case "localizationState":
                return Json.enumCase("localization", localization().state());
            case "setLocalizationOverride": {
                localization().apply(required(arguments));
                replyWhenActivitiesSettle(reply, () -> Json.enumCase("localization", localization.state()));
                return null;
            }
            case "refreshLocalizedUI": {
                localization().refresh();
                replyWhenActivitiesSettle(reply, () -> Json.enumCase("localization", localization.state()));
                return null;
            }

            // Screenshots
            case "captureScreenshot": {
                JSONObject target = required(arguments);
                Screenshots.Completion completion = (image, error) ->
                    reply.send(error != null ? errorResponse(error) : Json.enumCase("screenshot", image));
                if (target.has("view")) {
                    Object id = Json.caseValue(target);
                    if (!(id instanceof Number)) throw AgentError.invalidCommand("captureScreenshot without a view id");
                    screenshots.capture(target(((Number) id).longValue()), completion);
                } else {
                    screenshots.captureApplication(completion);
                }
                return null;
            }
            case "screenInfo": {
                JSONObject info = Json.object();
                Json.put(info, "orientation", Ui.orientation());
                Json.put(info, "scale", (double) Ui.density());
                return Json.enumCase("screenInfo", info);
            }

            // Navigation
            case "navigationState":
                return Json.enumCase("navigationState", Navigation.state());
            case "navigate": {
                Object action = arguments.opt("_0");
                if (!(action instanceof String)) throw AgentError.invalidCommand("navigate without an action");
                return Json.enumCase("navigationResult", Navigation.perform((String) action));
            }

            // Resizable previews need the SDK's host view controller; there is no Android counterpart.
            case "setPreviewConfig":
                throw AgentError.internal("Preview is not available for Android apps.");
            case "clearPreview":
                return Json.enumCase("ack");

            default:
                throw AgentError.invalidCommand(name);
        }
    }

    private static JSONObject required(JSONObject arguments) throws AgentError {
        JSONObject value = arguments.optJSONObject("_0");
        if (value == null) throw AgentError.invalidCommand("missing payload");
        return value;
    }

    private static String optionalString(JSONObject arguments, String key) {
        return arguments.isNull(key) ? null : arguments.optString(key, null);
    }

    // MARK: Handshake

    /** `HandshakeAccepted` */
    private JSONObject handshake() {
        Application app = Ui.application();
        JSONObject capabilities = Json.object();
        Json.put(capabilities, "injectionMode", "injected");
        Json.put(capabilities, "previewHost", false);
        Json.put(capabilities, "localization", true);
        Json.put(capabilities, "screenshots", true);
        Json.put(capabilities, "navigation", true);
        Json.put(capabilities, "sourceSymbols", false);

        JSONObject accepted = Json.object();
        Json.put(accepted, "protocolVersion", PROTOCOL_VERSION);
        Json.put(accepted, "sessionID", UUID.randomUUID().toString().toUpperCase(java.util.Locale.US));
        Json.put(accepted, "agentName", "VolyAgent");
        Json.put(accepted, "agentVersion", AGENT_VERSION);
        Json.put(accepted, "bundleIdentifier", app != null ? app.getPackageName() : null);
        Json.put(accepted, "processName", ScreenDescriber.appName(app));
        Json.put(accepted, "pid", Process.myPid());
        Json.put(accepted, "capabilities", capabilities);
        Json.put(accepted, "platform", "android");
        return accepted;
    }

    // MARK: Hit testing and measurement

    /** The view, or the node of Compose content, under a point given in display points. */
    private static Target hit(JSONObject arguments) {
        float density = Ui.density();
        return Ui.hitTest((float) arguments.optDouble("x", -1) * density, (float) arguments.optDouble("y", -1) * density);
    }

    private JSONObject measureHover(JSONObject arguments) {
        Target anchor = Target.of(registry.objectFor(arguments.optLong("anchorID")));
        Target other = hit(arguments);
        JSONObject result = Json.object();
        if (anchor == null || other == null) {
            overlay.clearMeasurement();
            return Json.enumCaseLabeled("measureHoverResult", result);
        }
        Measure.Result measured = overlay.measureAgainst(anchor, other);
        Json.put(result, "otherID", registry.idFor(other.key()));
        if (measured != null) Json.put(result, "summary", measured.summary());
        return Json.enumCaseLabeled("measureHoverResult", result);
    }

    /** Draw a `MeasurementOverlay` the host computed from its snapshot. */
    private void showMeasurement(JSONObject description) throws AgentError {
        if (description == null) throw AgentError.invalidCommand("measure without an overlay");
        JSONObject other = description.optJSONObject("other");
        if (other == null) throw AgentError.invalidCommand("measure without the other frame");
        double x = other.optDouble("x"), y = other.optDouble("y");
        RectF rect = new RectF((float) x, (float) y, (float) (x + other.optDouble("width")), (float) (y + other.optDouble("height")));
        List<Measure.Guide> guides = new ArrayList<>();
        JSONArray encoded = description.optJSONArray("guides");
        for (int index = 0; encoded != null && index < encoded.length(); index++) {
            Measure.Guide guide = Measure.Guide.fromJson(encoded.optJSONObject(index));
            if (guide != null) guides.add(guide);
        }
        overlay.showMeasurement(rect, description.optBoolean("otherIsTransformed", false), guides);
    }

    // MARK: URLs

    private JSONObject openUrl(String url) {
        JSONObject result = Json.object();
        try {
            Uri uri = Uri.parse(url);
            if (uri.getScheme() == null) throw new IllegalArgumentException("not a full URL");
            Application app = Ui.application();
            Activity activity = Ui.topActivity();
            Intent intent = new Intent(Intent.ACTION_VIEW, uri);
            intent.addCategory(Intent.CATEGORY_BROWSABLE);
            // When the app itself handles the link, open it there rather than in a chooser.
            if (app != null) {
                Intent own = new Intent(intent).setPackage(app.getPackageName());
                List<ResolveInfo> handlers = app.getPackageManager().queryIntentActivities(own, 0);
                if (handlers != null && !handlers.isEmpty()) intent = own;
            }
            if (activity != null) {
                activity.startActivity(intent);
            } else if (app != null) {
                app.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            } else {
                throw new IllegalStateException("the app has no context yet");
            }
            Json.put(result, "success", true);
        } catch (Throwable e) {
            Json.put(result, "success", false);
            Json.put(result, "error", e instanceof android.content.ActivityNotFoundException
                ? "Nothing on the device handles this URL."
                : String.valueOf(e.getMessage() != null ? e.getMessage() : e));
        }
        return Json.enumCaseLabeled("urlResult", result);
    }

    // MARK: Waiting for recreated activities

    private interface Response {
        JSONObject make() throws AgentError;
    }

    /**
     * A change to a view takes effect in the next layout pass. Answer after
     * it, so the frame sent back is the new one.
     */
    private void afterLayout(Reply reply, Response response) {
        final boolean[] sent = {false};
        final Runnable send = () -> {
            if (sent[0]) return;
            sent[0] = true;
            try {
                reply.send(response.make());
            } catch (AgentError error) {
                reply.send(errorResponse(error));
            } catch (Throwable error) {
                reply.send(errorResponse(AgentError.internal(String.valueOf(error))));
            }
        };
        // Frame callbacks run before that frame's layout; the posted message runs after it.
        android.view.Choreographer.getInstance().postFrameCallback(time -> Ui.MAIN.post(send));
        // No frame is drawn while the app is in the background.
        Ui.MAIN.postDelayed(send, 400);
    }

    /**
     * A language change makes the system recreate the activities a moment
     * later. Answer once the new ones are on screen, so the host's next
     * read of the view tree sees them.
     */
    private void replyWhenActivitiesSettle(Reply reply, Response response) {
        final List<Activity> before = Ui.activities();
        final long deadline = android.os.SystemClock.uptimeMillis() + 2500;
        final long earliest = android.os.SystemClock.uptimeMillis() + 250;
        Ui.MAIN.postDelayed(new Runnable() {
            private boolean sawChange;

            @Override
            public void run() {
                long now = android.os.SystemClock.uptimeMillis();
                List<Activity> current = Ui.activities();
                boolean changed = current.size() != before.size();
                for (Activity activity : current) {
                    if (!before.contains(activity)) changed = true;
                }
                boolean ready = !current.isEmpty();
                for (Activity activity : current) {
                    View decor = activity.getWindow() != null ? activity.getWindow().peekDecorView() : null;
                    if (before.contains(activity) && changed) continue;
                    if (decor == null || !decor.isAttachedToWindow() || decor.getWidth() == 0) ready = false;
                }
                if (changed) sawChange = true;
                if (now >= deadline || (now >= earliest && ready && (sawChange || now >= earliest + 600))) {
                    try {
                        reply.send(response.make());
                    } catch (Throwable error) {
                        reply.send(errorResponse(AgentError.internal(String.valueOf(error))));
                    }
                    return;
                }
                Ui.MAIN.postDelayed(this, 100);
            }
        }, 150);
    }
}
