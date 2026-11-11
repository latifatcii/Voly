package dev.voly.agent;

import android.view.View;

import java.lang.ref.WeakReference;
import java.util.HashMap;
import java.util.Iterator;
import java.util.Map;
import java.util.Set;
import java.util.WeakHashMap;

/**
 * What the host's id for a piece of Compose content stands for: one layout
 * node inside one `AndroidComposeView`.
 *
 * Compose content has no views, so there is no object of the app's to hand
 * to the `ObjectRegistry`. This is that object. It is the same instance for
 * as long as the node is on screen, so the node keeps its id from one
 * snapshot to the next, and it holds on to nothing: the view and the node
 * are referenced weakly, and looked up again whenever they are needed.
 */
final class ComposeNode {
    /** One handle per node of each host, kept exactly as long as the host view. */
    private static final WeakHashMap<View, Map<Integer, ComposeNode>> NODES = new WeakHashMap<>();

    private final WeakReference<View> host;
    /** Compose's own id for the node (`LayoutInfo.semanticsId`), unique within the app. */
    final int id;

    private ComposeNode(View host, int id) {
        this.host = new WeakReference<>(host);
        this.id = id;
    }

    static ComposeNode of(View host, int id) {
        Map<Integer, ComposeNode> known = NODES.get(host);
        if (known == null) {
            known = new HashMap<>();
            NODES.put(host, known);
        }
        ComposeNode node = known.get(id);
        if (node == null) {
            node = new ComposeNode(host, id);
            known.put(id, node);
        }
        return node;
    }

    /** Forget the nodes that are no longer in `host`; their ids stop resolving. */
    static void retain(View host, Set<Integer> ids) {
        Map<Integer, ComposeNode> known = NODES.get(host);
        if (known == null) return;
        for (Iterator<Integer> iterator = known.keySet().iterator(); iterator.hasNext();) {
            if (!ids.contains(iterator.next())) iterator.remove();
        }
    }

    /** The `AndroidComposeView` the node is in; null once that view is gone. */
    View host() {
        return host.get();
    }
}
