package dev.voly.agent;

import android.graphics.RectF;
import android.os.SystemClock;
import android.view.View;
import android.view.ViewParent;

import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * The content of an `AndroidComposeView` as a tree the inspector can show,
 * pick from and measure: what the view tree is for everything else.
 *
 * A Compose screen is one Android view; what it shows are layout nodes
 * (`LayoutNode`), which are not views and which `ViewGroup.getChildAt`
 * never returns. They are read here in one of two ways:
 *
 * - **Layout nodes**: every node Compose lays out — `Box`, `Row`, `Spacer`
 *   and all — in drawing order. Everything read from a node is Compose's
 *   public `LayoutInfo`; the one thing that is not public is the list of a
 *   node's children, which is why this can stop working with a Compose
 *   release.
 * - **Semantics nodes**: the nodes that say something to accessibility —
 *   texts, buttons, images with a description, anything with a test tag.
 *   All public API, and what is used when the children can't be listed.
 *   Containers that only arrange their content are missing from it.
 *
 * Either way a node has the same identity (`ComposeNode`), name and frame,
 * so the rest of the agent does not care which one it got.
 *
 * Compose is part of the app, not of the platform: everything is reflection
 * that gives nothing when a class or method is absent. Main thread only.
 */
final class ComposeTree {
    private ComposeTree() {}

    private static final String HOST = "androidx.compose.ui.platform.AndroidComposeView";
    private static final String INTEROP_HOLDER = "androidx.compose.ui.viewinterop.AndroidViewHolder";
    /** A screen of lists of cards is a few hundred nodes; this is a runaway guard. */
    private static final int MAX_NODES = 6000;
    private static final int MAX_DEPTH = 200;
    /** Ids above this belong to nodes semantics makes up for a role or a description. */
    private static final int FIRST_FAKE_SEMANTICS_ID = 1_000_000_000;
    private static final int MAX_LABEL = 80;

    /** One node of Compose content. */
    static final class Item {
        ComposeNode ref;
        /** The node's `LayoutInfo`; null only for a semantics node that has none. */
        Object info;
        /** `ModifierInfo` of the node's modifiers, outermost first. */
        List<?> modifiers = Collections.emptyList();
        /** Semantics property name to value; empty when the node has no semantics. */
        Map<String, Object> semantics = Collections.emptyMap();
        private String name;
        /** What the node says: its text, or its content description. */
        String label;
        String testTag;
        /** Bounds in the host view's coordinates, in pixels. */
        RectF local;
        /** Draws nothing outside its bounds: a list, a clipped card. */
        boolean clips;
        /** Shows something itself, or is someone's to tap; not just room between other nodes. */
        boolean solid;
        /** Rotated or scaled by a modifier of its own. */
        boolean transformed;
        Item parent;
        final List<Item> children = new ArrayList<>();

        /** `Text`, `Row`, `Button`, … Worked out when asked for: finding what is under the pointer never asks. */
        String name() {
            if (name == null) name = ComposeNames.of(this);
            return name;
        }
    }

    /** Everything in one host, as of one moment. */
    static final class Content {
        final List<Item> roots = new ArrayList<>();
        final Map<Integer, Item> byId = new HashMap<>();
        /** Every layout node is in it, not only those with semantics. */
        boolean complete;
        /** Less than there is: reading layout nodes failed part-way, or the node limit was reached. */
        boolean partial;
        long builtAt;
    }

    /** Off only in tests, to read the semantics tree where layout nodes could be listed. */
    static boolean useLayoutNodes = true;

    static boolean isHost(View view) {
        return Reflect.isInstance(view, HOST);
    }

    /**
     * The Compose host whose content `view` stands in for: the host itself,
     * or one of the helper views Compose keeps inside it (the container of
     * embedded views, of ripples, of drawing layers). Null for any other
     * view, embedded Android views (`AndroidView { }`) included.
     */
    static View hostFor(View view) {
        View current = view;
        for (int depth = 0; current != null && depth < 8; depth++) {
            if (isHost(current)) return current;
            if (Reflect.isInstance(current, INTEROP_HOLDER) || Classes.isAppDefined(current.getClass())) return null;
            String name = current.getClass().getName();
            // Compose's helpers are its own classes or bare views; anything else was put there by the app.
            if (!name.startsWith("androidx.compose.") && !name.equals("android.view.View")) return null;
            ViewParent parent = current.getParent();
            current = parent instanceof View ? (View) parent : null;
        }
        return null;
    }

    // MARK: Reading, with a short memory

    /**
     * Built trees, kept for a moment: hovering asks for the same host many
     * times a second. They hold on to the app's layout nodes, so they are
     * dropped as soon as nobody has asked for half a second.
     */
    private static final Map<View, Content> RECENT = new HashMap<>();
    private static final Runnable FORGET = RECENT::clear;
    private static final long KEEP_MS = 500;
    /**
     * How old a tree may be for pointing and highlighting, and for the
     * questions about one node that arrive together (its description, its
     * properties, its source). Reading a screen that is all Compose takes a
     * while, on the app's main thread; while something is being picked the
     * app is not being used, and changes little.
     */
    static final long RECENT_ENOUGH_MS = 250;

    /** The content of `host`, less than `maxAgeMs` old: 0 reads it now. */
    static Content content(View host, long maxAgeMs) {
        long now = SystemClock.uptimeMillis();
        Content recent = RECENT.get(host);
        if (recent != null && now - recent.builtAt < maxAgeMs) return recent;
        // Trees of other hosts that nobody asked for lately go now: while a
        // highlight keeps asking for one host, the timer below never fires.
        for (java.util.Iterator<Content> each = RECENT.values().iterator(); each.hasNext();) {
            if (now - each.next().builtAt > KEEP_MS) each.remove();
        }
        Content built = build(host);
        built.builtAt = now;
        RECENT.put(host, built);
        Ui.MAIN.removeCallbacks(FORGET);
        Ui.MAIN.postDelayed(FORGET, KEEP_MS);
        // A read that came up empty or short says nothing about which nodes still exist.
        if (!built.byId.isEmpty() && !built.partial) ComposeNode.retain(host, built.byId.keySet());
        return built;
    }

    /** The node a handle stands for, as it is now; null when it is gone. */
    static Item find(ComposeNode node, long maxAgeMs) {
        View host = node == null ? null : node.host();
        if (host == null || !host.isAttachedToWindow()) return null;
        return content(host, maxAgeMs).byId.get(node.id);
    }

    /**
     * Whether a node read earlier is still on screen, bringing its bounds
     * up to date: one node's worth of reading, where `find` reads the whole
     * host. For what keeps asking about the same node, like a highlight.
     */
    static boolean refresh(View host, Item item) {
        Object info = item == null ? null : item.info;
        if (info == null || host == null || !host.isAttachedToWindow()) return false;
        if (!Reflect.getBool(info, "isAttached", true) || !Reflect.getBool(info, "isPlaced", true)
            || Reflect.getBool(info, "isDeactivated", false)) {
            return false;
        }
        Object root = Reflect.get(Reflect.get(host, "getRoot"), "getCoordinates");
        RectF local = bounds(host, root, info, listOrEmpty(Reflect.get(info, "getModifierInfo")), null);
        if (local == null) return false;
        item.local = local;
        return true;
    }

    /** The deepest node under a point in the host's coordinates (pixels). */
    static Item hit(View host, float x, float y) {
        Content content = content(host, RECENT_ENOUGH_MS);
        for (int index = content.roots.size() - 1; index >= 0; index--) {
            Item found = deepest(content.roots.get(index), x, y);
            if (found != null) return found;
        }
        return null;
    }

    private static Item deepest(Item item, float x, float y) {
        RectF bounds = item.local;
        boolean inside = bounds != null && bounds.width() > 0 && bounds.height() > 0
            && x >= bounds.left && x < bounds.right && y >= bounds.top && y < bounds.bottom;
        // A child may lie outside its parent (an offset, a badge), so the
        // parent's bounds decide nothing — unless it clips: the rows of a list
        // that are scrolled under the toolbar are not what is there.
        if (item.clips && !inside) return null;
        // Later children are drawn over earlier ones.
        for (int index = item.children.size() - 1; index >= 0; index--) {
            Item found = deepest(item.children.get(index), x, y);
            if (found != null) return found;
        }
        // An empty node that shows nothing (a spacer) can't be seen, so it is
        // not what anybody points at: what is behind it is.
        if (!inside || (item.children.isEmpty() && !item.solid)) return null;
        return item;
    }

    // MARK: Building

    private static Content build(View host) {
        Object owner = Reflect.get(host, "getSemanticsOwner");
        Object semanticsRoot = Reflect.get(owner, "getUnmergedRootSemanticsNode");
        Object rootInfo = Reflect.get(semanticsRoot, "getLayoutInfo");
        if (rootInfo == null) rootInfo = Reflect.get(host, "getRoot");
        if (rootInfo == null) return new Content();

        boolean failed = false;
        try {
            List<?> top = useLayoutNodes ? childrenOf(rootInfo) : null;
            if (top != null) {
                Builder builder = new Builder(host, rootInfo);
                builder.indexSemantics(semanticsRoot, 0);
                for (Object child : top) builder.addLayoutNode(child, null, 0);
                builder.content.complete = true;
                builder.content.partial = builder.count >= MAX_NODES;
                return builder.content;
            }
        } catch (Throwable e) {
            failed = true;
            Log.w("reading Compose layout nodes failed, using semantics: " + e);
        }
        try {
            Builder builder = new Builder(host, rootInfo);
            Object children = Reflect.get(semanticsRoot, "getChildren");
            if (children instanceof List) {
                for (Object child : (List<?>) children) builder.addSemanticsNode(child, null, 0);
            }
            builder.content.partial = failed || builder.count >= MAX_NODES;
            return builder.content;
        } catch (Throwable e) {
            Log.w("reading Compose semantics failed: " + e);
            return new Content();
        }
    }

    /**
     * A layout node's children, back to front. Null when this Compose keeps
     * them where we don't know to look — the caller then settles for the
     * semantics tree.
     */
    static List<?> childrenOf(Object layoutNode) {
        // Not in the public API, but compiled under its plain name in every release so far.
        Object sorted = Reflect.get(layoutNode, "getZSortedChildren");
        Object list = Reflect.get(sorted, "asMutableList");
        // `internal`: getChildren$ui_release up to Compose 1.9, getChildren$ui from 1.10.
        if (!(list instanceof List)) list = Reflect.get(layoutNode, "getChildren");
        return list instanceof List ? new ArrayList<>((List<?>) list) : null;
    }

    private static final class Builder {
        final View host;
        final Object rootCoordinates;
        final Content content = new Content();
        /** Semantics node by id, for the layout nodes that have one. */
        final Map<Integer, Object> semanticsById = new HashMap<>();
        int count;

        Builder(View host, Object rootInfo) {
            this.host = host;
            this.rootCoordinates = Reflect.get(rootInfo, "getCoordinates");
        }

        void indexSemantics(Object node, int depth) {
            if (node == null || depth > MAX_DEPTH || semanticsById.size() >= MAX_NODES) return;
            int id = Reflect.getInt(node, "getId", -1);
            if (id >= 0 && id < FIRST_FAKE_SEMANTICS_ID) semanticsById.put(id, node);
            Object children = Reflect.get(node, "getChildren");
            if (!(children instanceof List)) return;
            for (Object child : (List<?>) children) indexSemantics(child, depth + 1);
        }

        void addLayoutNode(Object node, Item parent, int depth) {
            if (node == null || depth > MAX_DEPTH || count >= MAX_NODES) return;
            // Composed but not on screen: kept for reuse by a lazy list, or simply not placed.
            if (!Reflect.getBool(node, "isAttached", true) || !Reflect.getBool(node, "isPlaced", true)
                || Reflect.getBool(node, "isDeactivated", false)) {
                return;
            }
            int id = Reflect.getInt(node, "getSemanticsId", 0);
            if (id == 0) id = System.identityHashCode(node);
            Item item = new Item();
            item.info = node;
            item.modifiers = listOrEmpty(Reflect.get(node, "getModifierInfo"));
            Object semantics = semanticsById.get(id);
            if (semantics != null) item.semantics = properties(Reflect.get(semantics, "getConfig"));
            item.local = bounds(host, rootCoordinates, node, item.modifiers, semantics);
            if (item.local == null) return;
            if (!add(item, id, parent)) return;

            List<?> children = childrenOf(node);
            if (children != null) {
                for (Object child : children) addLayoutNode(child, item, depth + 1);
            }
            finish(item);
        }

        void addSemanticsNode(Object node, Item parent, int depth) {
            if (node == null || depth > MAX_DEPTH || count >= MAX_NODES) return;
            int id = Reflect.getInt(node, "getId", -1);
            if (id < 0 || id >= FIRST_FAKE_SEMANTICS_ID) return;
            Item item = new Item();
            item.info = Reflect.get(node, "getLayoutInfo");
            if (item.info != null) item.modifiers = listOrEmpty(Reflect.get(item.info, "getModifierInfo"));
            item.semantics = properties(Reflect.get(node, "getConfig"));
            item.local = bounds(host, rootCoordinates, item.info, item.modifiers, node);
            if (item.local == null || !add(item, id, parent)) return;

            Object children = Reflect.get(node, "getChildren");
            if (children instanceof List) {
                for (Object child : (List<?>) children) addSemanticsNode(child, item, depth + 1);
            }
            finish(item);
        }

        private boolean add(Item item, int id, Item parent) {
            // Should two nodes ever claim one id, the first keeps it: the host needs ids to be unique.
            if (content.byId.containsKey(id)) return false;
            count++;
            item.ref = ComposeNode.of(host, id);
            item.parent = parent;
            content.byId.put(id, item);
            if (parent != null) parent.children.add(item);
            else content.roots.add(item);
            return true;
        }

        /** What needs the children to be known. */
        private void finish(Item item) {
            item.testTag = string(item.semantics.get("TestTag"));
            String text = joined(item.semantics.get("Text"));
            // What is typed into a password field stays in the app, whatever Compose puts here.
            if (text == null && !item.semantics.containsKey("Password")) text = string(item.semantics.get("EditableText"));
            if (text == null) text = joined(item.semantics.get("ContentDescription"));
            item.label = shortened(text);
            item.solid = !item.semantics.isEmpty() || Reflect.get(item.info, "getInteropView") != null;
            for (Object modifier : item.modifiers) {
                Object element = Reflect.get(modifier, "getModifier");
                if (element == null) continue;
                String className = element.getClass().getName();
                if (paintsOrTakesTaps(className) || className.contains("Text")) item.solid = true;
                // clip(), clipToBounds() and scrolling containers are all a layer that clips.
                if (className.contains("GraphicsLayer") && Boolean.TRUE.equals(Reflect.field(element, "clip"))) {
                    item.clips = true;
                }
                if (className.contains("GraphicsLayer") && rotatesOrScales(element)) item.transformed = true;
            }
        }

    }

    // MARK: Bounds

    /**
     * Where the node is, in the host's coordinates. Unclipped: a card
     * half scrolled out of its list has its whole frame, like a view.
     */
    private static RectF bounds(View host, Object rootCoordinates, Object info, List<?> modifiers, Object semantics) {
        Object coordinates = visibleBox(info, modifiers);
        if (coordinates != null && rootCoordinates != null && Reflect.getBool(coordinates, "isAttached", false)
            && Reflect.getBool(rootCoordinates, "isAttached", false)) {
            RectF rect = rect(boundingBox(rootCoordinates, coordinates));
            // Compose answers "nowhere" for a box without an area; a spacer is 8dp high and nothing wide.
            if (rect != null && (rect.width() <= 0 || rect.height() <= 0)) {
                RectF placed = emptyBox(coordinates);
                if (placed != null) rect = placed;
            }
            if (rect != null) return rect;
        }
        // What accessibility is told: in the window's coordinates, and clipped to what is visible.
        RectF inWindow = rect(Reflect.get(semantics, "getBoundsInWindow"));
        if (inWindow == null) return null;
        int[] location = new int[2];
        host.getLocationInWindow(location);
        inWindow.offset(-location[0], -location[1]);
        return inWindow;
    }

    /** A graphics layer that turns or resizes what it holds, as `rotate()` and `scale()` make. */
    private static boolean rotatesOrScales(Object layer) {
        String[] names = {"scaleX", "scaleY", "rotationX", "rotationY", "rotationZ"};
        float[] idle = {1, 1, 0, 0, 0};
        for (int index = 0; index < names.length; index++) {
            Object value = Reflect.field(layer, names[index]);
            if (value instanceof Float && (Float) value != idle[index]) return true;
        }
        return false;
    }

    /**
     * The coordinates of the box a node shows itself in.
     *
     * A node has one box per layout modifier: `padding(16).background(c).padding(8)`
     * around a text is three boxes, and the one the eye sees is the middle
     * one, where the background is. So: the box of the outermost modifier
     * that paints or takes taps, and the node's own content box when there
     * is none (a `Text`, an `Image`, a plain `Row`) — which leaves padding
     * used as a margin out, and keeps padding inside a card in.
     */
    static Object visibleBox(Object info, List<?> modifiers) {
        for (Object modifier : modifiers) {
            Object element = Reflect.get(modifier, "getModifier");
            if (element != null && paintsOrTakesTaps(element.getClass().getName())) {
                Object coordinates = Reflect.get(modifier, "getCoordinates");
                if (coordinates != null) return coordinates;
            }
        }
        return Reflect.get(info, "getCoordinates");
    }

    private static final String[] VISIBLE_MODIFIERS = {
        "Background", "Border", "GraphicsLayer", "Clickable", "Selectable", "Toggleable",
        "DrawBehind", "DrawWith", "DrawBackground", "Painter", "Shadow", "Indication",
    };

    private static boolean paintsOrTakesTaps(String className) {
        String simple = className.substring(className.lastIndexOf('.') + 1);
        for (String part : VISIBLE_MODIFIERS) {
            if (simple.contains(part)) return true;
        }
        return false;
    }

    private static Method boundingBoxMethod;

    /** `root.localBoundingBoxOf(coordinates, clipBounds = false)`: a `Rect` in the root's coordinates. */
    private static Object boundingBox(Object root, Object coordinates) {
        try {
            Method method = boundingBoxMethod;
            if (method == null || !method.getDeclaringClass().isInstance(root)) {
                method = null;
                for (Method candidate : root.getClass().getMethods()) {
                    Class<?>[] types = candidate.getParameterTypes();
                    if (candidate.getName().equals("localBoundingBoxOf") && types.length == 2 && types[1] == boolean.class) {
                        candidate.setAccessible(true);
                        method = candidate;
                        break;
                    }
                }
                boundingBoxMethod = method;
            }
            return method == null ? null : method.invoke(root, coordinates, false);
        } catch (Throwable e) {
            return null;
        }
    }

    private static Method positionInRootMethod;
    private static boolean positionInRootSearched;

    /** Position and size of a box, without the transforms above it: `positionInRoot()` and `size`. */
    private static RectF emptyBox(Object coordinates) {
        try {
            if (!positionInRootSearched) {
                positionInRootSearched = true;
                Class<?> type = Reflect.classOrNull(
                    "androidx.compose.ui.layout.LayoutCoordinatesKt", coordinates.getClass().getClassLoader());
                if (type != null) {
                    for (Method candidate : type.getMethods()) {
                        if (candidate.getName().equals("positionInRoot") && candidate.getParameterTypes().length == 1) {
                            positionInRootMethod = candidate;
                            break;
                        }
                    }
                }
            }
            if (positionInRootMethod == null) return null;
            // Both are value classes packed into a long: two floats, and two ints.
            Object position = positionInRootMethod.invoke(null, coordinates);
            Object size = Reflect.get(coordinates, "getSize");
            if (!(position instanceof Long) || !(size instanceof Long)) return null;
            float x = Float.intBitsToFloat((int) ((Long) position >> 32));
            float y = Float.intBitsToFloat((int) ((Long) position & 0xFFFFFFFFL));
            int width = (int) ((Long) size >> 32), height = (int) ((Long) size & 0xFFFFFFFFL);
            if (Float.isNaN(x) || Float.isNaN(y) || Float.isInfinite(x) || Float.isInfinite(y)) return null;
            return new RectF(x, y, x + width, y + height);
        } catch (Throwable e) {
            return null;
        }
    }

    /** An `androidx.compose.ui.geometry.Rect` with sides that are numbers. */
    private static RectF rect(Object composeRect) {
        Object left = Reflect.get(composeRect, "getLeft"), top = Reflect.get(composeRect, "getTop");
        Object right = Reflect.get(composeRect, "getRight"), bottom = Reflect.get(composeRect, "getBottom");
        if (!(left instanceof Float) || !(top instanceof Float) || !(right instanceof Float) || !(bottom instanceof Float)) {
            return null;
        }
        RectF rect = new RectF((Float) left, (Float) top, (Float) right, (Float) bottom);
        for (float side : new float[] {rect.left, rect.top, rect.right, rect.bottom}) {
            if (Float.isNaN(side) || Float.isInfinite(side)) return null;
        }
        return rect;
    }

    // MARK: Semantics

    /** A `SemanticsConfiguration` as property name to value, in the order it lists them. */
    static Map<String, Object> properties(Object configuration) {
        if (!(configuration instanceof Iterable)) return Collections.emptyMap();
        Map<String, Object> result = new LinkedHashMap<>();
        try {
            for (Object item : (Iterable<?>) configuration) {
                if (!(item instanceof Map.Entry)) continue;
                Map.Entry<?, ?> entry = (Map.Entry<?, ?>) item;
                Object name = Reflect.get(entry.getKey(), "getName");
                if (name instanceof String) result.put((String) name, entry.getValue());
            }
        } catch (Throwable ignored) {
        }
        return result;
    }

    static String string(Object value) {
        if (value == null) return null;
        String text = value.toString();
        return text.isEmpty() ? null : text;
    }

    /** A semantics value that is a list of strings / annotated strings. */
    static String joined(Object value) {
        if (value == null) return null;
        if (!(value instanceof List)) return string(value);
        StringBuilder joined = new StringBuilder();
        for (Object part : (List<?>) value) {
            if (part == null) continue;
            if (joined.length() > 0) joined.append(' ');
            joined.append(part);
        }
        return joined.length() == 0 ? null : joined.toString();
    }

    private static String shortened(String text) {
        if (text == null) return null;
        String line = text.replaceAll("\\s+", " ").trim();
        if (line.isEmpty()) return null;
        return line.length() <= MAX_LABEL ? line : line.substring(0, MAX_LABEL - 1) + "…";
    }

    private static List<?> listOrEmpty(Object value) {
        return value instanceof List ? (List<?>) value : Collections.emptyList();
    }
}
