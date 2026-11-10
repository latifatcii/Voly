package dev.voly.agent;

import java.lang.reflect.Field;
import java.lang.reflect.Method;

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

    static Field field(Class<?> type, String name) {
        for (Class<?> current = type; current != null; current = current.getSuperclass()) {
            try {
                Field field = current.getDeclaredField(name);
                field.setAccessible(true);
                return field;
            } catch (Throwable ignored) {
            }
        }
        return null;
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
