package dev.voly.agent;

/** Telling the app's own classes from the platform's and the usual libraries'. */
final class Classes {
    private Classes() {}

    private static final String[] LIBRARY_PREFIXES = {
        "android.", "androidx.", "com.android.", "com.google.android.", "com.google.accompanist.",
        "kotlin.", "kotlinx.", "java.", "javax.", "dalvik.", "dev.voly.agent.",
    };

    static boolean isAppDefined(Class<?> type) {
        if (type == null || type.getClassLoader() == android.view.View.class.getClassLoader()) return false;
        String name = type.getName();
        for (String prefix : LIBRARY_PREFIXES) {
            if (name.startsWith(prefix)) return false;
        }
        return true;
    }

    /**
     * The class a lambda or local class was written in, by name: the part
     * before the first `$`. Lambdas the build tools generate
     * (`CardKt$$ExternalSyntheticLambda0`) have no enclosing class to ask
     * for, only this name.
     */
    static Class<?> fileClass(Class<?> type) {
        String name = type.getName();
        int dollar = name.indexOf('$');
        Class<?> named = dollar <= 0 ? null : Reflect.classOrNull(name.substring(0, dollar), type.getClassLoader());
        return named != null ? named : outermost(type);
    }

    /** `com.example.app.ui.BadgeView$Dot` → `BadgeView.Dot` */
    static String displayName(Class<?> type) {
        return Reflect.simpleName(type);
    }

    /** The outermost class: the one a source file is named after. */
    static Class<?> outermost(Class<?> type) {
        Class<?> current = type;
        for (int depth = 0; depth < 8; depth++) {
            Class<?> enclosing;
            try {
                enclosing = current.getEnclosingClass();
            } catch (Throwable e) {
                enclosing = null;
            }
            if (enclosing == null) break;
            current = enclosing;
        }
        return current;
    }
}
