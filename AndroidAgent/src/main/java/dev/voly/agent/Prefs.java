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
        String kind = Json.caseName(value);
        switch (kind) {
            case "null":
                editor.remove(key);
                break;
            case "bool":
                editor.putBoolean(key, Json.propBool(value));
                break;
            case "int": {
                // Keep the type the app reads the key with.
                long number = Json.propLong(value);
                if (existing instanceof Long) editor.putLong(key, number);
                else if (existing instanceof Float) editor.putFloat(key, number);
                else if (existing instanceof Boolean && (number == 0 || number == 1)) editor.putBoolean(key, number == 1);
                else if (existing instanceof String) editor.putString(key, String.valueOf(number));
                else if (number > Integer.MAX_VALUE || number < Integer.MIN_VALUE) editor.putLong(key, number);
                else editor.putInt(key, (int) number);
                break;
            }
            case "double": {
                double number = Json.propDouble(value);
                if (existing instanceof Integer && number == Math.rint(number)) editor.putInt(key, (int) number);
                else if (existing instanceof Long && number == Math.rint(number)) editor.putLong(key, (long) number);
                else if (existing instanceof String) editor.putString(key, String.valueOf(number));
                else editor.putFloat(key, (float) number);
                break;
            }
            case "string":
                editor.putString(key, Json.propString(value));
                break;
            default:
                throw AgentError.unsupportedValue();
        }
        editor.apply();
    }

    static void delete(String suite, String key) throws AgentError {
        Application app = app();
        if (key == null || key.isEmpty()) return;
        app.getSharedPreferences(resolveSuite(app, suite, key), Context.MODE_PRIVATE).edit().remove(key).apply();
    }
}
