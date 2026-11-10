package dev.voly.agent;

import android.app.Activity;
import android.view.View;

import java.util.ArrayList;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;

/**
 * AndroidX fragments, reached by reflection: they are classes of the app,
 * not of the platform, so the agent can't link against them. An app without
 * them simply has none.
 */
final class Fragments {
    private Fragments() {}

    static final String FRAGMENT_ACTIVITY = "androidx.fragment.app.FragmentActivity";

    /** The activity's support FragmentManager, or null. */
    static Object manager(Activity activity) {
        if (activity == null || !Reflect.isInstance(activity, FRAGMENT_ACTIVITY)) return null;
        return Reflect.call(activity, "getSupportFragmentManager");
    }

    static List<Object> children(Object manager) {
        List<Object> result = new ArrayList<>();
        Object fragments = Reflect.call(manager, "getFragments");
        if (fragments instanceof List) {
            for (Object fragment : (List<?>) fragments) {
                if (fragment != null) result.add(fragment);
            }
        }
        return result;
    }

    static Object childManager(Object fragment) {
        if (!Boolean.TRUE.equals(Reflect.call(fragment, "isAdded"))) return null;
        return Reflect.call(fragment, "getChildFragmentManager");
    }

    static int backStackCount(Object manager) {
        Object count = Reflect.call(manager, "getBackStackEntryCount");
        return count instanceof Integer ? (Integer) count : 0;
    }

    /** Root view → the fragment that owns it, for every fragment of every activity. */
    static Map<View, Object> viewOwners() {
        Map<View, Object> owners = new IdentityHashMap<>();
        for (Activity activity : Ui.activities()) collect(manager(activity), owners, 0);
        return owners;
    }

    private static void collect(Object manager, Map<View, Object> owners, int depth) {
        if (manager == null || depth > 8) return;
        for (Object fragment : children(manager)) {
            Object view = Reflect.call(fragment, "getView");
            if (view instanceof View) owners.put((View) view, fragment);
            collect(childManager(fragment), owners, depth + 1);
        }
    }

    /**
     * The fragment the user is looking at: the last visible one, followed
     * down through its own child fragments (so a NavHostFragment gives the
     * destination it shows).
     */
    static Object topVisible(Activity activity) {
        Object manager = manager(activity);
        Object top = null;
        for (int depth = 0; manager != null && depth < 8; depth++) {
            Object visible = null;
            for (Object fragment : children(manager)) {
                if (Boolean.TRUE.equals(Reflect.call(fragment, "isVisible"))) visible = fragment;
            }
            if (visible == null) break;
            top = visible;
            manager = childManager(visible);
        }
        return top;
    }

    /**
     * The FragmentManager whose back stack "back" would pop first: the
     * deepest one, along the visible fragments, that has entries.
     */
    static Object deepestManagerWithBackStack(Activity activity) {
        Object manager = manager(activity);
        Object found = null;
        for (int depth = 0; manager != null && depth < 8; depth++) {
            if (backStackCount(manager) > 0) found = manager;
            Object visible = null;
            for (Object fragment : children(manager)) {
                if (Boolean.TRUE.equals(Reflect.call(fragment, "isVisible"))) visible = fragment;
            }
            if (visible == null) break;
            manager = childManager(visible);
        }
        return found;
    }

    /** Back stack entries across the activity's visible fragment managers. */
    static int totalBackStackCount(Activity activity) {
        Object manager = manager(activity);
        int total = 0;
        for (int depth = 0; manager != null && depth < 8; depth++) {
            total += backStackCount(manager);
            Object visible = null;
            for (Object fragment : children(manager)) {
                if (Boolean.TRUE.equals(Reflect.call(fragment, "isVisible"))) visible = fragment;
            }
            if (visible == null) break;
            manager = childManager(visible);
        }
        return total;
    }
}
