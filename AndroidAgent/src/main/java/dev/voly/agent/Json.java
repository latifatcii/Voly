package dev.voly.agent;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.text.SimpleDateFormat;
import java.util.Collection;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;

/**
 * JSON in the exact shapes the host's Swift `Codable` types expect.
 *
 * The protocol is whatever Swift synthesizes for the types in
 * `Packages/VolyCore/Sources/VolyModels` and `VolyProtocol`:
 * an enum case is `{"caseName":{"label":value}}` (unlabeled values are
 * `_0`, `_1`), a case without values is `{"caseName":{}}`, raw-value enums
 * are their raw string, optionals are simply left out, `Data` is base64 and
 * `Date` is ISO 8601 without fractional seconds.
 */
final class Json {
    private Json() {}

    static JSONObject object() {
        return new JSONObject();
    }

    /** `{"name":{}}` */
    static JSONObject enumCase(String name) {
        return put(new JSONObject(), name, new JSONObject());
    }

    /** `{"name":{"_0":value}}` */
    static JSONObject enumCase(String name, Object value) {
        return put(new JSONObject(), name, put(new JSONObject(), "_0", value));
    }

    /** `{"name":{…labeled values…}}` */
    static JSONObject enumCaseLabeled(String name, JSONObject values) {
        return put(new JSONObject(), name, values);
    }

    /**
     * `put` that never throws and never writes a non-finite number: the
     * host decodes those from the strings "nan", "+inf" and "-inf" (see
     * `Framing` on the Swift side).
     */
    static JSONObject put(JSONObject object, String key, Object value) {
        try {
            if (value == null) return object;
            if (value instanceof Float) value = ((Float) value).doubleValue();
            if (value instanceof Double) {
                object.put(key, number((Double) value));
            } else {
                object.put(key, value);
            }
        } catch (JSONException e) {
            throw new IllegalStateException(e);
        }
        return object;
    }

    static Object number(double value) {
        if (Double.isNaN(value)) return "nan";
        if (Double.isInfinite(value)) return value > 0 ? "+inf" : "-inf";
        return value;
    }

    static JSONArray array(Collection<?> values) {
        JSONArray array = new JSONArray();
        for (Object value : values) array.put(value);
        return array;
    }

    static JSONArray strings(String... values) {
        JSONArray array = new JSONArray();
        for (String value : values) array.put(value);
        return array;
    }

    static String iso8601(Date date) {
        SimpleDateFormat format = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US);
        format.setTimeZone(TimeZone.getTimeZone("UTC"));
        return format.format(date);
    }

    // MARK: Geometry (in points, i.e. dp)

    static JSONObject rect(double x, double y, double width, double height) {
        JSONObject object = new JSONObject();
        put(object, "x", x);
        put(object, "y", y);
        put(object, "width", width);
        put(object, "height", height);
        return object;
    }

    static JSONObject point(double x, double y) {
        return put(put(new JSONObject(), "x", x), "y", y);
    }

    static JSONObject size(double width, double height) {
        return put(put(new JSONObject(), "width", width), "height", height);
    }

    static JSONObject insets(double top, double left, double bottom, double right) {
        JSONObject object = new JSONObject();
        put(object, "top", top);
        put(object, "left", left);
        put(object, "bottom", bottom);
        put(object, "right", right);
        return object;
    }

    // MARK: Colors

    /** `CGColorCodable` from an Android ARGB int. */
    static JSONObject color(int argb) {
        JSONObject object = new JSONObject();
        put(object, "red", ((argb >> 16) & 0xFF) / 255.0);
        put(object, "green", ((argb >> 8) & 0xFF) / 255.0);
        put(object, "blue", (argb & 0xFF) / 255.0);
        put(object, "alpha", ((argb >>> 24) & 0xFF) / 255.0);
        return object;
    }

    /** `#RRGGBBAA`, the form `CGColorCodable.hex` produces. */
    static String hex(int argb) {
        return String.format(Locale.US, "#%02X%02X%02X%02X",
            (argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF, (argb >>> 24) & 0xFF);
    }

    static int argb(JSONObject color) throws AgentError {
        if (color == null) throw AgentError.unsupportedValue();
        return (channel(color.optDouble("alpha", 1)) << 24)
            | (channel(color.optDouble("red", 0)) << 16)
            | (channel(color.optDouble("green", 0)) << 8)
            | channel(color.optDouble("blue", 0));
    }

    private static int channel(double value) {
        if (Double.isNaN(value)) value = 0;
        return (int) Math.round(Math.max(0, Math.min(1, value)) * 255);
    }

    // MARK: PropValue

    static JSONObject propNull() {
        return enumCase("null");
    }

    static JSONObject prop(boolean value) {
        return enumCase("bool", value);
    }

    static JSONObject prop(long value) {
        return enumCase("int", value);
    }

    static JSONObject prop(double value) {
        return enumCase("double", number(value));
    }

    static JSONObject prop(String value) {
        return value == null ? propNull() : enumCase("string", value);
    }

    static JSONObject propColor(Integer argb) {
        return argb == null ? propNull() : enumCase("color", color(argb));
    }

    static JSONObject propSize(double width, double height) {
        return enumCase("size", size(width, height));
    }

    static JSONObject propArray(JSONArray values) {
        return enumCase("arrayOf", values);
    }

    /** The single case name of an encoded Swift enum. */
    static String caseName(JSONObject encodedEnum) throws AgentError {
        if (encodedEnum == null || encodedEnum.length() != 1) throw AgentError.unsupportedValue();
        return encodedEnum.keys().next();
    }

    /** The unlabeled associated value of an encoded Swift enum. */
    static Object caseValue(JSONObject encodedEnum) throws AgentError {
        JSONObject payload = encodedEnum.optJSONObject(caseName(encodedEnum));
        return payload == null ? null : payload.opt("_0");
    }

    static double propDouble(JSONObject value) throws AgentError {
        String kind = caseName(value);
        Object raw = caseValue(value);
        if (raw instanceof Number && (kind.equals("double") || kind.equals("int"))) return ((Number) raw).doubleValue();
        if (raw instanceof Boolean && kind.equals("bool")) return ((Boolean) raw) ? 1 : 0;
        if (raw instanceof String && kind.equals("double")) return nonFinite((String) raw);
        throw AgentError.unsupportedValue();
    }

    private static double nonFinite(String text) throws AgentError {
        switch (text) {
            case "nan": return Double.NaN;
            case "+inf": return Double.POSITIVE_INFINITY;
            case "-inf": return Double.NEGATIVE_INFINITY;
            default: throw AgentError.unsupportedValue();
        }
    }

    static long propLong(JSONObject value) throws AgentError {
        // A whole number as it was sent: a double holds only 53 bits of it.
        Object raw = caseValue(value);
        if (caseName(value).equals("int") && (raw instanceof Long || raw instanceof Integer)) {
            return ((Number) raw).longValue();
        }
        double number = propDouble(value);
        if (Double.isNaN(number) || Double.isInfinite(number)) throw AgentError.unsupportedValue();
        return (long) number;
    }

    static boolean propBool(JSONObject value) throws AgentError {
        String kind = caseName(value);
        Object raw = caseValue(value);
        if (raw instanceof Boolean && kind.equals("bool")) return (Boolean) raw;
        if (raw instanceof Number && (kind.equals("int") || kind.equals("double"))) return ((Number) raw).doubleValue() != 0;
        throw AgentError.unsupportedValue();
    }

    static String propString(JSONObject value) throws AgentError {
        Object raw = caseValue(value);
        if (raw instanceof String && caseName(value).equals("string")) return (String) raw;
        throw AgentError.unsupportedValue();
    }

    /** Null for `.null`; throws for anything that is not a color. */
    static Integer propColorOrNull(JSONObject value) throws AgentError {
        String kind = caseName(value);
        if (kind.equals("null")) return null;
        Object raw = caseValue(value);
        if (raw instanceof JSONObject && kind.equals("color")) return argb((JSONObject) raw);
        throw AgentError.unsupportedValue();
    }

    static boolean isNull(JSONObject value) {
        return value != null && value.has("null");
    }
}
