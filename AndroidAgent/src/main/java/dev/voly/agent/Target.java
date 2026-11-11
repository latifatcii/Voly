package dev.voly.agent;

import android.graphics.RectF;
import android.view.View;

/**
 * Something that can be selected, highlighted and measured: a view, or a
 * node of Compose content inside one. Everything that only needs to know
 * where a thing is on screen takes this, so Compose content behaves like
 * views there without being one.
 */
final class Target {
    /** The view itself, or the `AndroidComposeView` the node is in. */
    final View view;
    /** Null for a view. */
    final ComposeNode node;
    /** The node as it was last read. */
    private ComposeTree.Item seen;

    private Target(View view, ComposeNode node) {
        this.view = view;
        this.node = node;
    }

    static Target of(View view) {
        return view == null ? null : new Target(view, null);
    }

    static Target of(ComposeNode node) {
        View host = node == null ? null : node.host();
        return host == null ? null : new Target(host, node);
    }

    /** What an id from the host stands for; null when it is neither a view nor Compose content. */
    static Target of(Object registered) {
        if (registered instanceof View) return of((View) registered);
        if (registered instanceof ComposeNode) return of((ComposeNode) registered);
        return null;
    }

    /** The object the host's id for this is registered under. */
    Object key() {
        return node != null ? node : view;
    }

    boolean isCompose() {
        return node != null;
    }

    /**
     * The Compose node as it is now; null for a view, or when the node is
     * gone. Asked again and again by whoever keeps a target (a highlight),
     * so a node already read is only asked where it is now: reading the
     * whole host each time would be the app's main thread several times a
     * second.
     */
    ComposeTree.Item item() {
        if (node == null) return null;
        if (!ComposeTree.refresh(view, seen)) seen = ComposeTree.find(node, ComposeTree.RECENT_ENOUGH_MS);
        return seen;
    }

    boolean isAttached() {
        if (!view.isAttachedToWindow()) return false;
        return node == null || item() != null;
    }

    View root() {
        return view.getRootView();
    }

    /** Bounds in the root view's coordinates (pixels); null when a Compose node is gone. */
    RectF rectInRoot() {
        if (node == null) return Ui.rectInRoot(view);
        ComposeTree.Item item = item();
        return item == null ? null : Ui.rectInRoot(view, item.local);
    }

    /** Bounds on the display (pixels); null when a Compose node is gone. */
    RectF rectOnScreen() {
        RectF rect = rectInRoot();
        if (rect == null) return null;
        int[] origin = Ui.rootOrigin(view.getRootView());
        rect.offset(origin[0], origin[1]);
        return rect;
    }

    /** Rotated or scaled, itself or through something above it. */
    boolean hasTransform() {
        if (Ui.hasTransform(view)) return true;
        for (ComposeTree.Item item = item(); item != null; item = item.parent) {
            if (item.transformed) return true;
        }
        return false;
    }
}
