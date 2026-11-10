package dev.voly.agent;

import android.app.Activity;
import android.app.Application;
import android.graphics.RectF;
import android.os.Build;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ImageView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Map;

/**
 * The view tree as the inspector window shows it: one `ViewNode` per view,
 * one `SceneNode` for the app, with every visible window as a root.
 */
final class Snapshots {
    private final ObjectRegistry registry;

    Snapshots(ObjectRegistry registry) {
        this.registry = registry;
    }

    /** `HierarchySnapshot` */
    JSONObject hierarchy(int depth) {
        Map<View, Object> owners = Fragments.viewOwners();
        List<View> roots = Ui.visibleRoots();
        JSONArray windowIds = new JSONArray();
        JSONArray windows = new JSONArray();
        for (View root : roots) {
            windowIds.put(registry.idFor(root));
            windows.put(node(root, depth, owners));
        }
        Application app = Ui.application();
        Activity top = Ui.topActivity();
        JSONObject scene = Json.object();
        Json.put(scene, "id", sceneId());
        Json.put(scene, "role", "Android");
        CharSequence title = top != null ? top.getTitle() : null;
        Json.put(scene, "title", title != null && title.length() > 0
            ? title.toString()
            : (app != null ? app.getPackageName() : null));
        Json.put(scene, "windowIDs", windowIds);
        Json.put(scene, "windowsInline", windows);

        JSONObject snapshot = Json.object();
        Json.put(snapshot, "scenes", new JSONArray().put(scene));
        Json.put(snapshot, "issuedAt", Json.iso8601(new Date()));
        return snapshot;
    }

    /** The one scene an Android app has: its display. */
    long sceneId() {
        Application app = Ui.application();
        return registry.idFor(app != null ? app : Snapshots.class);
    }

    JSONObject subtree(long id, int depth) throws AgentError {
        return node(view(id), depth, Fragments.viewOwners());
    }

    View view(long id) throws AgentError {
        Object object = registry.objectFor(id);
        if (!(object instanceof View)) throw AgentError.objectGone(id);
        return (View) object;
    }

    /** `ViewNode` */
    JSONObject node(View view, int remainingDepth, Map<View, Object> owners) {
        float density = Ui.density();
        JSONArray childIds = new JSONArray();
        JSONArray children = remainingDepth > 0 ? new JSONArray() : null;
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) view;
            for (int index = 0; index < group.getChildCount(); index++) {
                View child = group.getChildAt(index);
                childIds.put(registry.idFor(child));
                if (children != null) children.put(node(child, remainingDepth - 1, owners));
            }
        }

        double width = view.getWidth() / density, height = view.getHeight() / density;
        double left = view.getLeft() / density, top = view.getTop() / density;
        JSONObject node = Json.object();
        Json.put(node, "id", registry.idFor(view));
        Json.put(node, "className", Classes.displayName(view.getClass()));
        Json.put(node, "moduleName", Reflect.packageName(view.getClass()));
        Json.put(node, "accessibilityIdentifier", resourceName(view));
        Object owner = owner(view, owners);
        if (owner != null) Json.put(node, "owningViewControllerID", registry.idFor(owner));
        Json.put(node, "frame", Json.rect(left, top, width, height));
        Json.put(node, "bounds", Json.rect(view.getScrollX() / density, view.getScrollY() / density, width, height));
        Json.put(node, "center", Json.point(left + width / 2, top + height / 2));
        Json.put(node, "isHidden", view.getVisibility() != View.VISIBLE);
        Json.put(node, "alpha", (double) view.getAlpha());
        Json.put(node, "layer", layer(view));
        Integer tint = Style.tintColor(view);
        if (tint != null) Json.put(node, "tintColor", Json.color(tint));
        Json.put(node, "clipsToBounds", clipsToBounds(view));
        Json.put(node, "contentMode", view instanceof ImageView ? ((ImageView) view).getScaleType().ordinal() : 0);
        Json.put(node, "constraintIDs", new JSONArray());
        Json.put(node, "childIDs", childIds);
        if (children != null) Json.put(node, "childrenInline", children);
        Json.put(node, "classInheritance", inheritance(view.getClass()));
        Json.put(node, "hasNonIdentityTransform", Ui.hasTransform(view));
        RectF onScreen = Ui.rectOnScreen(view);
        Json.put(node, "windowFrame", Ui.points(onScreen));
        return node;
    }

    private JSONObject layer(View view) {
        float density = Ui.density();
        JSONObject layer = Json.object();
        Json.put(layer, "cornerRadius", (double) (Style.cornerRadius(view) / density));
        Style.Border border = Style.border(view);
        Json.put(layer, "borderWidth", border != null ? (double) (border.width / density) : 0.0);
        if (border != null) Json.put(layer, "borderColor", Json.color(border.color));
        float elevation = view.getElevation() + view.getTranslationZ();
        Json.put(layer, "shadowOpacity", elevation > 0 ? 1.0 : 0.0);
        Json.put(layer, "shadowRadius", (double) (elevation / density));
        Json.put(layer, "shadowOffset", Json.size(0, 0));
        Json.put(layer, "masksToBounds", view.getClipToOutline());
        Json.put(layer, "shouldRasterize", view.getLayerType() != View.LAYER_TYPE_NONE);
        Json.put(layer, "rasterizationScale", (double) density);
        Json.put(layer, "opacity", (double) view.getAlpha());
        Json.put(layer, "isOpaque", view.isOpaque());
        Integer background = Style.backgroundColor(view);
        if (background != null) Json.put(layer, "backgroundColor", Json.color(background));
        Json.put(layer, "contentsScale", (double) density);
        return layer;
    }

    static boolean clipsToBounds(View view) {
        if (view instanceof ViewGroup && Build.VERSION.SDK_INT >= 18) return ((ViewGroup) view).getClipChildren();
        return view.getClipToOutline();
    }

    /** The entry name of the view's `android:id`, the closest thing to an accessibility identifier. */
    static String resourceName(View view) {
        int id = view.getId();
        if (id == View.NO_ID || (id >>> 24) == 0) return null;
        try {
            return view.getResources().getResourceEntryName(id);
        } catch (Throwable e) {
            return null;
        }
    }

    /** The fragment or activity whose root view this is. */
    static Object owner(View view, Map<View, Object> owners) {
        Object fragment = owners.get(view);
        if (fragment != null) return fragment;
        if (view.getParent() instanceof View) return null;
        return Ui.activityForRoot(view);
    }

    static JSONArray inheritance(Class<?> type) {
        List<String> chain = new ArrayList<>();
        for (Class<?> current = type; current != null; current = current.getSuperclass()) {
            chain.add(Classes.displayName(current));
        }
        return Json.array(chain);
    }
}
