package dev.voly.agent;

import android.app.Activity;
import android.app.Application;
import android.content.Context;
import android.content.ContextWrapper;
import android.graphics.Matrix;
import android.graphics.Rect;
import android.graphics.RectF;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.DisplayMetrics;
import android.view.Display;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewParent;
import android.view.Window;
import android.view.WindowManager;

import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.Map;

/**
 * The app as the agent sees it: its windows, activities and the geometry
 * that turns pixels into the points (dp) the host works in.
 *
 * "Window coordinates" on the host side are display coordinates here: every
 * window of the app is measured from the display's top-left corner, so a
 * dialog and the activity under it share one coordinate space and frames
 * line up with a screenshot of the whole display.
 */
final class Ui {
    private Ui() {}

    static final Handler MAIN = new Handler(Looper.getMainLooper());

    // MARK: App

    static Application application() {
        Class<?> activityThread = Reflect.classOrNull("android.app.ActivityThread", null);
        Object app = Reflect.callStatic(activityThread, "currentApplication");
        if (app instanceof Application) return (Application) app;
        Class<?> appGlobals = Reflect.classOrNull("android.app.AppGlobals", null);
        app = Reflect.callStatic(appGlobals, "getInitialApplication");
        return app instanceof Application ? (Application) app : null;
    }

    static float density() {
        Application app = application();
        if (app != null) return app.getResources().getDisplayMetrics().density;
        return android.content.res.Resources.getSystem().getDisplayMetrics().density;
    }

    static double dp(double pixels) {
        return pixels / density();
    }

    static int px(double points) {
        return (int) Math.round(points * density());
    }

    /** Size of the display in pixels, in its current rotation. */
    static int[] displaySizePx() {
        Application app = application();
        if (app != null) {
            WindowManager manager = (WindowManager) app.getSystemService(Context.WINDOW_SERVICE);
            if (manager != null) {
                try {
                    if (Build.VERSION.SDK_INT >= 30) {
                        Rect bounds = manager.getMaximumWindowMetrics().getBounds();
                        return new int[] {bounds.width(), bounds.height()};
                    }
                    Display display = manager.getDefaultDisplay();
                    DisplayMetrics metrics = new DisplayMetrics();
                    display.getRealMetrics(metrics);
                    return new int[] {metrics.widthPixels, metrics.heightPixels};
                } catch (Throwable ignored) {
                }
            }
        }
        DisplayMetrics metrics = android.content.res.Resources.getSystem().getDisplayMetrics();
        return new int[] {metrics.widthPixels, metrics.heightPixels};
    }

    static int displayRotation() {
        Activity activity = topActivity();
        try {
            if (activity != null) {
                Display display = Build.VERSION.SDK_INT >= 30
                    ? activity.getDisplay()
                    : activity.getWindowManager().getDefaultDisplay();
                if (display != null) return display.getRotation();
            }
            Application app = application();
            if (app != null) {
                WindowManager manager = (WindowManager) app.getSystemService(Context.WINDOW_SERVICE);
                if (manager != null) return manager.getDefaultDisplay().getRotation();
            }
        } catch (Throwable ignored) {
        }
        return 0;
    }

    /** The host's `InterfaceOrientation` raw value. */
    static String orientation() {
        switch (displayRotation()) {
            case 1: return "landscapeRight";
            case 2: return "portraitUpsideDown";
            case 3: return "landscapeLeft";
            default: return "portrait";
        }
    }

    // MARK: Windows

    /** Every root view of this process, bottom-most first. */
    static List<View> allRoots() {
        List<View> roots = new ArrayList<>();
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                roots.addAll(android.view.inspector.WindowInspector.getGlobalWindowViews());
                return roots;
            }
        } catch (Throwable ignored) {
        }
        try {
            Class<?> global = Reflect.classOrNull("android.view.WindowManagerGlobal", null);
            Object instance = Reflect.callStatic(global, "getInstance");
            Object views = Reflect.field(instance, "mViews");
            if (views instanceof Collection) {
                for (Object view : (Collection<?>) views) {
                    if (view instanceof View) roots.add((View) view);
                }
            } else if (views instanceof View[]) {
                for (View view : (View[]) views) roots.add(view);
            }
        } catch (Throwable ignored) {
        }
        return roots;
    }

    /** The windows the user can see right now, bottom-most first. */
    static List<View> visibleRoots() {
        List<View> roots = new ArrayList<>();
        for (View root : allRoots()) {
            if (isShown(root)) roots.add(root);
        }
        return roots;
    }

    static boolean isShown(View root) {
        return root.isAttachedToWindow()
            && root.getWindowVisibility() == View.VISIBLE
            && root.getVisibility() == View.VISIBLE
            && root.getWidth() > 0 && root.getHeight() > 0;
    }

    /** The `Window` a root view belongs to; null for popups, which have none. */
    static Window windowOf(View root) {
        for (Activity activity : activities()) {
            Window window = activity.getWindow();
            if (window != null && window.peekDecorView() == root) return window;
        }
        Object window = Reflect.field(root, "mWindow");
        return window instanceof Window ? (Window) window : null;
    }

    // MARK: Activities

    static List<Activity> activities() {
        List<Activity> result = new ArrayList<>();
        try {
            Class<?> activityThread = Reflect.classOrNull("android.app.ActivityThread", null);
            Object thread = Reflect.callStatic(activityThread, "currentActivityThread");
            Object records = Reflect.field(thread, "mActivities");
            if (records instanceof Map) {
                for (Object record : ((Map<?, ?>) records).values()) {
                    Object activity = Reflect.field(record, "activity");
                    if (activity instanceof Activity && !((Activity) activity).isDestroyed()) {
                        result.add((Activity) activity);
                    }
                }
            }
        } catch (Throwable ignored) {
        }
        if (!result.isEmpty()) return result;
        // Without the activity list, the windows still lead to the visible ones.
        for (View root : allRoots()) {
            Activity activity = activityOf(root.getContext());
            if (activity != null && !result.contains(activity)) result.add(activity);
        }
        return result;
    }

    static Activity activityOf(Context context) {
        for (int depth = 0; context != null && depth < 20; depth++) {
            if (context instanceof Activity) return (Activity) context;
            if (!(context instanceof ContextWrapper)) return null;
            context = ((ContextWrapper) context).getBaseContext();
        }
        return null;
    }

    /** The activity whose window is the top-most visible one. */
    static Activity topActivity() {
        List<Activity> activities = activities();
        List<View> roots = visibleRoots();
        for (int index = roots.size() - 1; index >= 0; index--) {
            View root = roots.get(index);
            for (Activity activity : activities) {
                Window window = activity.getWindow();
                if (window != null && window.peekDecorView() == root) return activity;
            }
        }
        for (Activity activity : activities) {
            if (activity.hasWindowFocus()) return activity;
        }
        return activities.isEmpty() ? null : activities.get(activities.size() - 1);
    }

    /** The activity a root view is the decor view of, if any. */
    static Activity activityForRoot(View root) {
        for (Activity activity : activities()) {
            Window window = activity.getWindow();
            if (window != null && window.peekDecorView() == root) return activity;
        }
        return null;
    }

    // MARK: Geometry

    /**
     * A view's bounds in its root view's coordinates (pixels), transforms
     * included, like `convert(bounds, to: nil)` on UIKit.
     */
    static RectF rectInRoot(View view) {
        RectF rect = new RectF(0, 0, view.getWidth(), view.getHeight());
        View current = view;
        while (true) {
            Matrix matrix = current.getMatrix();
            if (matrix != null && !matrix.isIdentity()) matrix.mapRect(rect);
            ViewParent parent = current.getParent();
            if (!(parent instanceof View)) break;
            View parentView = (View) parent;
            rect.offset(current.getLeft() - parentView.getScrollX(), current.getTop() - parentView.getScrollY());
            current = parentView;
        }
        return rect;
    }

    /** Where a root view's top-left corner is on the display, in pixels. */
    static int[] rootOrigin(View root) {
        int[] location = new int[2];
        try {
            root.getLocationOnScreen(location);
        } catch (Throwable ignored) {
        }
        return location;
    }

    /** A view's bounds on the display, in pixels. */
    static RectF rectOnScreen(View view) {
        RectF rect = rectInRoot(view);
        int[] origin = rootOrigin(view.getRootView());
        rect.offset(origin[0], origin[1]);
        return rect;
    }

    static org.json.JSONObject frameOnScreen(View view) {
        return points(rectOnScreen(view));
    }

    static org.json.JSONObject points(RectF pixels) {
        float density = density();
        return Json.rect(pixels.left / density, pixels.top / density, pixels.width() / density, pixels.height() / density);
    }

    static boolean hasTransform(View view) {
        Matrix matrix = view.getMatrix();
        return matrix != null && !matrix.isIdentity();
    }

    static boolean isVisible(View view) {
        return view.getVisibility() == View.VISIBLE && view.getAlpha() > 0.01f;
    }

    // MARK: Hit testing

    /**
     * The deepest visible view under a display point (pixels), looking at
     * the top-most window first. Ignores whether views are clickable: a
     * plain TextView must be pickable too.
     */
    static View hitTest(float screenX, float screenY) {
        List<View> roots = visibleRoots();
        for (int index = roots.size() - 1; index >= 0; index--) {
            View root = roots.get(index);
            int[] origin = rootOrigin(root);
            View found = deepest(root, screenX - origin[0], screenY - origin[1]);
            if (found != null) return found;
        }
        return null;
    }

    private static View deepest(View view, float x, float y) {
        if (!isVisible(view)) return null;
        if (x < 0 || y < 0 || x >= view.getWidth() || y >= view.getHeight()) return null;
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) view;
            for (int index = group.getChildCount() - 1; index >= 0; index--) {
                View child = group.getChildAt(index);
                float[] point = {x + group.getScrollX() - child.getLeft(), y + group.getScrollY() - child.getTop()};
                Matrix matrix = child.getMatrix();
                if (matrix != null && !matrix.isIdentity()) {
                    Matrix inverse = new Matrix();
                    if (matrix.invert(inverse)) inverse.mapPoints(point);
                }
                View found = deepest(child, point[0], point[1]);
                if (found != null) return found;
            }
            // An empty container that paints nothing can't be seen, so it is
            // not what anybody points at: what shows through it is. (A
            // fragment container waiting for its fragment, laid over a list.)
            if (isEmptyAndUnpainted(group)) return null;
        }
        return view;
    }

    private static boolean isEmptyAndUnpainted(ViewGroup group) {
        for (int index = 0; index < group.getChildCount(); index++) {
            if (isVisible(group.getChildAt(index))) return false;
        }
        return group.getBackground() == null && group.getForeground() == null && group.willNotDraw();
    }

    /** The root view that contains `view`, or the top-most visible one. */
    static View rootFor(View view) {
        if (view != null && view.isAttachedToWindow()) return view.getRootView();
        List<View> roots = visibleRoots();
        return roots.isEmpty() ? null : roots.get(roots.size() - 1);
    }
}
