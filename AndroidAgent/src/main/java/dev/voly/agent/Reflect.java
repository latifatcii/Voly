package dev.voly.agent;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Reflection that fails soft. Used for platform internals (window list,
 * activity list) and for AndroidX / Compose classes that live in the app,
 * which the agent can't link against.
 */
final class Reflect {
    private Reflect() {}

    static Class<?> classOrNull(String name, ClassLoader loader) {
        try {
            return Class.forName(name, false, loader != null ? loader : Reflect.class.getClassLoader());
        } catch (Throwable e) {
            return null;
        }
    }

    /** Call a no-argument method by name, searching the class hierarchy. */
    static Object call(Object target, String name) {
        return call(target, name, new Class<?>[0]);
    }

    static Object call(Object target, String name, Class<?>[] types, Object... args) {
        if (target == null) return null;
        Method method = method(target.getClass(), name, types);
        if (method == null) return null;
        try {
            return method.invoke(target, args);
        } catch (Throwable e) {
            return null;
        }
    }

    static Object callStatic(Class<?> type, String name) {
        if (type == null) return null;
        Method method = method(type, name);
        if (method == null) return null;
        try {
            return method.invoke(null);
        } catch (Throwable e) {
            return null;
        }
    }

    static Method method(Class<?> type, String name, Class<?>... types) {
        for (Class<?> current = type; current != null; current = current.getSuperclass()) {
            try {
                Method method = current.getDeclaredMethod(name, types);
                method.setAccessible(true);
                return method;
            } catch (Throwable ignored) {
            }
        }
        // Interface default methods and the like.
        try {
            Method method = type.getMethod(name, types);
            method.setAccessible(true);
            return method;
        } catch (Throwable ignored) {
            return null;
        }
    }

    static Object field(Object target, String name) {
        if (target == null) return null;
        Field field = field(target.getClass(), name);
        if (field == null) return null;
        try {
            return field.get(target);
        } catch (Throwable e) {
            return null;
        }
    }

    private static final Map<Class<?>, Map<String, Object>> FIELDS = new ConcurrentHashMap<>();

    /** Looked up once per class, like `getter`: a miss is an exception per class of the hierarchy. */
    static Field field(Class<?> type, String name) {
        Map<String, Object> known = FIELDS.get(type);
        if (known == null) {
            known = new ConcurrentHashMap<>();
            FIELDS.put(type, known);
        }
        Object cached = known.get(name);
        if (cached == null) {
            cached = MISSING;
            for (Class<?> current = type; current != null; current = current.getSuperclass()) {
                try {
                    Field field = current.getDeclaredField(name);
                    field.setAccessible(true);
                    cached = field;
                    break;
                } catch (Throwable ignored) {
                }
            }
            known.put(name, cached);
        }
        return cached == MISSING ? null : (Field) cached;
    }

    // MARK: Cached lookups

    /**
     * Getters looked up once per class. Walking a Compose tree calls the
     * same few methods on thousands of objects, and a lookup that fails
     * costs an exception per class in the hierarchy.
     */
    private static final Map<Class<?>, Map<String, Object>> GETTERS = new ConcurrentHashMap<>();
    private static final Object MISSING = new Object();

    /**
     * A no-argument instance method called `name`, or its mangled form:
     * Kotlin appends `-<hash>` to members that return an inline class
     * (`getSize-YbymL2g`) and `$<module>` to internal ones
     * (`getChildren$ui_release`, later `getChildren$ui`).
     */
    static Method getter(Class<?> type, String name) {
        Map<String, Object> known = GETTERS.get(type);
        if (known == null) {
            known = new ConcurrentHashMap<>();
            GETTERS.put(type, known);
        }
        Object cached = known.get(name);
        if (cached == null) {
            Method found = findGetter(type, name);
            cached = found != null ? found : MISSING;
            known.put(name, cached);
        }
        return cached == MISSING ? null : (Method) cached;
    }

    private static Method findGetter(Class<?> type, String name) {
        Method mangled = null;
        try {
            for (Method method : type.getMethods()) {
                if (!isGetter(method)) continue;
                if (method.getName().equals(name)) return accessible(method);
                if (mangled == null && isMangled(method.getName(), name)) mangled = method;
            }
        } catch (Throwable ignored) {
        }
        for (Class<?> current = type; current != null; current = current.getSuperclass()) {
            try {
                for (Method method : current.getDeclaredMethods()) {
                    if (!isGetter(method)) continue;
                    if (method.getName().equals(name)) return accessible(method);
                    if (mangled == null && isMangled(method.getName(), name)) mangled = method;
                }
            } catch (Throwable ignored) {
            }
        }
        return mangled == null ? null : accessible(mangled);
    }

    private static boolean isGetter(Method method) {
        return method.getParameterTypes().length == 0 && !java.lang.reflect.Modifier.isStatic(method.getModifiers())
            && method.getReturnType() != void.class && !method.isSynthetic();
    }

    private static boolean isMangled(String actual, String name) {
        return actual.length() > name.length() + 1 && actual.startsWith(name)
            && (actual.charAt(name.length()) == '-' || actual.charAt(name.length()) == '$')
            && !actual.endsWith("$annotations") && !actual.endsWith("$default");
    }

    private static Method accessible(Method method) {
        try {
            method.setAccessible(true);
        } catch (Throwable ignored) {
        }
        return method;
    }

    static boolean has(Object target, String name) {
        return target != null && getter(target.getClass(), name) != null;
    }

    /** The value of a cached getter; null when there is none or it throws. */
    static Object get(Object target, String name) {
        if (target == null) return null;
        Method method = getter(target.getClass(), name);
        if (method == null) return null;
        try {
            return method.invoke(target);
        } catch (Throwable e) {
            return null;
        }
    }

    static boolean getBool(Object target, String name, boolean fallback) {
        Object value = get(target, name);
        return value instanceof Boolean ? (Boolean) value : fallback;
    }

    static int getInt(Object target, String name, int fallback) {
        Object value = get(target, name);
        return value instanceof Number ? ((Number) value).intValue() : fallback;
    }

    /** Whether `type` or one of its supertypes has this fully qualified name. */
    static boolean isInstance(Object object, String className) {
        if (object == null) return false;
        return extendsClass(object.getClass(), className);
    }

    static boolean extendsClass(Class<?> type, String className) {
        for (Class<?> current = type; current != null; current = current.getSuperclass()) {
            if (current.getName().equals(className)) return true;
            for (Class<?> implemented : current.getInterfaces()) {
                if (implemented.getName().equals(className)) return true;
            }
        }
        return false;
    }

    /** `Outer$Inner` → `Inner`; anonymous classes fall back to the name's tail. */
    static String simpleName(Class<?> type) {
        String simple = null;
        try {
            simple = type.getSimpleName();
        } catch (Throwable ignored) {
        }
        if (simple != null && !simple.isEmpty()) return simple;
        String name = type.getName();
        return name.substring(name.lastIndexOf('.') + 1);
    }

    static String packageName(Class<?> type) {
        String name = type.getName();
        int dot = name.lastIndexOf('.');
        return dot < 0 ? null : name.substring(0, dot);
    }
}
