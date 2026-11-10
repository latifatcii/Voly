package dev.voly.agent;

import android.view.View;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.Map;

/**
 * What the host needs to find a view's source: the classes worth opening,
 * most specific first. On Android there is no debug info to resolve an
 * address with, so the host searches the project by fully qualified class
 * name (and by the view's `android:id` for layout files).
 */
final class Sources {
    private Sources() {}

    /** `SourceInfo` */
    static JSONObject info(View view) {
        Map<View, Object> owners = Fragments.viewOwners();
        JSONArray candidates = new JSONArray();

        Class<?> type = view.getClass();
        if (Classes.isAppDefined(type)) {
            candidates.put(candidate("viewClass", type));
        } else {
            for (Class<?> parent = type.getSuperclass(); parent != null; parent = parent.getSuperclass()) {
                if (Classes.isAppDefined(parent)) {
                    candidates.put(candidate("superclass", parent));
                    break;
                }
            }
        }

        // The fragment or activity the view belongs to, and the nearest app-defined view above it.
        Object owner = null;
        Class<?> ancestorClass = null;
        for (Object current = view; current instanceof View; current = ((View) current).getParent()) {
            View step = (View) current;
            if (step != view && ancestorClass == null && Classes.isAppDefined(step.getClass())) {
                ancestorClass = step.getClass();
            }
            Object stepOwner = Snapshots.owner(step, owners);
            if (stepOwner != null) {
                owner = stepOwner;
                break;
            }
        }
        if (owner == null) owner = Ui.activityOf(view.getContext());
        if (owner != null && Classes.isAppDefined(owner.getClass())) {
            candidates.put(candidate("viewController", owner.getClass()));
        }
        // A fragment's activity is worth offering as well.
        if (owner != null && !(owner instanceof android.app.Activity)) {
            android.app.Activity activity = Ui.activityOf(view.getContext());
            if (activity != null && Classes.isAppDefined(activity.getClass())) {
                candidates.put(candidate("viewController", activity.getClass()));
            }
        }
        if (ancestorClass != null) candidates.put(candidate("ancestorView", ancestorClass));

        JSONObject info = Json.object();
        Json.put(info, "className", Classes.displayName(type));
        Json.put(info, "moduleName", Reflect.packageName(type));
        Json.put(info, "candidates", candidates);
        Json.put(info, "platform", "android");
        Json.put(info, "resourceID", Snapshots.resourceName(view));
        android.app.Application app = Ui.application();
        if (app != null) Json.put(info, "applicationID", app.getPackageName());
        return info;
    }

    /** `SourceCandidate`, with the fields only Mach-O images have left empty. */
    private static JSONObject candidate(String role, Class<?> type) {
        Class<?> outermost = Classes.outermost(type);
        JSONObject candidate = Json.object();
        Json.put(candidate, "role", role);
        Json.put(candidate, "className", Classes.displayName(outermost));
        Json.put(candidate, "moduleName", Reflect.packageName(outermost));
        Json.put(candidate, "runtimeName", outermost.getName());
        Json.put(candidate, "imagePath", "");
        Json.put(candidate, "probes", new JSONArray());
        return candidate;
    }
}
