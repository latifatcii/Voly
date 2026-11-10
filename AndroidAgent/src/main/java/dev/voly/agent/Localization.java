package dev.voly.agent;

import android.app.Activity;
import android.app.Application;
import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.res.Configuration;
import android.content.res.Resources;
import android.os.Build;
import android.os.Bundle;
import android.os.LocaleList;
import android.text.TextUtils;
import android.view.View;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Switching the running app's language, and its layout direction on its
 * own.
 *
 * On Android 13 and later this is the platform's per-app language
 * (`LocaleManager`): the system recreates the app's activities in the new
 * language, and remembers the choice for later launches until it is set
 * back to "system". Earlier versions get the same effect by changing the
 * app's configuration and recreating the activities, for as long as the
 * process lives.
 *
 * A forced layout direction (left-to-right text in a right-to-left layout,
 * or the reverse) is applied to every window's root view and re-applied as
 * activities come and go.
 */
final class Localization implements Application.ActivityLifecycleCallbacks {
    private final Application application;
    /** Language tag set on platforms without per-app languages. */
    private String legacyOverride;
    private String directionMode = "system";
    private boolean lifecycleRegistered;

    Localization(Application application) {
        this.application = application;
    }

    // MARK: State

    /** `LocalizationState` */
    JSONObject state() {
        JSONArray available = new JSONArray();
        for (Map.Entry<String, Locale> entry : availableLocales().entrySet()) {
            Locale locale = entry.getValue();
            JSONObject language = Json.object();
            Json.put(language, "code", entry.getKey());
            Json.put(language, "displayName", capitalize(locale.getDisplayName(Locale.ENGLISH)));
            Json.put(language, "isRightToLeft", TextUtils.getLayoutDirectionFromLocale(locale) == View.LAYOUT_DIRECTION_RTL);
            available.put(language);
        }
        Locale system = Resources.getSystem().getConfiguration().getLocales().get(0);

        JSONObject state = Json.object();
        Json.put(state, "available", available);
        Json.put(state, "systemLanguage", system != null ? system.toLanguageTag() : null);
        Json.put(state, "activeOverride", activeOverride());
        Json.put(state, "layoutDirectionMode", directionMode);
        Json.put(state, "isLayoutRightToLeft", isLayoutRightToLeft());
        Json.put(state, "interceptedLookups", Json.strings(
            Build.VERSION.SDK_INT >= 33 ? "LocaleManager.setApplicationLocales" : "Resources.updateConfiguration"));
        return state;
    }

    private static String capitalize(String text) {
        return text == null || text.isEmpty() ? text : Character.toUpperCase(text.charAt(0)) + text.substring(1);
    }

    private String activeOverride() {
        if (Build.VERSION.SDK_INT >= 33) {
            try {
                android.app.LocaleManager manager = application.getSystemService(android.app.LocaleManager.class);
                LocaleList locales = manager != null ? manager.getApplicationLocales() : null;
                if (locales != null && !locales.isEmpty()) return locales.get(0).toLanguageTag();
            } catch (Throwable ignored) {
            }
            return null;
        }
        return legacyOverride;
    }

    private boolean isLayoutRightToLeft() {
        Activity top = Ui.topActivity();
        if (top != null && top.getWindow() != null && top.getWindow().peekDecorView() != null) {
            return top.getWindow().peekDecorView().getLayoutDirection() == View.LAYOUT_DIRECTION_RTL;
        }
        return application.getResources().getConfiguration().getLayoutDirection() == View.LAYOUT_DIRECTION_RTL;
    }

    /** The languages the app has resources for, by BCP 47 tag. */
    private Map<String, Locale> availableLocales() {
        Map<String, Locale> result = new LinkedHashMap<>();
        // What the app declares (android:localeConfig), when it does.
        if (Build.VERSION.SDK_INT >= 33) {
            try {
                android.app.LocaleConfig config = new android.app.LocaleConfig(application);
                LocaleList declared = config.getSupportedLocales();
                if (declared != null) {
                    for (int index = 0; index < declared.size(); index++) add(result, declared.get(index));
                }
            } catch (Throwable ignored) {
            }
        }
        if (!result.isEmpty()) return result;
        // Otherwise what its resources actually contain, without the platform's own.
        Object tags = Reflect.call(application.getAssets(), "getNonSystemLocales");
        if (tags instanceof String[]) {
            List<String> sorted = new ArrayList<>();
            for (String tag : (String[]) tags) {
                if (tag != null && !tag.isEmpty()) sorted.add(tag);
            }
            java.util.Collections.sort(sorted);
            for (String tag : sorted) add(result, Locale.forLanguageTag(tag));
        }
        return result;
    }

    private static void add(Map<String, Locale> result, Locale locale) {
        if (locale == null || locale.getLanguage().isEmpty()) return;
        String tag = locale.toLanguageTag();
        // Pseudo-locales are tooling, not languages.
        if (tag.equals("en-XA") || tag.equals("ar-XB")) return;
        result.put(tag, locale);
    }

    // MARK: Changing it

    /** Apply a `LocalizationOverrideRequest`. Activities are recreated afterwards, asynchronously. */
    void apply(JSONObject request) throws AgentError {
        String language = request.isNull("language") ? null : request.optString("language", null);
        if (language != null && language.isEmpty()) language = null;
        String mode = request.optString("layoutDirectionMode", "system");
        Locale locale = null;
        if (language != null) {
            locale = Locale.forLanguageTag(language.replace('_', '-'));
            if (locale.getLanguage().isEmpty()) {
                throw AgentError.unavailable("\"" + language + "\" is not a language tag (examples: fr, ar, pt-BR).");
            }
        }
        directionMode = mode;
        registerLifecycle();
        setLanguage(locale);
        applyDirectionEverywhere();
    }

    /** Rebuild what is on screen in the current language. */
    void refresh() {
        for (Activity activity : Ui.activities()) {
            if (!activity.isFinishing()) activity.recreate();
        }
    }

    private void setLanguage(Locale locale) throws AgentError {
        if (Build.VERSION.SDK_INT >= 33) {
            try {
                android.app.LocaleManager manager = application.getSystemService(android.app.LocaleManager.class);
                LocaleList wanted = locale == null ? LocaleList.getEmptyLocaleList() : new LocaleList(locale);
                if (!wanted.equals(manager.getApplicationLocales())) manager.setApplicationLocales(wanted);
                return;
            } catch (Throwable e) {
                throw AgentError.unavailable("The system refused the language change: " + e.getMessage());
            }
        }
        legacyOverride = locale == null ? null : locale.toLanguageTag();
        Locale effective = locale != null ? locale : Resources.getSystem().getConfiguration().getLocales().get(0);
        Locale.setDefault(effective);
        updateConfiguration(application.getResources(), effective);
        for (Activity activity : Ui.activities()) {
            updateConfiguration(activity.getResources(), effective);
            if (!activity.isFinishing()) activity.recreate();
        }
    }

    @SuppressWarnings("deprecation")
    private static void updateConfiguration(Resources resources, Locale locale) {
        Configuration configuration = new Configuration(resources.getConfiguration());
        configuration.setLocales(new LocaleList(locale));
        configuration.setLayoutDirection(locale);
        resources.updateConfiguration(configuration, resources.getDisplayMetrics());
    }

    // MARK: Layout direction

    /** The direction to force on windows, or null to leave them to the configuration. */
    private Integer forcedDirection() {
        switch (directionMode) {
            case "leftToRight": return View.LAYOUT_DIRECTION_LTR;
            case "rightToLeft": return View.LAYOUT_DIRECTION_RTL;
            case "system": {
                // "Leave the layout alone": with a language override active the
                // configuration would follow the new language, so hold the
                // direction the device's own language gives.
                if (activeOverride() == null) return null;
                Locale system = Resources.getSystem().getConfiguration().getLocales().get(0);
                return TextUtils.getLayoutDirectionFromLocale(system);
            }
            default: return null;
        }
    }

    private void applyDirectionEverywhere() {
        for (View root : Ui.allRoots()) applyDirection(root);
    }

    private void applyDirection(View root) {
        if (root == null) return;
        Integer forced = forcedDirection();
        int wanted = forced != null ? forced : root.getResources().getConfiguration().getLayoutDirection();
        if (root.getLayoutDirection() != wanted) {
            root.setLayoutDirection(wanted);
            root.requestLayout();
        }
    }

    /** Whether the manifest lets the app mirror at all. */
    boolean supportsRtl() {
        return (application.getApplicationInfo().flags & ApplicationInfo.FLAG_SUPPORTS_RTL) != 0;
    }

    private void registerLifecycle() {
        if (lifecycleRegistered) return;
        lifecycleRegistered = true;
        application.registerActivityLifecycleCallbacks(this);
    }

    private void applyDirection(Activity activity) {
        if (activity.getWindow() == null) return;
        final View decor = activity.getWindow().peekDecorView();
        if (decor == null) return;
        applyDirection(decor);
        // The window sets the direction from the configuration when it attaches; go after it.
        decor.post(() -> applyDirection(decor));
    }

    @Override
    public void onActivityCreated(Activity activity, Bundle savedInstanceState) {
    }

    @Override
    public void onActivityStarted(Activity activity) {
        applyDirection(activity);
    }

    @Override
    public void onActivityResumed(Activity activity) {
        applyDirection(activity);
    }

    @Override
    public void onActivityPaused(Activity activity) {
    }

    @Override
    public void onActivityStopped(Activity activity) {
    }

    @Override
    public void onActivitySaveInstanceState(Activity activity, Bundle outState) {
    }

    @Override
    public void onActivityDestroyed(Activity activity) {
    }
}
