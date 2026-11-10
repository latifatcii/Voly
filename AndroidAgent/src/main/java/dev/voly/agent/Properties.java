package dev.voly.agent;

import android.graphics.Typeface;
import android.os.Build;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.CompoundButton;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * A view's properties as the host lists them (`PropertyBag`) and the other
 * direction: applying a change to one of them.
 *
 * The bag has the host's three groups. "view" and "layer" keep the names
 * the two platforms share (alpha, isHidden, backgroundColor, cornerRadius,
 * …); everything Android-specific — layout params, padding, text — is in
 * "custom", under the names an Android developer knows it by. Lengths are
 * in dp, text sizes in sp.
 */
final class Properties {
    private final ObjectRegistry registry;

    Properties(ObjectRegistry registry) {
        this.registry = registry;
    }

    private View view(long id) throws AgentError {
        Object object = registry.objectFor(id);
        if (!(object instanceof View)) throw AgentError.objectGone(id);
        return (View) object;
    }

    // MARK: Reading

    JSONObject bag(long id) throws AgentError {
        View view = view(id);
        float density = Ui.density();

        JSONObject viewGroup = Json.object();
        Json.put(viewGroup, "alpha", Json.prop((double) view.getAlpha()));
        Json.put(viewGroup, "isHidden", Json.prop(view.getVisibility() != View.VISIBLE));
        Json.put(viewGroup, "isEnabled", Json.prop(view.isEnabled()));
        Json.put(viewGroup, "clipsToBounds", Json.prop(Snapshots.clipsToBounds(view)));
        Json.put(viewGroup, "backgroundColor", Json.propColor(Style.backgroundColor(view)));
        Json.put(viewGroup, "tintColor", Json.propColor(Style.tintColor(view)));

        JSONObject layer = Json.object();
        Style.Border border = Style.border(view);
        Json.put(layer, "cornerRadius", Json.prop((double) (Style.cornerRadius(view) / density)));
        Json.put(layer, "borderWidth", Json.prop(border != null ? (double) (border.width / density) : 0.0));
        Json.put(layer, "borderColor", Json.propColor(border != null ? border.color : null));
        Json.put(layer, "elevation", Json.prop((double) (view.getElevation() / density)));
        Json.put(layer, "masksToBounds", Json.prop(view.getClipToOutline()));

        JSONArray custom = new JSONArray();
        for (Entry entry : entries(view)) custom.put(entry.toJson());

        JSONObject bag = Json.object();
        Json.put(bag, "objectID", id);
        Json.put(bag, "view", viewGroup);
        Json.put(bag, "layer", layer);
        Json.put(bag, "custom", custom);
        return bag;
    }

    /** One row of the "custom" group: `CustomPropDescriptor`. */
    private static final class Entry {
        final String name;
        final String type;
        final boolean readOnly;
        final String source;
        final JSONObject value;

        Entry(String name, String type, boolean readOnly, String source, JSONObject value) {
            this.name = name;
            this.type = type;
            this.readOnly = readOnly;
            this.source = source;
            this.value = value;
        }

        JSONObject toJson() {
            JSONObject json = Json.object();
            Json.put(json, "name", name);
            Json.put(json, "declaredType", type);
            Json.put(json, "isReadOnly", readOnly);
            Json.put(json, "source", source);
            Json.put(json, "currentValue", value);
            return json;
        }
    }

    private static Entry string(String name, CharSequence value, boolean readOnly) {
        return new Entry(name, "string", readOnly, "registered", Json.prop(value == null ? null : value.toString()));
    }

    private static Entry number(String name, double value) {
        return new Entry(name, "double", false, "registered", Json.prop(value));
    }

    private static Entry integer(String name, long value) {
        return new Entry(name, "int", false, "registered", Json.prop(value));
    }

    private static Entry bool(String name, boolean value) {
        return new Entry(name, "bool", false, "registered", Json.prop(value));
    }

    private List<Entry> entries(View view) {
        float density = Ui.density();
        List<Entry> list = new ArrayList<>();

        // What the view is.
        if (view instanceof TextView) {
            TextView text = (TextView) view;
            list.add(string("text", text.getText(), false));
            list.add(string("hint", text.getHint(), false));
            list.add(number("textSize", textSizeSp(text)));
            list.add(new Entry("textColor", "color", false, "registered", Json.propColor(text.getCurrentTextColor())));
            list.add(integer("maxLines", text.getMaxLines() == Integer.MAX_VALUE ? 0 : text.getMaxLines()));
            list.add(string("gravity", gravity(text.getGravity()), true));
            list.add(string("ellipsize", text.getEllipsize() == null ? "none" : text.getEllipsize().name().toLowerCase(Locale.US), true));
            list.add(string("typeface", typeface(text.getTypeface()), true));
            list.add(number("letterSpacing", text.getLetterSpacing()));
            if (Build.VERSION.SDK_INT >= 28) list.add(bool("isAllCaps", text.isAllCaps()));
            list.add(bool("includeFontPadding", text.getIncludeFontPadding()));
        }
        if (view instanceof ImageView) {
            list.add(string("scaleType", scaleTypeName(((ImageView) view).getScaleType()), false));
        }
        if (view instanceof CompoundButton) {
            list.add(bool("isChecked", ((CompoundButton) view).isChecked()));
        }
        if (view instanceof ProgressBar) {
            ProgressBar bar = (ProgressBar) view;
            list.add(integer("progress", bar.getProgress()));
            list.add(integer("max", bar.getMax()));
        }
        if (view instanceof LinearLayout) {
            LinearLayout layout = (LinearLayout) view;
            list.add(string("orientation", layout.getOrientation() == LinearLayout.VERTICAL ? "vertical" : "horizontal", false));
        }
        if (view instanceof ViewGroup) {
            list.add(bool("clipToPadding", ((ViewGroup) view).getClipToPadding()));
        }
        list.addAll(beanProperties(view));

        // How it is laid out.
        list.add(string("visibility", visibilityName(view.getVisibility()), false));
        ViewGroup.LayoutParams params = view.getLayoutParams();
        if (params != null) {
            list.add(string("layout_width", dimension(params.width, density), false));
            list.add(string("layout_height", dimension(params.height, density), false));
            if (params instanceof ViewGroup.MarginLayoutParams) {
                ViewGroup.MarginLayoutParams margins = (ViewGroup.MarginLayoutParams) params;
                list.add(number("marginLeft", margins.leftMargin / density));
                list.add(number("marginTop", margins.topMargin / density));
                list.add(number("marginRight", margins.rightMargin / density));
                list.add(number("marginBottom", margins.bottomMargin / density));
            }
            if (params instanceof LinearLayout.LayoutParams) {
                LinearLayout.LayoutParams linear = (LinearLayout.LayoutParams) params;
                list.add(number("layout_weight", linear.weight));
                list.add(string("layout_gravity", gravity(linear.gravity), true));
            } else if (params instanceof android.widget.FrameLayout.LayoutParams) {
                list.add(string("layout_gravity", gravity(((android.widget.FrameLayout.LayoutParams) params).gravity), true));
            }
            if (LayoutConstraints.isConstraintParams(params)) {
                Object horizontal = Reflect.field(params, "horizontalBias");
                Object vertical = Reflect.field(params, "verticalBias");
                if (horizontal instanceof Float) list.add(number("layout_constraintHorizontal_bias", (Float) horizontal));
                if (vertical instanceof Float) list.add(number("layout_constraintVertical_bias", (Float) vertical));
                Object ratio = Reflect.field(params, "dimensionRatio");
                if (ratio instanceof String) list.add(string("layout_constraintDimensionRatio", (String) ratio, true));
            }
        }
        list.add(number("paddingLeft", view.getPaddingLeft() / density));
        list.add(number("paddingTop", view.getPaddingTop() / density));
        list.add(number("paddingRight", view.getPaddingRight() / density));
        list.add(number("paddingBottom", view.getPaddingBottom() / density));
        list.add(number("translationX", view.getTranslationX() / density));
        list.add(number("translationY", view.getTranslationY() / density));
        list.add(number("rotation", view.getRotation()));
        list.add(number("scaleX", view.getScaleX()));
        list.add(number("scaleY", view.getScaleY()));
        list.add(bool("isClickable", view.isClickable()));
        list.add(bool("isSelected", view.isSelected()));
        list.add(string("contentDescription", view.getContentDescription(), false));
        String resource = Snapshots.resourceName(view);
        if (resource != null) list.add(string("resourceId", "@id/" + resource, true));
        return list;
    }

    static String visibilityName(int visibility) {
        switch (visibility) {
            case View.VISIBLE: return "visible";
            case View.INVISIBLE: return "invisible";
            default: return "gone";
        }
    }

    /** `match_parent`, `wrap_content` or a length in dp. */
    static String dimension(int value, float density) {
        if (value == ViewGroup.LayoutParams.MATCH_PARENT) return "match_parent";
        if (value == ViewGroup.LayoutParams.WRAP_CONTENT) return "wrap_content";
        return trim(value / density) + "dp";
    }

    static String trim(double value) {
        double rounded = Math.round(value * 100) / 100.0;
        if (rounded == Math.rint(rounded)) return String.valueOf((long) rounded);
        return String.valueOf(rounded);
    }

    static String gravity(int gravity) {
        if (gravity == Gravity.NO_GRAVITY || gravity == -1) return "none";
        List<String> parts = new ArrayList<>();
        int horizontal = gravity & Gravity.RELATIVE_HORIZONTAL_GRAVITY_MASK;
        int vertical = gravity & Gravity.VERTICAL_GRAVITY_MASK;
        if (vertical == Gravity.CENTER_VERTICAL && (horizontal & Gravity.HORIZONTAL_GRAVITY_MASK) == Gravity.CENTER_HORIZONTAL) {
            return "center";
        }
        switch (vertical) {
            case Gravity.TOP: parts.add("top"); break;
            case Gravity.BOTTOM: parts.add("bottom"); break;
            case Gravity.CENTER_VERTICAL: parts.add("center_vertical"); break;
            case Gravity.FILL_VERTICAL: parts.add("fill_vertical"); break;
            default: break;
        }
        if ((horizontal & Gravity.RELATIVE_LAYOUT_DIRECTION) != 0) {
            int side = horizontal & ~Gravity.RELATIVE_LAYOUT_DIRECTION;
            if (side == Gravity.LEFT) parts.add("start");
            else if (side == Gravity.RIGHT) parts.add("end");
            else if (side == Gravity.CENTER_HORIZONTAL) parts.add("center_horizontal");
            else if (side == Gravity.FILL_HORIZONTAL) parts.add("fill_horizontal");
        } else {
            switch (horizontal & Gravity.HORIZONTAL_GRAVITY_MASK) {
                case Gravity.LEFT: parts.add("left"); break;
                case Gravity.RIGHT: parts.add("right"); break;
                case Gravity.CENTER_HORIZONTAL: parts.add("center_horizontal"); break;
                case Gravity.FILL_HORIZONTAL: parts.add("fill_horizontal"); break;
                default: break;
            }
        }
        return parts.isEmpty() ? "none" : TextUtils.join("|", parts);
    }

    /** `sans-serif Medium`, `monospace Bold Italic`, `sans-serif-condensed`, … */
    static String typeface(Typeface typeface) {
        if (typeface == null) typeface = Typeface.DEFAULT;
        String italic = typeface.isItalic() ? " Italic" : "";
        String family;
        if (typeface.equals(Typeface.MONOSPACE)) family = "monospace";
        else if (typeface.equals(Typeface.SERIF)) family = "serif";
        else family = "sans-serif";
        if (Build.VERSION.SDK_INT >= 34) {
            try {
                String system = typeface.getSystemFontFamilyName();
                // A name like sans-serif-medium already says its weight.
                if (system != null && system.indexOf('-', "sans-serif".length()) > 0) return system + italic;
                if (system != null && !system.isEmpty()) family = system;
            } catch (Throwable ignored) {
            }
        }
        String weight;
        int value = Build.VERSION.SDK_INT >= 28 ? typeface.getWeight() : (typeface.isBold() ? 700 : 400);
        if (value <= 150) weight = "Thin";
        else if (value <= 250) weight = "ExtraLight";
        else if (value <= 350) weight = "Light";
        else if (value <= 450) weight = "Regular";
        else if (value <= 550) weight = "Medium";
        else if (value <= 650) weight = "SemiBold";
        else if (value <= 750) weight = "Bold";
        else if (value <= 850) weight = "ExtraBold";
        else weight = "Black";
        return family + " " + weight + italic;
    }

    /**
     * A text size in sp. Sizes are stored in whole pixels, so 22sp reads
     * back as 22.18 on a 2.75x screen; a value that close to a whole or
     * half sp is that sp.
     */
    static double textSizeSp(android.widget.TextView text) {
        double sp = text.getTextSize() / text.getResources().getDisplayMetrics().scaledDensity;
        double half = Math.rint(sp * 2) / 2;
        double onePixel = 1.0 / text.getResources().getDisplayMetrics().scaledDensity;
        return Math.abs(sp - half) <= onePixel * 0.75 ? half : Math.rint(sp * 10) / 10;
    }

    static String scaleTypeName(ImageView.ScaleType type) {
        switch (type) {
            case MATRIX: return "matrix";
            case FIT_XY: return "fitXY";
            case FIT_START: return "fitStart";
            case FIT_CENTER: return "fitCenter";
            case FIT_END: return "fitEnd";
            case CENTER: return "center";
            case CENTER_CROP: return "centerCrop";
            case CENTER_INSIDE: return "centerInside";
            default: return type.name();
        }
    }

    // MARK: Properties of the app's own view classes

    /**
     * Getter/setter pairs declared by app-defined view classes — the
     * counterpart of reading a custom UIView's properties off the
     * Objective-C runtime.
     */
    private List<Entry> beanProperties(View view) {
        List<Entry> list = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        for (Class<?> type = view.getClass(); Classes.isAppDefined(type) && list.size() < 40; type = type.getSuperclass()) {
            Method[] methods;
            try {
                methods = type.getDeclaredMethods();
            } catch (Throwable e) {
                continue;
            }
            for (Method getter : methods) {
                String name = beanName(getter);
                if (name == null || !seen.add(name)) continue;
                Class<?> valueType = getter.getReturnType();
                String declared = declaredType(name, valueType);
                if (declared == null) continue;
                Object value;
                try {
                    getter.setAccessible(true);
                    value = getter.invoke(view);
                } catch (Throwable e) {
                    continue;
                }
                boolean readOnly = setter(view.getClass(), name, valueType) == null;
                list.add(new Entry(name, declared, readOnly, "runtimeObjC", propValue(declared, value)));
                if (list.size() >= 40) break;
            }
        }
        return list;
    }

    /** `getBadgeText` → `badgeText`, `isRound` → `isRound`; null for anything else. */
    private static String beanName(Method method) {
        int modifiers = method.getModifiers();
        if (!Modifier.isPublic(modifiers) || Modifier.isStatic(modifiers) || method.getParameterTypes().length != 0
            || method.isSynthetic()) {
            return null;
        }
        String name = method.getName();
        if (name.startsWith("get") && name.length() > 3 && Character.isUpperCase(name.charAt(3))) {
            return Character.toLowerCase(name.charAt(3)) + name.substring(4);
        }
        if (name.startsWith("is") && name.length() > 2 && Character.isUpperCase(name.charAt(2))
            && method.getReturnType() == boolean.class) {
            return name;
        }
        return null;
    }

    private static Method setter(Class<?> type, String name, Class<?> valueType) {
        String base = name.startsWith("is") && name.length() > 2 && Character.isUpperCase(name.charAt(2))
            ? name.substring(2)
            : Character.toUpperCase(name.charAt(0)) + name.substring(1);
        return Reflect.method(type, "set" + base, valueType);
    }

    private static String declaredType(String name, Class<?> type) {
        if (type == boolean.class || type == Boolean.class) return "bool";
        if (type == int.class || type == Integer.class) {
            return name.toLowerCase(Locale.US).contains("color") ? "color" : "int";
        }
        if (type == long.class || type == Long.class) return "int";
        if (type == float.class || type == double.class || type == Float.class || type == Double.class) return "double";
        if (type == String.class || type == CharSequence.class) return "string";
        return null;
    }

    private static JSONObject propValue(String declared, Object value) {
        if (value == null) return Json.propNull();
        switch (declared) {
            case "bool": return Json.prop((Boolean) value);
            case "int": return Json.prop(((Number) value).longValue());
            case "color": return Json.propColor(((Number) value).intValue());
            case "double": return Json.prop(((Number) value).doubleValue());
            default: return Json.prop(value.toString());
        }
    }

    // MARK: Writing

    /** Apply a `SetPropertyRequest`. */
    void apply(JSONObject request) throws AgentError {
        long id = request.optLong("objectID");
        View view = view(id);
        String scope = request.optString("scope");
        JSONObject change = request.optJSONObject("change");
        if (change == null) throw AgentError.invalidCommand("setProperty without a change");
        String name = change.optString("property");
        JSONObject value = change.optJSONObject("value");
        if (value == null) throw AgentError.unsupportedValue();
        switch (scope) {
            case "view": applyView(view, name, value); break;
            case "layer": applyLayer(view, name, value); break;
            case "custom": applyCustom(view, name, value); break;
            default: throw AgentError.invalidCommand("unknown scope " + scope);
        }
        view.requestLayout();
        view.invalidate();
    }

    private void applyView(View view, String name, JSONObject value) throws AgentError {
        switch (name) {
            case "alpha": view.setAlpha((float) Json.propDouble(value)); break;
            case "isHidden": view.setVisibility(Json.propBool(value) ? View.INVISIBLE : View.VISIBLE); break;
            case "isEnabled":
            case "isUserInteractionEnabled": view.setEnabled(Json.propBool(value)); break;
            case "clipsToBounds":
                if (view instanceof ViewGroup) ((ViewGroup) view).setClipChildren(Json.propBool(value));
                else view.setClipToOutline(Json.propBool(value));
                break;
            case "backgroundColor": Style.setBackgroundColor(view, Json.propColorOrNull(value)); break;
            case "tintColor": Style.setTintColor(view, Json.propColorOrNull(value)); break;
            default: throw AgentError.unsupportedProperty(name);
        }
    }

    private void applyLayer(View view, String name, JSONObject value) throws AgentError {
        float density = Ui.density();
        switch (name) {
            case "cornerRadius": Style.setCornerRadius(view, (float) Json.propDouble(value) * density); break;
            case "borderWidth": Style.setBorder(view, (float) Json.propDouble(value) * density, null); break;
            case "borderColor": {
                Integer color = Json.propColorOrNull(value);
                if (color == null) Style.setBorder(view, 0f, null);
                else Style.setBorder(view, Style.border(view) == null ? density : null, color);
                break;
            }
            case "elevation":
            case "shadowRadius": view.setElevation((float) Json.propDouble(value) * density); break;
            case "masksToBounds": view.setClipToOutline(Json.propBool(value)); break;
            case "opacity": view.setAlpha((float) Json.propDouble(value)); break;
            default: throw AgentError.unsupportedProperty(name);
        }
    }

    private void applyCustom(View view, String name, JSONObject value) throws AgentError {
        float density = Ui.density();
        ViewGroup.LayoutParams params = view.getLayoutParams();
        switch (name) {
            case "visibility": {
                String wanted = Json.propString(value).trim().toLowerCase(Locale.US);
                if (wanted.equals("visible")) view.setVisibility(View.VISIBLE);
                else if (wanted.equals("invisible")) view.setVisibility(View.INVISIBLE);
                else if (wanted.equals("gone")) view.setVisibility(View.GONE);
                else throw AgentError.unsupportedValue();
                return;
            }
            case "layout_width":
            case "layout_height": {
                if (params == null) throw AgentError.unsupportedProperty(name);
                int size = parseDimension(value, density);
                if (name.equals("layout_width")) params.width = size;
                else params.height = size;
                view.setLayoutParams(params);
                return;
            }
            case "marginLeft":
            case "marginTop":
            case "marginRight":
            case "marginBottom": {
                if (!(params instanceof ViewGroup.MarginLayoutParams)) throw AgentError.unsupportedProperty(name);
                ViewGroup.MarginLayoutParams margins = (ViewGroup.MarginLayoutParams) params;
                int size = Math.round((float) Json.propDouble(value) * density);
                if (name.equals("marginLeft")) margins.leftMargin = size;
                else if (name.equals("marginTop")) margins.topMargin = size;
                else if (name.equals("marginRight")) margins.rightMargin = size;
                else margins.bottomMargin = size;
                view.setLayoutParams(params);
                return;
            }
            case "layout_weight": {
                if (!(params instanceof LinearLayout.LayoutParams)) throw AgentError.unsupportedProperty(name);
                ((LinearLayout.LayoutParams) params).weight = (float) Json.propDouble(value);
                view.setLayoutParams(params);
                return;
            }
            case "layout_constraintHorizontal_bias":
            case "layout_constraintVertical_bias": {
                if (!LayoutConstraints.isConstraintParams(params)) throw AgentError.unsupportedProperty(name);
                String field = name.contains("Horizontal") ? "horizontalBias" : "verticalBias";
                try {
                    Reflect.field(params.getClass(), field).setFloat(params, (float) Json.propDouble(value));
                } catch (AgentError e) {
                    throw e;
                } catch (Throwable e) {
                    throw AgentError.unsupportedProperty(name);
                }
                view.setLayoutParams(params);
                return;
            }
            case "paddingLeft":
            case "paddingTop":
            case "paddingRight":
            case "paddingBottom": {
                int size = Math.round((float) Json.propDouble(value) * density);
                view.setPadding(
                    name.equals("paddingLeft") ? size : view.getPaddingLeft(),
                    name.equals("paddingTop") ? size : view.getPaddingTop(),
                    name.equals("paddingRight") ? size : view.getPaddingRight(),
                    name.equals("paddingBottom") ? size : view.getPaddingBottom());
                return;
            }
            case "translationX": view.setTranslationX((float) Json.propDouble(value) * density); return;
            case "translationY": view.setTranslationY((float) Json.propDouble(value) * density); return;
            case "rotation": view.setRotation((float) Json.propDouble(value)); return;
            case "scaleX": view.setScaleX((float) Json.propDouble(value)); return;
            case "scaleY": view.setScaleY((float) Json.propDouble(value)); return;
            case "isClickable": view.setClickable(Json.propBool(value)); return;
            case "isSelected": view.setSelected(Json.propBool(value)); return;
            case "contentDescription": view.setContentDescription(Json.isNull(value) ? null : Json.propString(value)); return;
            default: break;
        }

        if (view instanceof TextView) {
            TextView text = (TextView) view;
            switch (name) {
                case "text": text.setText(Json.isNull(value) ? "" : Json.propString(value)); return;
                case "hint": text.setHint(Json.isNull(value) ? null : Json.propString(value)); return;
                case "textSize": text.setTextSize(TypedValue.COMPLEX_UNIT_SP, (float) Json.propDouble(value)); return;
                case "textColor": {
                    Integer color = Json.propColorOrNull(value);
                    if (color == null) throw AgentError.unsupportedValue();
                    text.setTextColor(color);
                    return;
                }
                case "maxLines": {
                    long lines = Json.propLong(value);
                    text.setMaxLines(lines <= 0 ? Integer.MAX_VALUE : (int) lines);
                    return;
                }
                case "letterSpacing": text.setLetterSpacing((float) Json.propDouble(value)); return;
                case "isAllCaps": text.setAllCaps(Json.propBool(value)); return;
                case "includeFontPadding": text.setIncludeFontPadding(Json.propBool(value)); return;
                default: break;
            }
        }
        if (view instanceof ImageView && name.equals("scaleType")) {
            String wanted = Json.propString(value).replace("_", "");
            for (ImageView.ScaleType type : ImageView.ScaleType.values()) {
                if (scaleTypeName(type).equalsIgnoreCase(wanted) || type.name().replace("_", "").equalsIgnoreCase(wanted)) {
                    ((ImageView) view).setScaleType(type);
                    return;
                }
            }
            throw AgentError.unsupportedValue();
        }
        if (view instanceof CompoundButton && name.equals("isChecked")) {
            ((CompoundButton) view).setChecked(Json.propBool(value));
            return;
        }
        if (view instanceof ProgressBar) {
            if (name.equals("progress")) {
                ((ProgressBar) view).setProgress((int) Json.propLong(value));
                return;
            }
            if (name.equals("max")) {
                ((ProgressBar) view).setMax((int) Json.propLong(value));
                return;
            }
        }
        if (view instanceof LinearLayout && name.equals("orientation")) {
            String wanted = Json.propString(value).trim().toLowerCase(Locale.US);
            if (!wanted.equals("vertical") && !wanted.equals("horizontal")) throw AgentError.unsupportedValue();
            ((LinearLayout) view).setOrientation(wanted.equals("vertical") ? LinearLayout.VERTICAL : LinearLayout.HORIZONTAL);
            return;
        }
        if (view instanceof ViewGroup && name.equals("clipToPadding")) {
            ((ViewGroup) view).setClipToPadding(Json.propBool(value));
            return;
        }
        applyBean(view, name, value);
    }

    private static int parseDimension(JSONObject value, float density) throws AgentError {
        String kind = Json.caseName(value);
        if (kind.equals("double") || kind.equals("int")) return Math.round((float) Json.propDouble(value) * density);
        String text = Json.propString(value).trim().toLowerCase(Locale.US);
        if (text.equals("match_parent") || text.equals("fill_parent")) return ViewGroup.LayoutParams.MATCH_PARENT;
        if (text.equals("wrap_content")) return ViewGroup.LayoutParams.WRAP_CONTENT;
        if (text.endsWith("dp")) text = text.substring(0, text.length() - 2).trim();
        try {
            return Math.round(Float.parseFloat(text) * density);
        } catch (NumberFormatException e) {
            throw AgentError.unsupportedValue();
        }
    }

    private void applyBean(View view, String name, JSONObject value) throws AgentError {
        for (Class<?> type = view.getClass(); Classes.isAppDefined(type); type = type.getSuperclass()) {
            for (Method getter : type.getDeclaredMethods()) {
                if (!name.equals(beanName(getter))) continue;
                Class<?> valueType = getter.getReturnType();
                Method setter = setter(view.getClass(), name, valueType);
                String declared = declaredType(name, valueType);
                if (setter == null || declared == null) throw AgentError.unsupportedProperty(name);
                Object converted;
                switch (declared) {
                    case "bool": converted = Json.propBool(value); break;
                    case "color": {
                        Integer color = Json.propColorOrNull(value);
                        if (color == null) throw AgentError.unsupportedValue();
                        converted = color;
                        break;
                    }
                    case "int":
                        converted = valueType == long.class || valueType == Long.class
                            ? (Object) Json.propLong(value) : (Object) (int) Json.propLong(value);
                        break;
                    case "double":
                        converted = valueType == float.class || valueType == Float.class
                            ? (Object) (float) Json.propDouble(value) : (Object) Json.propDouble(value);
                        break;
                    default:
                        converted = Json.isNull(value) ? null : Json.propString(value);
                        break;
                }
                try {
                    setter.invoke(view, converted);
                } catch (Throwable e) {
                    throw AgentError.internal("Setting " + name + " failed: " + e);
                }
                return;
            }
        }
        throw AgentError.unsupportedProperty(name);
    }
}
