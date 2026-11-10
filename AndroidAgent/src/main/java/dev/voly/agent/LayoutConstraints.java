package dev.voly.agent;

import android.view.View;
import android.view.ViewGroup;

import org.json.JSONArray;
import org.json.JSONObject;

import java.lang.ref.WeakReference;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.WeakHashMap;

/**
 * A view's layout params, told the way the host tells Auto Layout
 * constraints (`ConstraintNode`), so the inspector's Layout tab and the
 * `set_constraint` tool work on Android unchanged:
 *
 * - a fixed `layout_width` / `layout_height` is "Width equals 120";
 * - a non-zero margin is "Top margin equals 16";
 * - every ConstraintLayout connection is a real two-view constraint,
 *   "Leading to ImageView.trailing + 8", with the margin as its constant.
 *
 * The constant of each can be changed live. Priority and deactivation have
 * no counterpart here.
 */
final class LayoutConstraints {
    private static final String CONSTRAINT_PARAMS = "androidx.constraintlayout.widget.ConstraintLayout$LayoutParams";

    /** One constraint: which view it belongs to and which layout param it stands for. */
    private static final class Ref {
        final WeakReference<View> view;
        final String kind;

        Ref(View view, String kind) {
            this.view = new WeakReference<>(view);
            this.kind = kind;
        }
    }

    private final ObjectRegistry registry;
    /** Keeps each view's refs alive exactly as long as the view, so their ids stay stable. */
    private final WeakHashMap<View, Map<String, Ref>> refs = new WeakHashMap<>();

    LayoutConstraints(ObjectRegistry registry) {
        this.registry = registry;
    }

    static boolean isConstraintParams(ViewGroup.LayoutParams params) {
        return params != null && Reflect.extendsClass(params.getClass(), CONSTRAINT_PARAMS);
    }

    private long idFor(View view, String kind) {
        Map<String, Ref> byKind = refs.get(view);
        if (byKind == null) {
            byKind = new HashMap<>();
            refs.put(view, byKind);
        }
        Ref ref = byKind.get(kind);
        if (ref == null) {
            ref = new Ref(view, kind);
            byKind.put(kind, ref);
        }
        return registry.idFor(ref);
    }

    // MARK: Reading

    /** A ConstraintLayout connection: the params field, and what it connects. */
    private static final String[][] CONNECTIONS = {
        // field, this view's attribute, the target's attribute, margin
        {"leftToLeft", "left", "left", "left"},
        {"leftToRight", "left", "right", "left"},
        {"rightToLeft", "right", "left", "right"},
        {"rightToRight", "right", "right", "right"},
        {"topToTop", "top", "top", "top"},
        {"topToBottom", "top", "bottom", "top"},
        {"bottomToTop", "bottom", "top", "bottom"},
        {"bottomToBottom", "bottom", "bottom", "bottom"},
        {"baselineToBaseline", "firstBaseline", "firstBaseline", "none"},
        {"startToEnd", "leading", "trailing", "start"},
        {"startToStart", "leading", "leading", "start"},
        {"endToStart", "trailing", "leading", "end"},
        {"endToEnd", "trailing", "trailing", "end"},
    };

    JSONArray constraints(long id) throws AgentError {
        Object object = registry.objectFor(id);
        if (!(object instanceof View)) throw AgentError.objectGone(id);
        View view = (View) object;
        List<JSONObject> list = new ArrayList<>();
        collect(view, list);
        // Constraints other views of the same ConstraintLayout have to this one.
        if (view.getParent() instanceof ViewGroup && isConstraintParams(view.getLayoutParams())) {
            ViewGroup parent = (ViewGroup) view.getParent();
            for (int index = 0; index < parent.getChildCount(); index++) {
                View sibling = parent.getChildAt(index);
                if (sibling == view) continue;
                List<JSONObject> theirs = new ArrayList<>();
                collectConnections(sibling, theirs, view);
                list.addAll(theirs);
            }
        }
        JSONArray array = new JSONArray();
        for (JSONObject constraint : list) array.put(constraint);
        return array;
    }

    private void collect(View view, List<JSONObject> list) {
        ViewGroup.LayoutParams params = view.getLayoutParams();
        if (params == null) return;
        float density = Ui.density();
        View parent = view.getParent() instanceof View ? (View) view.getParent() : null;
        boolean constrained = isConstraintParams(params);

        if (params.width > 0 || (params.width == 0 && !constrained)) {
            list.add(dimension(view, "width", params.width / density));
        } else if (params.width == ViewGroup.LayoutParams.MATCH_PARENT && parent != null) {
            list.add(matchParent(view, parent, "width"));
        }
        if (params.height > 0 || (params.height == 0 && !constrained)) {
            list.add(dimension(view, "height", params.height / density));
        } else if (params.height == ViewGroup.LayoutParams.MATCH_PARENT && parent != null) {
            list.add(matchParent(view, parent, "height"));
        }

        if (constrained) {
            collectConnections(view, list, null);
        } else if (params instanceof ViewGroup.MarginLayoutParams) {
            ViewGroup.MarginLayoutParams margins = (ViewGroup.MarginLayoutParams) params;
            addMargin(view, list, "leftMargin", margins.leftMargin / density);
            addMargin(view, list, "topMargin", margins.topMargin / density);
            addMargin(view, list, "rightMargin", margins.rightMargin / density);
            addMargin(view, list, "bottomMargin", margins.bottomMargin / density);
        }
    }

    private void addMargin(View view, List<JSONObject> list, String attribute, double value) {
        if (value == 0) return;
        list.add(node(view, attribute, attribute, null, "notAnAttribute", value, "layout_" + attribute, view));
    }

    private JSONObject dimension(View view, String attribute, double value) {
        return node(view, attribute, attribute, null, "notAnAttribute", value, "layout_" + attribute, view);
    }

    private JSONObject matchParent(View view, View parent, String attribute) {
        return node(view, "match_" + attribute, attribute, parent, attribute, 0, "match_parent", parent);
    }

    /**
     * @param onlyTo when set, only connections whose target is that view.
     */
    private void collectConnections(View view, List<JSONObject> list, View onlyTo) {
        ViewGroup.LayoutParams params = view.getLayoutParams();
        if (!isConstraintParams(params) || !(view.getParent() instanceof ViewGroup)) return;
        ViewGroup parent = (ViewGroup) view.getParent();
        float density = Ui.density();
        for (String[] connection : CONNECTIONS) {
            Object target = Reflect.field(params, connection[0]);
            if (!(target instanceof Integer) || (Integer) target == -1) continue;
            int targetId = (Integer) target;
            View other = targetId == 0 ? parent : child(parent, targetId);
            if (other == null || (onlyTo != null && other != onlyTo)) continue;
            double margin = margin(params, connection[3], view) / density;
            // A margin pushes the view inwards: trailing/bottom edges get a negative constant.
            boolean far = connection[1].equals("right") || connection[1].equals("bottom") || connection[1].equals("trailing");
            list.add(node(view, connection[0], connection[1], other, connection[2], far ? -margin : margin,
                attributeName(connection[0]), parent));
        }
    }

    /** `startToEnd` → `layout_constraintStart_toEndOf`, the XML attribute it comes from. */
    static String attributeName(String field) {
        int split = field.indexOf("To");
        if (split <= 0) return field;
        return "layout_constraint" + Character.toUpperCase(field.charAt(0)) + field.substring(1, split)
            + "_to" + field.substring(split + 2) + "Of";
    }

    private static View child(ViewGroup parent, int id) {
        for (int index = 0; index < parent.getChildCount(); index++) {
            View child = parent.getChildAt(index);
            if (child.getId() == id) return child;
        }
        // Guidelines, barriers and other helpers are found this way too.
        Object found = Reflect.call(parent, "getViewById", new Class<?>[] {int.class}, id);
        return found instanceof View ? (View) found : null;
    }

    private static float margin(ViewGroup.LayoutParams params, String side, View view) {
        if (!(params instanceof ViewGroup.MarginLayoutParams)) return 0;
        ViewGroup.MarginLayoutParams margins = (ViewGroup.MarginLayoutParams) params;
        switch (side) {
            case "left": return margins.leftMargin;
            case "right": return margins.rightMargin;
            case "top": return margins.topMargin;
            case "bottom": return margins.bottomMargin;
            case "start": return margins.getMarginStart();
            case "end": return margins.getMarginEnd();
            default: return 0;
        }
    }

    private JSONObject node(
        View view, String kind, String firstAttribute, View second, String secondAttribute,
        double constant, String identifier, View owner
    ) {
        String firstName = Classes.displayName(view.getClass());
        String secondName = second == null ? "nil" : Classes.displayName(second.getClass());
        JSONObject node = Json.object();
        Json.put(node, "id", idFor(view, kind));
        Json.put(node, "firstItemID", registry.idFor(view));
        Json.put(node, "firstAttribute", firstAttribute);
        Json.put(node, "relation", "equal");
        if (second != null) Json.put(node, "secondItemID", registry.idFor(second));
        Json.put(node, "secondAttribute", secondAttribute);
        Json.put(node, "constant", constant);
        Json.put(node, "multiplier", 1.0);
        Json.put(node, "priority", 1000.0);
        Json.put(node, "identifier", identifier);
        Json.put(node, "isActive", true);
        Json.put(node, "ownerID", registry.idFor(owner));
        Json.put(node, "isSystemGenerated", false);
        // Same shape as the iOS agent's summary; the host reads the second
        // item's class name out of it.
        Json.put(node, "summary", firstName + "." + firstAttribute + " = " + secondName + "." + secondAttribute
            + " × 1.0 + " + constant + " @1000.0");
        return node;
    }

    // MARK: Writing

    /** Apply a `SetConstraintRequest`; returns the view to re-snapshot. */
    View apply(JSONObject request) throws AgentError {
        long constraintId = request.optLong("constraintID");
        Object object = registry.objectFor(constraintId);
        if (!(object instanceof Ref)) throw AgentError.objectGone(constraintId);
        Ref ref = (Ref) object;
        View view = ref.view.get();
        if (view == null) throw AgentError.objectGone(constraintId);
        JSONObject change = request.optJSONObject("change");
        if (change == null) throw AgentError.invalidCommand("setConstraint without a change");
        if (change.has("isActive") && !change.isNull("isActive") && !change.optBoolean("isActive", true)) {
            throw AgentError.unavailable(
                "Layout params can't be switched off on Android. Change the constant, or hide the view with visibility=gone.");
        }
        if (change.has("constant") && !change.isNull("constant")) {
            applyConstant(view, ref.kind, change.optDouble("constant"));
        }
        // Layout params have no priority; a value sent along with a constant is ignored.
        Object anchor = registry.objectFor(request.optLong("anchorObjectID"));
        View result = anchor instanceof View ? (View) anchor : view;
        view.requestLayout();
        return result;
    }

    private void applyConstant(View view, String kind, double constant) throws AgentError {
        ViewGroup.LayoutParams params = view.getLayoutParams();
        if (params == null || Double.isNaN(constant) || Double.isInfinite(constant)) throw AgentError.unsupportedValue();
        int pixels = Math.round((float) Math.abs(constant) * Ui.density());
        ViewGroup.MarginLayoutParams margins = params instanceof ViewGroup.MarginLayoutParams
            ? (ViewGroup.MarginLayoutParams) params : null;
        switch (kind) {
            case "width": params.width = pixels; break;
            case "height": params.height = pixels; break;
            case "match_width":
            case "match_height":
                throw AgentError.unavailable("match_parent has no constant. Set layout_width / layout_height with set_property instead.");
            default: {
                if (margins == null) throw AgentError.unsupportedValue();
                String side = kind;
                for (String[] connection : CONNECTIONS) {
                    if (connection[0].equals(kind)) side = connection[3];
                }
                switch (side) {
                    case "left":
                    case "leftMargin": margins.leftMargin = pixels; break;
                    case "right":
                    case "rightMargin": margins.rightMargin = pixels; break;
                    case "top":
                    case "topMargin": margins.topMargin = pixels; break;
                    case "bottom":
                    case "bottomMargin": margins.bottomMargin = pixels; break;
                    case "start": margins.setMarginStart(pixels); break;
                    case "end": margins.setMarginEnd(pixels); break;
                    default:
                        throw AgentError.unavailable("This constraint has no margin to change.");
                }
            }
        }
        view.setLayoutParams(params);
    }
}
