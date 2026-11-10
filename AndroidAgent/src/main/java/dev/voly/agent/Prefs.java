package dev.voly.agent;

import android.app.Application;
import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;

/**
 * SharedPreferences, in the place UserDefaults has on iOS. A "suite" is a
 * preferences file (its name without `.xml`); without one, every file is
 * listed and a write goes to the file that already has the key, else to the
 * default file (`<package>_preferences`).
 *
 * Values are read and written through the app's own SharedPreferences
 * instances, so the app sees a change right away and its listeners fire.
 */
final class Prefs {
    private Prefs() {}

    private static Application app() throws AgentError {
        Application app = Ui.application();
        if (app == null) throw AgentError.unavailable("The app has no Application object yet.");
        return app;
    }

    static String defaultSuite(Context context) {
        return context.getPackageName() + "_preferences";
    }

    static List<String> suites(Context context) {
        List<String> names = new ArrayList<>();
        File directory = new File(context.getApplicationInfo().dataDir, "shared_prefs");
        String[] files = directory.list();
        if (files != null) {
            Arrays.sort(files);
            for (String file : files) {
                if (file.endsWith(".xml")) names.add(file.substring(0, file.length() - 4));
            }
        }
        return names;
    }

    /** `[UserDefaultsItem]` */
    static JSONArray list(String suite) throws AgentError {
        Application app = app();
        List<String> suites = new ArrayList<>();
        if (suite != null && !suite.isEmpty()) suites.add(suite);
        else suites.addAll(suites(app));
        JSONArray items = new JSONArray();
        for (String name : suites) {
            Map<String, ?> all;
            try {
                all = app.getSharedPreferences(name, Context.MODE_PRIVATE).getAll();
            } catch (Throwable e) {
                continue;
            }
            for (String key : new TreeSet<>(all.keySet())) {
                Object value = all.get(key);
                String type;
                JSONObject encoded;
                if (value instanceof Boolean) {
                    type = "bool";
                    encoded = Json.prop((Boolean) value);
                } else if (value instanceof Integer || value instanceof Long) {
                    type = "int";
                    encoded = Json.prop(((Number) value).longValue());
                } else if (value instanceof Float) {
                    type = "double";
                    // Through the decimal text, so 0.1f doesn't read 0.10000000149.
                    encoded = Json.prop(Double.parseDouble(value.toString()));
                } else if (value instanceof Set) {
                    type = "array";
                    JSONArray values = new JSONArray();
                    for (Object member : new TreeSet<Object>((Set<?>) value)) values.put(Json.prop(String.valueOf(member)));
                    encoded = Json.propArray(values);
                } else if (value != null) {
                    type = "string";
                    encoded = Json.prop(value.toString());
                } else {
                    continue;
                }
                JSONObject item = Json.object();
                Json.put(item, "id", name + "::" + key);
                Json.put(item, "suite", name);
                Json.put(item, "key", key);
                Json.put(item, "type", type);
                Json.put(item, "value", encoded);
                items.put(item);
            }
        }
        return items;
    }

    /** The file a key lives in when no suite is named. */
    private static String resolveSuite(Application app, String suite, String key) {
        if (suite != null && !suite.isEmpty()) return suite;
        String fallback = defaultSuite(app);
        for (String name : suites(app)) {
            if (app.getSharedPreferences(name, Context.MODE_PRIVATE).contains(key)) return name;
        }
        return fallback;
    }

    /** Apply a `UserDefaultsSetRequest`. */
    static void set(JSONObject request) throws AgentError {
        Application app = app();
        String key = request.optString("key", "");
        if (key.isEmpty()) throw AgentError.invalidCommand("A key is required.");
        JSONObject value = request.optJSONObject("value");
        if (value == null) throw AgentError.unsupportedValue();
        String suite = resolveSuite(app, request.isNull("suite") ? null : request.optString("suite", null), key);
        SharedPreferences preferences = app.getSharedPreferences(suite, Context.MODE_PRIVATE);
        Object existing = preferences.getAll().get(key);
        SharedPreferences.Editor editor = preferences.edit();
        if (Json.isNull(value)) {
            editor.remove(key);
        } else if (existing == null) {
            putNew(editor, key, value);
        } else {
            putKeepingType(editor, key, existing, value);
        }
        editor.apply();
    }

    /** A key the app hasn't stored yet takes the type of the value sent. */
    private static void putNew(SharedPreferences.Editor editor, String key, JSONObject value) throws AgentError {
        switch (Json.caseName(value)) {
            case "bool":
                editor.putBoolean(key, Json.propBool(value));
                break;
            case "int": {
                long number = Json.propLong(value);
                if (number > Integer.MAX_VALUE || number < Integer.MIN_VALUE) editor.putLong(key, number);
                else editor.putInt(key, (int) number);
                break;
            }
            case "double":
                editor.putFloat(key, (float) Json.propDouble(value));
                break;
            case "string":
                editor.putString(key, Json.propString(value));
                break;
            default:
                throw AgentError.unsupportedValue();
        }
    }

    /**
     * A key that exists keeps its type: the app reads it with `getString`,
     * `getInt` and so on, and those throw on any other type — for good,
     * since the value is saved. What can't be stored as that type is refused.
     */
    private static void putKeepingType(SharedPreferences.Editor editor, String key, Object existing, JSONObject value)
            throws AgentError {
        String kind = Json.caseName(value);
        // The host guesses a type from what was typed: `true` and `12` arrive as a boolean and a number.
        String text;
        switch (kind) {
            case "bool": text = String.valueOf(Json.propBool(value)); break;
            case "int": text = String.valueOf(Json.propLong(value)); break;
            case "double": text = String.valueOf(Json.propDouble(value)); break;
            case "string": text = Json.propString(value); break;
            default: throw AgentError.unsupportedValue();
        }
        if (existing instanceof String) {
            editor.putString(key, text);
        } else if (existing instanceof Boolean) {
            if (text.equals("true") || text.equals("1")) editor.putBoolean(key, true);
            else if (text.equals("false") || text.equals("0")) editor.putBoolean(key, false);
            else throw mismatch(key, "a boolean", "true or false");
        } else if (existing instanceof Integer) {
            Long number = wholeNumber(kind, value, text);
            if (number == null || number > Integer.MAX_VALUE || number < Integer.MIN_VALUE) {
                throw mismatch(key, "an int", "a whole number that fits in 32 bits");
            }
            editor.putInt(key, (int) (long) number);
        } else if (existing instanceof Long) {
            Long number = wholeNumber(kind, value, text);
            if (number == null) throw mismatch(key, "a long", "a whole number");
            editor.putLong(key, number);
        } else if (existing instanceof Float) {
            if (kind.equals("bool")) throw mismatch(key, "a float", "a number");
            try {
                editor.putFloat(key, Float.parseFloat(text.trim()));
            } catch (NumberFormatException e) {
                throw mismatch(key, "a float", "a number");
            }
        } else {
            throw AgentError.unavailable("\"" + key + "\" holds a set of strings, which can't be edited from here.");
        }
    }

    /** The value as a whole number, or null when it isn't one. */
    private static Long wholeNumber(String kind, JSONObject value, String text) throws AgentError {
        switch (kind) {
            case "int":
                return Json.propLong(value);
            case "double": {
                double number = Json.propDouble(value);
                return number == Math.rint(number) && Math.abs(number) < 9.2e18 ? (long) number : null;
            }
            case "string":
                try {
                    return Long.parseLong(text.trim());
                } catch (NumberFormatException e) {
                    return null;
                }
            default:
                return null;
        }
    }

    private static AgentError mismatch(String key, String holds, String wants) {
        return AgentError.unavailable(
            "\"" + key + "\" holds " + holds + " and the app reads it as one: give it " + wants + ".");
    }

    static void delete(String suite, String key) throws AgentError {
        Application app = app();
        if (key == null || key.isEmpty()) return;
        app.getSharedPreferences(resolveSuite(app, suite, key), Context.MODE_PRIVATE).edit().remove(key).apply();
    }
}
