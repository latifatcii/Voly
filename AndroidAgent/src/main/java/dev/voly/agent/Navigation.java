package dev.voly.agent;

import android.app.Activity;
import android.app.Dialog;
import android.view.KeyEvent;
import android.view.View;
import android.view.Window;

import org.json.JSONObject;

import java.util.List;

/**
 * Leaving the current screen, in the host's three verbs:
 *
 * - `dismiss` closes what is shown on top of the screen: a dialog, bottom
 *   sheet or popup;
 * - `pop` goes back one step, the way the Back button would (a fragment
 *   back stack entry, a navigation destination, or the activity itself when
 *   it isn't the first one);
 * - `popToRoot` empties the fragment back stacks and finishes every
 *   activity above the first.
 */
final class Navigation {
    private Navigation() {}

    private static final String POPUP_DECOR = "android.widget.PopupWindow$PopupDecorView";

    /** The top-most visible window that is not an activity's own: a dialog or popup. */
    private static View presentedRoot() {
        List<View> roots = Ui.visibleRoots();
        for (int index = roots.size() - 1; index >= 0; index--) {
            View root = roots.get(index);
            if (Ui.activityForRoot(root) != null) return null;
            if (Ui.windowOf(root) != null || root.getClass().getName().equals(POPUP_DECOR)) return root;
        }
        return null;
    }

    private static boolean canGoBack(Activity activity) {
        if (activity == null) return false;
        if (Fragments.totalBackStackCount(activity) > 0) return true;
        if (!activity.isTaskRoot()) return true;
        // Compose Navigation and custom back handling register here.
        Object dispatcher = Reflect.call(activity, "getOnBackPressedDispatcher");
        return Boolean.TRUE.equals(Reflect.call(dispatcher, "hasEnabledCallbacks"));
    }

    /** What the user is looking at: the visible fragment if there is one, else the activity. */
    static String topScreenName() {
        Activity activity = Ui.topActivity();
        if (activity == null) return null;
        Object fragment = Fragments.topVisible(activity);
        return Classes.displayName((fragment != null ? fragment : activity).getClass());
    }

    /** `NavigationState` */
    static JSONObject state() {
        Activity activity = Ui.topActivity();
        boolean presented = presentedRoot() != null;
        boolean back = canGoBack(activity);
        JSONObject reasons = Json.object();
        if (!presented) Json.put(reasons, "dismiss", "No dialog, bottom sheet or popup is showing.");
        if (!back) {
            String reason = activity == null ? "The app has no activity on screen." : "This is the app's first screen.";
            Json.put(reasons, "pop", reason);
            Json.put(reasons, "popToRoot", reason);
        }
        JSONObject state = Json.object();
        Json.put(state, "canDismiss", presented);
        Json.put(state, "canPop", back);
        Json.put(state, "canPopToRoot", back);
        Json.put(state, "unavailableReasons", reasons);
        Json.put(state, "topViewController", topScreenName());
        if (activity != null) {
            int depth = Fragments.totalBackStackCount(activity);
            Json.put(state, "navigationStackDepth", depth > 0 ? depth + 1 : Math.max(1, Ui.activities().size()));
        }
        Json.put(state, "isTransitioning", false);
        return state;
    }

    /** `NavigationResult` */
    static JSONObject perform(String action) {
        boolean performed = false;
        String message = null;
        try {
            switch (action) {
                case "dismiss": {
                    View root = presentedRoot();
                    if (root == null) message = "No dialog, bottom sheet or popup is showing.";
                    else performed = dismiss(root);
                    if (root != null && !performed) message = "The window on top could not be dismissed.";
                    break;
                }
                case "pop": {
                    Activity activity = Ui.topActivity();
                    if (!canGoBack(activity)) message = "This is the app's first screen.";
                    else performed = goBack(activity);
                    break;
                }
                case "popToRoot": {
                    Activity activity = Ui.topActivity();
                    if (!canGoBack(activity)) message = "This is the app's first screen.";
                    else performed = popToRoot();
                    break;
                }
                default:
                    message = "Unknown action " + action;
                    break;
            }
        } catch (Throwable e) {
            message = "Failed: " + e;
        }
        JSONObject result = Json.object();
        Json.put(result, "action", action);
        Json.put(result, "performed", performed);
        Json.put(result, "message", message);
        Json.put(result, "state", state());
        return result;
    }

    private static boolean dismiss(View root) {
        if (root.getClass().getName().equals(POPUP_DECOR)) {
            Object popup = Reflect.field(root, "this$0");
            if (popup instanceof android.widget.PopupWindow) {
                ((android.widget.PopupWindow) popup).dismiss();
                return true;
            }
        }
        Window window = Ui.windowOf(root);
        if (window == null) return false;
        // AppCompat and others wrap the dialog's callback; unwrap to reach it.
        Object callback = window.getCallback();
        for (int depth = 0; callback != null && depth < 6; depth++) {
            if (callback instanceof Dialog) {
                ((Dialog) callback).dismiss();
                return true;
            }
            Object inner = callback instanceof PickCallback
                ? ((PickCallback) callback).wrapped()
                : Reflect.call(callback, "getWrapped");
            if (inner == null) inner = Reflect.field(callback, "mWrapped");
            callback = inner;
        }
        // Anything else that is on top answers to Back.
        return sendBack(window);
    }

    private static boolean sendBack(Window window) {
        Window.Callback callback = window.getCallback();
        if (callback == null) return false;
        long now = android.os.SystemClock.uptimeMillis();
        boolean down = callback.dispatchKeyEvent(new KeyEvent(now, now, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_BACK, 0));
        boolean up = callback.dispatchKeyEvent(new KeyEvent(now, now, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_BACK, 0));
        return down || up;
    }

    private static boolean goBack(Activity activity) {
        Object dispatcher = Reflect.call(activity, "getOnBackPressedDispatcher");
        if (dispatcher != null && Reflect.method(dispatcher.getClass(), "onBackPressed") != null) {
            // Runs the app's own back handling: fragments, Navigation, Compose BackHandler.
            Reflect.call(dispatcher, "onBackPressed");
            return true;
        }
        activity.onBackPressed();
        return true;
    }

    private static boolean popToRoot() {
        List<Activity> activities = Ui.activities();
        boolean changed = false;
        Activity rootActivity = null;
        for (Activity activity : activities) {
            if (activity.isTaskRoot()) rootActivity = activity;
        }
        for (Activity activity : activities) {
            if (activity != rootActivity && !activity.isFinishing()) {
                activity.finish();
                changed = true;
            }
        }
        Activity remaining = rootActivity != null ? rootActivity : Ui.topActivity();
        if (remaining != null) {
            // Deepest first, so a nested navigation host unwinds before its parent.
            for (int guard = 0; guard < 8; guard++) {
                Object manager = Fragments.deepestManagerWithBackStack(remaining);
                if (manager == null) break;
                Object popped = Reflect.call(manager, "popBackStackImmediate",
                    new Class<?>[] {String.class, int.class}, null, 1 /* POP_BACK_STACK_INCLUSIVE */);
                if (!Boolean.TRUE.equals(popped)) break;
                changed = true;
            }
        }
        if (!changed && remaining != null && canGoBack(remaining)) {
            // Back handling that isn't a fragment stack (Compose Navigation): step back until done.
            for (int guard = 0; guard < 20 && canGoBack(remaining); guard++) {
                goBack(remaining);
                changed = true;
            }
        }
        return changed;
    }
}
