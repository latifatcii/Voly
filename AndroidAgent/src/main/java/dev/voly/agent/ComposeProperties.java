package dev.voly.agent;

import android.view.View;

import org.json.JSONArray;
import org.json.JSONObject;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * What can be read about a node of Compose content, as the host's
 * `PropertyBag`: what it says (semantics), how its text is styled, and its
 * modifiers in the order they apply, outermost first.
 *
 * All of it is read-only. A view keeps its own values and can be told new
 * ones; a node's values are arguments its composable function was called
 * with, and the next recomposition passes them again.
 *
 * Lengths are in dp, text sizes in sp, as everywhere else.
 */
final class ComposeProperties {
    private ComposeProperties() {}

    private static final int MAX_MODIFIERS = 40;
    private static final int MAX_VALUE = 160;

    static AgentError notEditable() {
        return AgentError.unavailable(
            "Compose content can't be changed from outside: its values are arguments of the composable, "
                + "passed again at the next recomposition. Change them in the source.");
    }

    /** `PropertyBag` */
    static JSONObject bag(long id, ComposeTree.Item item, View host) {
        JSONObject bag = Json.object();
        Json.put(bag, "objectID", id);
        // Nothing here can be edited, and these two groups are editable by definition.
        Json.put(bag, "view", Json.object());
        Json.put(bag, "layer", Json.object());
        Json.put(bag, "custom", read(item, host).json());
        return bag;
    }

    /** Everything there is to say about a node, in the order the panel lists it. */
    static Rows read(ComposeTree.Item item, View host) {
        Rows rows = new Rows();
        semantics(item, rows);
        textStyle(item, host, rows);
        Object policy = Reflect.get(item.info, "getMeasurePolicy");
        // How the node arranges its children; a text or an image has none to arrange.
        if (policy != null && !simpleName(policy.getClass()).startsWith("Empty")) {
            rows.string("measurePolicy", simpleName(policy.getClass()));
        }
        rows.modifiers = true;
        modifiers(item, host, rows);
        return rows;
    }

    /** One property: its name, its `PropValue` type, and its value as a String, Double, Boolean or ARGB Integer. */
    static final class Row {
        final String name, type;
        final Object value;
        /** An argument of a modifier, rather than something the node says about itself. */
        final boolean modifier;

        Row(String name, String type, Object value, boolean modifier) {
            this.name = name;
            this.type = type;
            this.value = value;
            this.modifier = modifier;
        }
    }

    /** Rows with names that stay unique: the host tells them apart by name. */
    static final class Rows {
        final List<Row> list = new ArrayList<>();
        private final Set<String> names = new HashSet<>();
        boolean modifiers;

        /** `[CustomPropDescriptor]`, all read-only. */
        JSONArray json() {
            JSONArray array = new JSONArray();
            for (Row row : list) {
                JSONObject value;
                if (row.value instanceof Boolean) value = Json.prop((boolean) (Boolean) row.value);
                else if (row.value instanceof Double) value = Json.prop((double) (Double) row.value);
                else if (row.type.equals("color")) value = Json.propColor((Integer) row.value);
                else value = Json.prop(String.valueOf(row.value));
                JSONObject json = Json.object();
                Json.put(json, "name", row.name);
                Json.put(json, "declaredType", row.type);
                Json.put(json, "isReadOnly", true);
                Json.put(json, "source", "registered");
                Json.put(json, "currentValue", value);
                array.put(json);
            }
            return array;
        }

        /** The value of the first row called `name`, if it is of `type`. */
        <T> T get(String name, Class<T> type) {
            for (Row row : list) {
                if (row.name.equals(name)) return type.isInstance(row.value) ? type.cast(row.value) : null;
            }
            return null;
        }

        private void add(String name, String type, Object value) {
            String unique = name;
            for (int number = 2; !names.add(unique); number++) unique = name + " " + number;
            list.add(new Row(unique, type, value, modifiers));
        }

        void string(String name, String value) {
            if (value != null) add(name, "string", value);
        }

        void number(String name, double value) {
            add(name, "double", value);
        }

        void bool(String name, boolean value) {
            add(name, "bool", value);
        }

        void color(String name, Integer argb) {
            if (argb != null) add(name, "color", argb);
        }
    }

    // MARK: Semantics

    private static void semantics(ComposeTree.Item item, Rows rows) {
        Map<String, Object> semantics = item.semantics;
        boolean field = semantics.containsKey("EditableText") || semantics.containsKey("SetText");
        String text = ComposeTree.joined(semantics.get("Text"));
        String editable = ComposeTree.string(semantics.get("EditableText"));
        if (field) {
            boolean password = semantics.containsKey("Password");
            if (editable != null) {
                rows.string("text", password ? "(secure text, " + editable.length() + " characters)" : editable);
            }
            // A field's own Text is its label or placeholder.
            rows.string("hint", text);
        } else {
            rows.string("text", text);
        }
        rows.string("contentDescription", ComposeTree.joined(semantics.get("ContentDescription")));
        rows.string("testTag", ComposeTree.string(semantics.get("TestTag")));
        rows.string("role", ComposeTree.string(semantics.get("Role")));
        rows.string("stateDescription", ComposeTree.string(semantics.get("StateDescription")));
        Object toggle = semantics.get("ToggleableState");
        if (toggle != null) rows.string("toggleableState", toggle.toString().toLowerCase(Locale.US));
        if (semantics.get("Selected") instanceof Boolean) rows.bool("isSelected", (Boolean) semantics.get("Selected"));
        if (semantics.containsKey("OnClick")) rows.bool("isClickable", true);
        if (semantics.containsKey("Disabled")) rows.bool("isEnabled", false);
        if (semantics.containsKey("Heading")) rows.bool("isHeading", true);
    }

    // MARK: Text style

    private static void textStyle(ComposeTree.Item item, View host, Rows rows) {
        Object element = null;
        for (Object modifier : item.modifiers) {
            Object candidate = Reflect.get(modifier, "getModifier");
            if (candidate != null && isText(candidate)) {
                element = candidate;
                break;
            }
        }
        if (element == null) return;
        Object style = Reflect.field(element, "style");
        Object span = Reflect.field(style, "spanStyle");
        Object paragraph = Reflect.field(style, "paragraphStyle");

        double[] size = textUnit(Reflect.field(span, "fontSize"));
        if (size != null && size[1] == SP) rows.number("textSize", size[0]);
        else if (size != null) rows.string("textSize", Properties.trim(size[0]) + "em");

        // A color given to Text() itself wins over the one in its style.
        Integer color = Colors.argb(Reflect.get(Reflect.field(element, "color"), "invoke"), host);
        if (color == null) color = Colors.argb(Reflect.get(Reflect.field(span, "textForegroundStyle"), "getColor"), host);
        rows.color("textColor", color);

        Object weight = Reflect.field(Reflect.field(span, "fontWeight"), "weight");
        if (weight instanceof Integer) rows.string("fontWeight", weightName((Integer) weight));
        rows.string("fontFamily", fontFamily(Reflect.field(span, "fontFamily"), host));
        Object fontStyle = Reflect.field(span, "fontStyle");
        if (fontStyle != null && fontStyle.toString().equals("Italic")) rows.bool("isItalic", true);

        double[] spacing = textUnit(Reflect.field(span, "letterSpacing"));
        if (spacing != null) rows.string("letterSpacing", Properties.trim(spacing[0]) + (spacing[1] == SP ? "sp" : "em"));
        double[] lineHeight = textUnit(Reflect.field(paragraph, "lineHeight"));
        if (lineHeight != null) {
            rows.string("lineHeight", Properties.trim(lineHeight[0]) + (lineHeight[1] == SP ? "sp" : "em"));
        }
        rows.string("textAlign", textAlign(Reflect.field(paragraph, "textAlign")));
        Object decoration = Reflect.field(span, "textDecoration");
        if (decoration != null && !decoration.toString().contains("None")) {
            rows.string("textDecoration", decoration.toString().replace("TextDecoration.", ""));
        }

        Object maxLines = Reflect.field(element, "maxLines");
        if (maxLines instanceof Integer && (Integer) maxLines != Integer.MAX_VALUE) rows.number("maxLines", (Integer) maxLines);
        Object overflow = Reflect.field(element, "overflow");
        // Clip is what a text does when nobody says otherwise.
        if (overflow instanceof Integer && (Integer) overflow != 1) rows.string("overflow", overflowName((Integer) overflow));
    }

    private static boolean isText(Object element) {
        String name = simpleName(element.getClass());
        return name.contains("TextStringSimple") || name.contains("TextAnnotatedString");
    }

    private static final double SP = 1, EM = 2;

    /** A packed `TextUnit` as {value, SP or EM}; null when it is unspecified. */
    private static double[] textUnit(Object packed) {
        if (!(packed instanceof Long)) return null;
        long bits = (Long) packed;
        long type = bits & (0xFFL << 32);
        float value = Float.intBitsToFloat((int) (bits & 0xFFFFFFFFL));
        if (Float.isNaN(value) || Float.isInfinite(value)) return null;
        if (type == (0x01L << 32)) return new double[] {value, SP};
        if (type == (0x02L << 32)) return new double[] {value, EM};
        return null;
    }

    private static String weightName(int weight) {
        String name;
        if (weight <= 150) name = "Thin";
        else if (weight <= 250) name = "ExtraLight";
        else if (weight <= 350) name = "Light";
        else if (weight <= 450) name = "Regular";
        else if (weight <= 550) name = "Medium";
        else if (weight <= 650) name = "SemiBold";
        else if (weight <= 750) name = "Bold";
        else if (weight <= 850) name = "ExtraBold";
        else name = "Black";
        return name + " (" + weight + ")";
    }

    /** `sans-serif`, or the names of the font resources a family is made of. */
    private static String fontFamily(Object family, View host) {
        if (family == null) return null;
        Object fonts = Reflect.get(family, "getFonts");
        if (fonts instanceof List) {
            List<String> names = new ArrayList<>();
            for (Object font : (List<?>) fonts) {
                Object resource = Reflect.get(font, "getResId");
                String name = null;
                if (resource instanceof Integer) {
                    try {
                        name = host.getResources().getResourceEntryName((Integer) resource);
                    } catch (Throwable ignored) {
                    }
                }
                if (name != null && !names.contains(name)) names.add(name);
                if (names.size() >= 4) break;
            }
            if (!names.isEmpty()) return android.text.TextUtils.join(", ", names);
        }
        Object generic = Reflect.get(family, "getName");
        if (generic instanceof String) return (String) generic;
        String described = family.toString();
        return described.startsWith("FontFamily.") ? described.substring("FontFamily.".length()) : shortened(described);
    }

    private static String textAlign(Object align) {
        if (align == null) return null;
        if (!(align instanceof Integer)) {
            String name = align.toString();
            return name.isEmpty() || name.equals("Unspecified") || name.equals("Invalid") ? null : name;
        }
        switch ((Integer) align) {
            case 1: return "Left";
            case 2: return "Right";
            case 3: return "Center";
            case 4: return "Justify";
            case 5: return "Start";
            case 6: return "End";
            default: return null;
        }
    }

    private static String overflowName(int overflow) {
        switch (overflow) {
            case 1: return "Clip";
            case 2: return "Ellipsis";
            case 3: return "Visible";
            case 4: return "StartEllipsis";
            case 5: return "MiddleEllipsis";
            default: return null;
        }
    }

    // MARK: Modifiers

    private static void modifiers(ComposeTree.Item item, View host, Rows rows) {
        // A password field's modifiers hold what was typed in ways that can't
        // be told from their other arguments: they are named, and not read.
        boolean secure = item.semantics.containsKey("Password");
        int listed = 0;
        for (Object modifier : item.modifiers) {
            Object element = Reflect.get(modifier, "getModifier");
            if (element == null || isText(element)) continue;
            String className = simpleName(element.getClass());
            String name = modifierName(element, className);
            // Already told, as what the node says to accessibility.
            // …and the wrappers older Compose put around a modifier to name it for tooling.
            if (name.equals("testTag") || name.equals("semantics") || name.equals("inspectable")) continue;
            if (listed++ >= MAX_MODIFIERS) break;
            try {
                if (className.contains("Background") && background(element, name, host, rows)) continue;
                if (className.contains("GraphicsLayer") && Reflect.field(element, "scaleX") != null) {
                    rows.string(name, graphicsLayer(element, host));
                    continue;
                }
                rows.string(name, secure ? "" : described(element, host));
            } catch (Throwable e) {
                rows.string(name, "");
            }
        }
    }

    /** `PaddingElement` → `padding`, `BorderModifierNodeElement` → `border`; Compose's own name when it gives one. */
    private static String modifierName(Object element, String className) {
        Object given = Reflect.get(element, "getNameFallback");
        if (given instanceof String && !((String) given).isEmpty() && !given.equals(className)) return (String) given;
        String name = className;
        int dollar = name.indexOf('$');
        if (dollar > 0) name = name.substring(0, dollar);
        if (name.endsWith("Kt")) name = name.substring(0, name.length() - 2);
        for (String suffix : new String[] {"ModifierNodeElement", "NodeElement", "ModifierElement", "Element", "ModifierImpl", "Modifier", "Node"}) {
            if (name.length() > suffix.length() && name.endsWith(suffix)) {
                name = name.substring(0, name.length() - suffix.length());
                break;
            }
        }
        if (name.contains("Semantics")) return "semantics";
        if (name.contains("PointerInput")) return "pointerInput";
        if (name.contains("GraphicsLayer")) return "graphicsLayer";
        if (name.equals("LayoutWeight")) return "weight";
        if (name.isEmpty()) return "modifier";
        return name.substring(0, 1).toLowerCase(Locale.US) + name.substring(1);
    }

    /** A fill color as a color, so the panel shows a swatch; its shape beside it. */
    private static boolean background(Object element, String name, View host, Rows rows) {
        Integer color = Colors.argb(Reflect.field(element, "color"), host);
        Object brush = Reflect.field(element, "brush");
        if (color == null && brush == null) return false;
        if (color != null) rows.color(name, color);
        else rows.string(name, value(brush, "brush", host));
        Object shape = Reflect.field(element, "shape");
        if (shape != null && !shape.toString().equals("RectangleShape")) rows.string(name + "Shape", shape(shape));
        Object alpha = Reflect.field(element, "alpha");
        if (alpha instanceof Float && (Float) alpha != 1f) rows.number(name + "Alpha", (Float) alpha);
        return true;
    }

    /** Only what differs from a layer that does nothing. */
    private static String graphicsLayer(Object element, View host) {
        List<String> parts = new ArrayList<>();
        String[] names = {"alpha", "scaleX", "scaleY", "translationX", "translationY", "rotationX", "rotationY", "rotationZ", "shadowElevation"};
        float[] idle = {1, 1, 1, 0, 0, 0, 0, 0, 0};
        for (int index = 0; index < names.length; index++) {
            Object value = Reflect.field(element, names[index]);
            if (value instanceof Float && (Float) value != idle[index] && !((Float) value).isNaN()) {
                parts.add(names[index] + " " + Properties.trim((Float) value));
            }
        }
        if (Boolean.TRUE.equals(Reflect.field(element, "clip"))) {
            Object shape = Reflect.field(element, "shape");
            parts.add("clip " + (shape == null ? "" : shape(shape)));
        }
        return shortened(android.text.TextUtils.join(", ", parts));
    }

    /** A modifier's arguments: what it tells Compose's own inspector, or else its fields. */
    private static String described(Object element, View host) {
        Map<String, Object> values = new LinkedHashMap<>();
        Object listed = Reflect.get(element, "getInspectableElements");
        Object iterator = Reflect.get(listed, "iterator");
        if (iterator instanceof Iterator) {
            Iterator<?> each = (Iterator<?>) iterator;
            while (each.hasNext() && values.size() < 12) {
                Object entry = each.next();
                Object name = Reflect.get(entry, "getName");
                if (name instanceof String) values.put((String) name, Reflect.get(entry, "getValue"));
            }
        }
        if (values.isEmpty()) {
            Object single = Reflect.get(element, "getValueOverride");
            String text = value(single, "", host);
            if (text != null) return text;
            fields(element, values);
        }
        List<String> parts = new ArrayList<>();
        for (Map.Entry<String, Object> entry : values.entrySet()) {
            String text = value(entry.getValue(), entry.getKey(), host);
            if (text != null) parts.add(entry.getKey() + " " + text);
        }
        return shortened(android.text.TextUtils.join(", ", parts));
    }

    private static void fields(Object element, Map<String, Object> values) {
        for (Class<?> type = element.getClass(); type != null && values.size() < 12; type = type.getSuperclass()) {
            if (type.getName().startsWith("androidx.compose.ui.node.") || type == Object.class) break;
            Field[] declared;
            try {
                declared = type.getDeclaredFields();
            } catch (Throwable e) {
                continue;
            }
            for (Field field : declared) {
                if (Modifier.isStatic(field.getModifiers()) || field.isSynthetic()) continue;
                String name = field.getName();
                if (name.equals("inspectorInfo") || name.startsWith("$") || name.startsWith("_")) continue;
                try {
                    field.setAccessible(true);
                    values.put(name, field.get(element));
                } catch (Throwable ignored) {
                }
                if (values.size() >= 12) break;
            }
        }
    }

    /** One argument as text; null for what says nothing (unset values, callbacks). */
    private static String value(Object value, String name, View host) {
        if (value == null) return null;
        if (value instanceof Float || value instanceof Double) {
            double number = ((Number) value).doubleValue();
            if (Double.isNaN(number)) return null;
            if (Double.isInfinite(number)) return number > 0 ? "∞" : "-∞";
            return Properties.trim(number);
        }
        boolean colorName = name.toLowerCase(Locale.US).contains("color");
        if (value instanceof Long) {
            // A long is a packed value class; only a color can be told from its name.
            Integer color = colorName ? Colors.argb(value, host) : null;
            return color == null ? null : Json.hex(color);
        }
        if (value instanceof Integer) {
            int number = (Integer) value;
            return number == Integer.MAX_VALUE || number == Integer.MIN_VALUE ? null : String.valueOf(number);
        }
        if (value instanceof Boolean || value instanceof String || value instanceof Enum) return value.toString();

        String className = value.getClass().getName();
        if (className.startsWith("kotlin.jvm.functions.") || className.contains("Lambda") || className.contains("$$")) {
            return null;
        }
        for (Class<?> implemented : value.getClass().getInterfaces()) {
            if (implemented.getName().startsWith("kotlin.jvm.functions.") || implemented.getName().equals("kotlin.Function")) {
                return null;
            }
        }
        if (className.equals("androidx.compose.ui.graphics.Color")
            || className.equals("androidx.compose.ui.graphics.SolidColor")) {
            Integer color = Colors.argb(Reflect.get(value, "getValue"), host);
            return color == null ? null : Json.hex(color);
        }
        if (Reflect.isInstance(value, "androidx.compose.ui.graphics.Shape")) return shape(value);
        String text = tidy(value.toString());
        // An object that doesn't describe itself (an interaction source, an indication) is no argument worth reading.
        if (text.isEmpty() || text.contains("@")) return null;
        return shortened(text);
    }

    /** `RoundedCornerShape(topStart = CornerSize(size = 8.0.dp), …)` → `RoundedCornerShape(8dp)`. */
    static String shape(Object shape) {
        String text = tidy(shape.toString());
        int open = text.indexOf('('), close = text.lastIndexOf(')');
        if (open > 0 && close > open) {
            String[] corners = text.substring(open + 1, close).split(",\\s*");
            if (corners.length == 4) {
                String first = corners[0].substring(corners[0].indexOf('=') + 1).trim();
                boolean same = true;
                for (String corner : corners) {
                    if (!corner.substring(corner.indexOf('=') + 1).trim().equals(first)) same = false;
                }
                if (same) return text.substring(0, open) + "(" + first + ")";
            }
        }
        return shortened(text);
    }

    /** `16.0.dp` → `16dp`, `CornerSize(size = 50.0%)` → `50%`. */
    private static String tidy(String text) {
        return text
            .replaceAll("CornerSize\\(size = ([^)]*)\\)", "$1")
            .replaceAll("(\\d+)\\.0\\.(dp|sp|em|px)", "$1$2")
            .replaceAll("(\\d+\\.\\d+)\\.(dp|sp|em|px)", "$1$2")
            .replaceAll("(\\d+)\\.0(%|px)", "$1$2");
    }

    private static String shortened(String text) {
        if (text == null) return null;
        return text.length() <= MAX_VALUE ? text : text.substring(0, MAX_VALUE - 1) + "…";
    }

    static String simpleName(Class<?> type) {
        String name = type.getName();
        name = name.substring(name.lastIndexOf('.') + 1);
        int slash = name.indexOf('/');
        return slash >= 0 ? name.substring(0, slash) : name;
    }

    // MARK: Colors

    /** Compose's packed `Color` to an Android ARGB int. */
    static final class Colors {
        private Colors() {}

        private static Method toArgb;
        private static boolean searched;

        /** Null for anything that is not a color, and for `Color.Unspecified`. */
        static Integer argb(Object packed, View host) {
            if (!(packed instanceof Long)) return null;
            long color = (Long) packed;
            // sRGB, the color space of nearly every color: 8 bits a channel in the upper half.
            if ((color & 0x3FL) == 0) return (int) (color >>> 32);
            if (color == 16L) return null;
            try {
                if (!searched) {
                    searched = true;
                    Class<?> type = Reflect.classOrNull("androidx.compose.ui.graphics.ColorKt", host.getClass().getClassLoader());
                    if (type != null) {
                        for (Method method : type.getMethods()) {
                            Class<?>[] types = method.getParameterTypes();
                            if (method.getName().startsWith("toArgb") && types.length == 1 && types[0] == long.class) {
                                toArgb = method;
                                break;
                            }
                        }
                    }
                }
                Object converted = toArgb == null ? null : toArgb.invoke(null, color);
                return converted instanceof Integer ? (Integer) converted : null;
            } catch (Throwable e) {
                return null;
            }
        }
    }
}
