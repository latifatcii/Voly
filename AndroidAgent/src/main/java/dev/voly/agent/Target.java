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

    /** The Compose node as it is now; null for a view, or when the node is gone. */
    ComposeTree.Item item() {
        return node == null ? null : ComposeTree.find(node, ComposeTree.RECENT_ENOUGH_MS);
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

    boolean hasTransform() {
        return node == null && Ui.hasTransform(view);
    }
}
