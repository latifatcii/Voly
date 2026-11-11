package dev.voly.agent;

import java.util.Locale;

/**
 * What to call a node of Compose content.
 *
 * A layout node does not know which composable function emitted it — that
 * is in the composition's slot table, which only tooling builds read. What
 * a node does carry says nearly as much: its semantics role, whether it
 * shows text, and the class of the measure policy that lays out its
 * children (`RowMeasurePolicy`, `BoxKt$boxMeasurePolicy$1`, an app's own
 * `ProductCardKt$ProductCard$1$1`).
 */
final class ComposeNames {
    private ComposeNames() {}

    static String of(ComposeTree.Item item) {
        if (Reflect.get(item.info, "getInteropView") != null) return "AndroidView";
        String role = ComposeTree.string(item.semantics.get("Role"));
        if (role != null && !role.equals("Unknown")) return role;
        if (item.semantics.containsKey("EditableText") || item.semantics.containsKey("SetText")) return "TextField";
        if (item.semantics.containsKey("Text") || has(item, "TextStringSimple", "TextAnnotatedString")) return "Text";

        String layout = fromMeasurePolicy(Reflect.get(item.info, "getMeasurePolicy"), 0);
        // Images and icons are an empty layout that a painter draws into.
        if (item.children.isEmpty() && (layout == null || layout.equals("Box") || layout.equals("Layout"))
            && has(item, "Painter")) {
            return "Image";
        }
        if (layout != null) return layout;
        if (item.info == null) return item.semantics.containsKey("OnClick") ? "Button" : "Node";
        return "Layout";
    }

    /** The app-defined class behind a node's layout, if it has one: where its source is. */
    static Class<?> appLayoutClass(Object info) {
        Object policy = Reflect.get(info, "getMeasurePolicy");
        for (int depth = 0; policy != null && depth < 4; depth++) {
            if (Classes.isAppDefined(policy.getClass())) return policy.getClass();
            policy = inner(policy);
        }
        return null;
    }

    private static boolean has(ComposeTree.Item item, String... parts) {
        for (Object modifier : item.modifiers) {
            Object element = Reflect.get(modifier, "getModifier");
            if (element == null) continue;
            String name = element.getClass().getName();
            String simple = name.substring(name.lastIndexOf('.') + 1);
            for (String part : parts) {
                if (simple.contains(part)) return true;
            }
        }
        return false;
    }

    // MARK: Measure policies

    private static String fromMeasurePolicy(Object policy, int depth) {
        if (policy == null || depth > 3) return null;
        String className = policy.getClass().getName();
        // Wrappers say nothing themselves: SubcomposeLayout wraps the block it
        // was given, and lazy layouts wrap their own policy in that block.
        Object wrapped = inner(policy);
        if (wrapped != null) {
            String name = fromMeasurePolicy(wrapped, depth + 1);
            if (name != null) return name;
        }
        if (className.contains("LayoutNodeSubcompositionsState")) return "SubcomposeLayout";
        if (className.endsWith(".RootMeasurePolicy")) return null;

        String name = clean(className);
        if (name == null) return null;
        // One policy for both directions; which one is a field of it.
        String orientation = orientation(policy);
        if (name.equals("RowColumn")) {
            if (orientation == null) return "RowColumn";
            return orientation.equals("Horizontal") ? "Row" : "Column";
        }
        if (name.equals("LazyList") && orientation != null) {
            return orientation.equals("Horizontal") ? "LazyRow" : "LazyColumn";
        }
        return name;
    }

    /**
     * The measure block or policy a wrapping policy was created with.
     *
     * It is a captured variable, and what those are called depends on who
     * compiled the lambda: `$block` in a class Kotlin generated, `f$0` in
     * one the Android build tools did. So by name first, then by what it is.
     */
    private static Object inner(Object policy) {
        for (String field : new String[] {"$block", "$measurePolicy", "measurePolicy", "$policy"}) {
            Object value = Reflect.field(policy, field);
            if (value != null && value != policy) return value;
        }
        String className = policy.getClass().getName();
        boolean wrapper = className.contains("LayoutNodeSubcompositionsState") || className.contains("LazyLayoutKt");
        if (!wrapper) return null;
        Object block = null;
        try {
            for (java.lang.reflect.Field field : policy.getClass().getDeclaredFields()) {
                if (java.lang.reflect.Modifier.isStatic(field.getModifiers())) continue;
                field.setAccessible(true);
                Object value = field.get(policy);
                if (value == null || value == policy) continue;
                if (named(value.getClass(), "MeasurePolicy")) return value;
                if (block == null && named(value.getClass(), "kotlin.jvm.functions.Function2")) block = value;
            }
        } catch (Throwable ignored) {
        }
        return block;
    }

    /** Whether a class, or an interface it implements, has `part` in its name. */
    private static boolean named(Class<?> type, String part) {
        for (Class<?> current = type; current != null; current = current.getSuperclass()) {
            if (current.getName().contains(part)) return true;
            for (Class<?> implemented : current.getInterfaces()) {
                if (implemented.getName().contains(part)) return true;
            }
        }
        return false;
    }

    private static String orientation(Object policy) {
        for (String field : new String[] {"$orientation", "orientation"}) {
            Object value = Reflect.field(policy, field);
            if (value != null) return value.toString();
        }
        Object vertical = Reflect.field(policy, "$isVertical");
        if (vertical instanceof Boolean) return (Boolean) vertical ? "Vertical" : "Horizontal";
        return null;
    }

    /**
     * `androidx.compose.foundation.layout.RowMeasurePolicy` → `Row`,
     * `…layout.BoxKt$boxMeasurePolicy$1` → `Box`,
     * `…lazy.LazyListKt$rememberLazyListMeasurePolicy$1$1` → `LazyList`,
     * `com.shop.ProductCardKt$ProductCard$1$1` → `ProductCard`,
     * `com.shop.BadgeKt$$ExternalSyntheticLambda0` → `Badge`.
     */
    static String clean(String className) {
        String simple = className.substring(className.lastIndexOf('.') + 1);
        // A lambda's class on a desktop JVM: Outer$$Lambda/0x…, Outer$$Lambda$12/0x….
        int slash = simple.indexOf('/');
        if (slash >= 0) simple = simple.substring(0, slash);
        String[] parts = simple.split("\\$");
        String outer = word(parts[0].endsWith("Kt") ? parts[0].substring(0, parts[0].length() - 2) : parts[0]);
        // The function a lambda or anonymous object was written in names it better than its file does.
        for (int index = 1; index < parts.length; index++) {
            String part = parts[index];
            if (part.isEmpty() || !Character.isLetter(part.charAt(0))) continue;
            if (part.startsWith("ExternalSynthetic") || part.startsWith("Lambda") || part.startsWith("lambda")
                || part.startsWith("inlined") || part.startsWith("sam") || part.equals("measure")) {
                continue;
            }
            String inner = word(part);
            if (inner != null) return inner;
        }
        return outer;
    }

    /** `rememberLazyListMeasurePolicy` → `LazyList`, `EmptyBoxMeasurePolicy` → `Box`; null when nothing is left. */
    private static String word(String raw) {
        String name = raw;
        for (String prefix : new String[] {"remember", "create", "Default", "Empty"}) {
            if (name.length() > prefix.length() && name.startsWith(prefix)
                && Character.isUpperCase(name.charAt(prefix.length()))) {
                name = name.substring(prefix.length());
            }
        }
        for (String suffix : new String[] {"MeasurePolicyImpl", "MeasurePolicy", "MeasureScope", "Impl"}) {
            if (name.endsWith(suffix)) name = name.substring(0, name.length() - suffix.length());
        }
        if (name.isEmpty() || name.equals("Empty") || name.equals("Default")) return null;
        return name.substring(0, 1).toUpperCase(Locale.US) + name.substring(1);
    }
}
