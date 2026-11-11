package dev.voly.agent;

import android.view.View;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Jetpack Compose content, read through its semantics tree — the Compose
 * counterpart of reading SwiftUI through accessibility elements. A Compose
 * screen is a single Android view (`AndroidComposeView`); what it shows only
 * exists as semantics nodes: text, role, state, test tag and bounds.
 *
 * `ComposeTree` reads the same content as nodes with ids of their own; an
 * element here carries the id of the node it is, so what a reader finds in
 * this short list can be asked about like a view.
 *
 * Compose is part of the app, not of the platform, so everything here is
 * reflection on its public API and gives nothing when it is absent.
 */
final class ComposeSemantics {
    private ComposeSemantics() {}

    private static final int MAX_ELEMENTS = 400;

    static boolean isComposeView(View view) {
        return Reflect.isInstance(view, "androidx.compose.ui.platform.AndroidComposeView");
    }

    /** `[AccessibilityElementDescription]`, or null when there is nothing to tell. */
    static JSONArray elements(View composeView, ObjectRegistry registry) {
        try {
            Object owner = Reflect.call(composeView, "getSemanticsOwner");
            Object root = Reflect.call(owner, "getRootSemanticsNode");
            if (root == null) return null;
            int[] origin = Ui.rootOrigin(composeView.getRootView());
            List<JSONObject> result = new ArrayList<>();
            collect(root, origin, result, 0, ComposeTree.content(composeView, ComposeTree.RECENT_ENOUGH_MS), registry);
            if (result.isEmpty()) return null;
            JSONArray array = new JSONArray();
            for (JSONObject element : result) array.put(element);
            return array;
        } catch (Throwable e) {
            Log.w("reading Compose semantics failed: " + e);
            return null;
        }
    }

    private static void collect(Object node, int[] origin, List<JSONObject> result, int depth,
                                ComposeTree.Content content, ObjectRegistry registry) {
        if (node == null || depth > 60 || result.size() >= MAX_ELEMENTS) return;
        JSONObject element = describe(node, origin);
        if (element != null) {
            // A node semantics makes up for a role or a description is not in the tree, and has no id.
            ComposeTree.Item item = content.byId.get(Reflect.getInt(node, "getId", -1));
            if (item != null) Json.put(element, "id", registry.idFor(item.ref));
            result.add(element);
        }
        Object children = Reflect.call(node, "getChildren");
        if (children instanceof List) {
            for (Object child : (List<?>) children) collect(child, origin, result, depth + 1, content, registry);
        }
    }

    private static JSONObject describe(Object node, int[] origin) {
        Object config = Reflect.call(node, "getConfig");
        if (!(config instanceof Iterable)) return null;

        String text = null, editable = null, description = null, role = null, tag = null, state = null;
        String toggle = null, progress = null;
        boolean disabled = false, heading = false, password = false, clickable = false, settable = false;
        Boolean selected = null;
        for (Object item : (Iterable<?>) config) {
            if (!(item instanceof Map.Entry)) continue;
            Map.Entry<?, ?> entry = (Map.Entry<?, ?>) item;
            Object name = Reflect.call(entry.getKey(), "getName");
            Object value = entry.getValue();
            if (!(name instanceof String)) continue;
            switch ((String) name) {
                case "Text": text = join(value); break;
                case "EditableText": editable = value == null ? null : value.toString(); break;
                case "ContentDescription": description = join(value); break;
                case "Role": role = value == null ? null : value.toString(); break;
                case "TestTag": tag = value == null ? null : value.toString(); break;
                case "StateDescription": state = value == null ? null : value.toString(); break;
                case "ToggleableState": toggle = value == null ? null : value.toString(); break;
                case "Selected": selected = value instanceof Boolean ? (Boolean) value : null; break;
                case "ProgressBarRangeInfo": progress = progress(value); break;
                case "Disabled": disabled = true; break;
                case "Heading": heading = true; break;
                case "Password": password = true; break;
                case "OnClick": clickable = true; break;
                case "SetText": settable = true; break;
                default: break;
            }
        }
        boolean isField = editable != null || settable;
        if (text == null && editable == null && description == null && role == null && tag == null
            && toggle == null && progress == null && !isField) {
            return null;
        }

        // The label is what the element says; the value what it holds.
        String label = text != null ? text : description;
        String value = null;
        if (isField) {
            if (editable != null && !editable.isEmpty()) {
                value = password ? "(secure text, " + editable.length() + " characters)" : editable;
            }
        } else if (toggle != null) {
            value = toggle.toLowerCase(Locale.US);
        } else if (progress != null) {
            value = progress;
        } else if (state != null) {
            value = state;
        }
        if (label != null && text != null && description != null && !description.equals(text) && value == null) {
            value = description;
        }

        List<String> traits = new ArrayList<>();
        if (role != null) {
            traits.add(Character.toLowerCase(role.charAt(0)) + role.substring(1));
        } else if (isField) {
            traits.add("textField");
        } else if (clickable) {
            traits.add("button");
        } else if (text != null) {
            traits.add("staticText");
        }
        if (heading) traits.add("header");
        if (Boolean.TRUE.equals(selected)) traits.add("selected");
        if (disabled) traits.add("disabled");
        if (password) traits.add("secure");

        Object bounds = Reflect.call(node, "getBoundsInWindow");
        float left = number(Reflect.call(bounds, "getLeft")), top = number(Reflect.call(bounds, "getTop"));
        float right = number(Reflect.call(bounds, "getRight")), bottom = number(Reflect.call(bounds, "getBottom"));
        float density = Ui.density();

        JSONObject element = Json.object();
        Json.put(element, "label", label);
        Json.put(element, "value", value);
        Json.put(element, "identifier", tag);
        Json.put(element, "traits", Json.array(traits));
        Json.put(element, "frame", Json.rect(
            (left + origin[0]) / density, (top + origin[1]) / density,
            Math.max(0, right - left) / density, Math.max(0, bottom - top) / density));
        return element;
    }

    private static float number(Object value) {
        return value instanceof Number ? ((Number) value).floatValue() : 0;
    }

    /** A semantics value that is a list of strings / annotated strings. */
    private static String join(Object value) {
        if (value == null) return null;
        if (!(value instanceof List)) return value.toString();
        StringBuilder joined = new StringBuilder();
        for (Object part : (List<?>) value) {
            if (part == null) continue;
            if (joined.length() > 0) joined.append(' ');
            joined.append(part);
        }
        return joined.length() == 0 ? null : joined.toString();
    }

    private static String progress(Object range) {
        Object current = Reflect.call(range, "getCurrent");
        Object bounds = Reflect.call(range, "getRange");
        Object start = Reflect.call(bounds, "getStart");
        Object end = Reflect.call(bounds, "getEndInclusive");
        if (!(current instanceof Number)) return null;
        if (start instanceof Number && end instanceof Number) {
            return Properties.trim(((Number) current).doubleValue()) + " in "
                + Properties.trim(((Number) start).doubleValue()) + "…" + Properties.trim(((Number) end).doubleValue());
        }
        return Properties.trim(((Number) current).doubleValue());
    }
}
