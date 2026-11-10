package dev.voly.agent;

import java.lang.ref.ReferenceQueue;
import java.lang.ref.WeakReference;
import java.util.HashMap;

/**
 * Hands out the ids the host refers to views (and layout constraints) by.
 * Objects are held weakly and compared by identity, so an id simply stops
 * resolving once its view is gone. Main thread only.
 */
final class ObjectRegistry {
    private static final class Ref extends WeakReference<Object> {
        final int hash;
        long id;

        Ref(Object object, ReferenceQueue<Object> queue) {
            super(object, queue);
            hash = System.identityHashCode(object);
        }

        @Override
        public int hashCode() {
            return hash;
        }

        @Override
        public boolean equals(Object other) {
            if (this == other) return true;
            if (!(other instanceof Ref)) return false;
            Object mine = get();
            return mine != null && mine == ((Ref) other).get();
        }
    }

    private final ReferenceQueue<Object> queue = new ReferenceQueue<>();
    private final HashMap<Ref, Ref> byObject = new HashMap<>();
    private final HashMap<Long, Ref> byId = new HashMap<>();
    private long nextId = 1;

    long idFor(Object object) {
        purge();
        Ref probe = new Ref(object, null);
        Ref existing = byObject.get(probe);
        if (existing != null) return existing.id;
        Ref ref = new Ref(object, queue);
        ref.id = nextId++;
        byObject.put(ref, ref);
        byId.put(ref.id, ref);
        return ref.id;
    }

    Object objectFor(long id) {
        Ref ref = byId.get(id);
        return ref == null ? null : ref.get();
    }

    private void purge() {
        Ref dead;
        while ((dead = (Ref) queue.poll()) != null) {
            byId.remove(dead.id);
            // A cleared ref equals nothing but itself; HashMap finds it by
            // its stored hash and that identity.
            byObject.remove(dead);
        }
    }
}
