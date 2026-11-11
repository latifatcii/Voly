package dev.voly.agent;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Rect;
import android.graphics.RectF;
import android.util.Base64;
import android.view.PixelCopy;
import android.view.View;
import android.view.Window;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.util.List;

/**
 * Screenshots of the app's own windows, or of one view, without Voly's
 * highlight in them.
 *
 * Windows are copied from what is actually on screen (`PixelCopy`), so
 * hardware-rendered content — images, Compose, video surfaces — is in the
 * picture. The app screenshot is always the size of the display, with each
 * window where it sits, so a frame from the view tree times the scale is a
 * pixel position in the image.
 */
final class Screenshots {
    interface Completion {
        void done(JSONObject image, AgentError error);
    }

    private final Overlay overlay;
    /** Captures asked for while one is being made. Main thread. */
    private final java.util.ArrayDeque<Runnable> waiting = new java.util.ArrayDeque<>();
    private boolean capturing;

    Screenshots(Overlay overlay) {
        this.overlay = overlay;
    }

    /**
     * One capture at a time: each holds a bitmap the size of what it
     * copies until its PNG is made. Main thread.
     */
    private void start(Runnable capture) {
        if (capturing) {
            waiting.add(capture);
            return;
        }
        capturing = true;
        capture.run();
    }

    /** Main thread. */
    private void next() {
        Runnable following = waiting.poll();
        if (following == null) capturing = false;
        else following.run();
    }

    /** The host is gone: nobody is waiting for what hasn't been started. Main thread. */
    void cancelWaiting() {
        waiting.clear();
    }

    void captureApplication(Completion completion) {
        start(() -> captureApplicationNow(completion));
    }

    /** A view, or the part of its host view that a node of Compose content takes up. */
    void capture(Target target, Completion completion) {
        start(() -> captureViewNow(target, completion));
    }

    private void captureApplicationNow(Completion completion) {
        Capture capture = new Capture(completion);
        withoutOverlay(capture, () -> {
            List<View> roots = Ui.visibleRoots();
            if (roots.isEmpty()) {
                capture.fail(AgentError.unavailable("The app has no visible window."));
                return;
            }
            int[] display = Ui.displaySizePx();
            Bitmap bitmap = Bitmap.createBitmap(Math.max(1, display[0]), Math.max(1, display[1]), Bitmap.Config.ARGB_8888);
            copyNext(capture, roots, 0, new Canvas(bitmap), () -> capture.finish(bitmap));
        });
    }

    private void captureViewNow(Target target, Completion completion) {
        Capture capture = new Capture(completion);
        View view = target.view;
        RectF size = target.isAttached() ? target.rectInRoot() : null;
        if (size == null || size.width() < 1 || size.height() < 1) {
            capture.fail(AgentError.unavailable("That view is not on screen or has no size."));
            return;
        }
        withoutOverlay(capture, () -> {
            View root = view.getRootView();
            RectF inRoot = target.isAttached() ? target.rectInRoot() : null;
            if (inRoot == null) {
                capture.fail(AgentError.unavailable("That view is no longer on screen."));
                return;
            }
            Rect source = new Rect(
                Math.max(0, Math.round(inRoot.left)), Math.max(0, Math.round(inRoot.top)),
                Math.min(root.getWidth(), Math.round(inRoot.right)), Math.min(root.getHeight(), Math.round(inRoot.bottom)));
            if (source.width() <= 0 || source.height() <= 0) {
                // Scrolled out of its window: draw it ourselves.
                Bitmap drawn = draw(target);
                if (drawn != null) capture.finish(drawn);
                else capture.fail(AgentError.unavailable("That view is outside its window and could not be drawn."));
                return;
            }
            Bitmap bitmap = Bitmap.createBitmap(source.width(), source.height(), Bitmap.Config.ARGB_8888);
            copy(capture, root, source, bitmap, copied -> {
                Bitmap drawn = copied ? bitmap : draw(target);
                if (drawn != null) capture.finish(drawn);
                else capture.fail(AgentError.unavailable("The view could not be captured."));
            });
        });
    }

    /** Software rendering of a view, or of the part of its host that a Compose node takes up. */
    private static Bitmap draw(Target target) {
        Bitmap whole = draw(target.view);
        if (whole == null || !target.isCompose()) return whole;
        ComposeTree.Item item = target.item();
        if (item == null) return null;
        int left = Math.max(0, Math.round(item.local.left)), top = Math.max(0, Math.round(item.local.top));
        int right = Math.min(whole.getWidth(), Math.round(item.local.right));
        int bottom = Math.min(whole.getHeight(), Math.round(item.local.bottom));
        if (right <= left || bottom <= top) return null;
        try {
            return Bitmap.createBitmap(whole, left, top, right - left, bottom - top);
        } catch (Throwable e) {
            return null;
        }
    }

    /**
     * One capture on its way to exactly one answer. The steps run in
     * callbacks on the app's main thread, outside the dispatcher: anything
     * thrown there (a bitmap the app has no memory for) would otherwise take
     * the app down, and leave Voly's highlight hidden for good.
     */
    private final class Capture {
        private final Completion completion;
        private boolean answered;

        Capture(Completion completion) {
            this.completion = completion;
        }

        /** Main thread. */
        void step(Runnable work) {
            try {
                work.run();
            } catch (Throwable e) {
                Log.e("screenshot failed", e);
                fail(AgentError.unavailable("The screenshot could not be taken: " + e));
            }
        }

        /** Main thread. */
        void fail(AgentError error) {
            if (answered) return;
            answered = true;
            overlay.setSuppressed(false);
            completion.done(null, error);
            next();
        }

        /** Main thread. The PNG is made on a thread of its own: a full screen takes a while. */
        void finish(Bitmap bitmap) {
            if (answered) return;
            answered = true;
            overlay.setSuppressed(false);
            final float density = Ui.density();
            final String orientation = Ui.orientation();
            Thread encoder = new Thread(() -> {
                JSONObject image = null;
                AgentError error = null;
                try {
                    image = encode(bitmap, density, orientation);
                } catch (Throwable e) {
                    Log.e("encoding a screenshot failed", e);
                    error = AgentError.unavailable("The screenshot could not be encoded: " + e);
                }
                completion.done(image, error);
                Ui.MAIN.post(Screenshots.this::next);
            }, "VolyAgent-screenshot");
            encoder.setDaemon(true);
            encoder.start();
        }
    }

    /** Run `work` once Voly's own drawing is off the screen. */
    private void withoutOverlay(Capture capture, Runnable work) {
        if (!overlay.setSuppressed(true)) {
            capture.step(work);
            return;
        }
        // The windows have to draw a frame without the overlay first.
        Ui.MAIN.postDelayed(() -> capture.step(work), 80);
    }

    private interface Copied {
        void done(boolean success);
    }

    /** Composite the windows bottom-up, each at its place on the display. */
    private void copyNext(Capture capture, List<View> roots, int index, Canvas canvas, Runnable done) {
        if (index >= roots.size()) {
            done.run();
            return;
        }
        View root = roots.get(index);
        int[] origin = Ui.rootOrigin(root);
        Bitmap part = Bitmap.createBitmap(root.getWidth(), root.getHeight(), Bitmap.Config.ARGB_8888);
        copy(capture, root, new Rect(0, 0, root.getWidth(), root.getHeight()), part, copied -> {
            Bitmap usable = copied ? part : draw(root);
            if (usable != null) canvas.drawBitmap(usable, origin[0], origin[1], null);
            copyNext(capture, roots, index + 1, canvas, done);
        });
    }

    private void copy(Capture capture, View root, Rect source, Bitmap into, Copied done) {
        Window window = Ui.windowOf(root);
        if (window == null || window.peekDecorView() == null) {
            done.done(false);
            return;
        }
        boolean requested;
        try {
            PixelCopy.request(
                window, source, into, result -> capture.step(() -> done.done(result == PixelCopy.SUCCESS)), Ui.MAIN);
            requested = true;
        } catch (Throwable e) {
            requested = false;
        }
        if (!requested) done.done(false);
    }

    /** Software rendering, for what `PixelCopy` can't reach (popups, off-screen views). */
    private static Bitmap draw(View view) {
        if (view.getWidth() <= 0 || view.getHeight() <= 0) return null;
        try {
            Bitmap bitmap = Bitmap.createBitmap(view.getWidth(), view.getHeight(), Bitmap.Config.ARGB_8888);
            view.draw(new Canvas(bitmap));
            return bitmap;
        } catch (Throwable e) {
            // Hardware bitmaps can't be drawn in software.
            return null;
        }
    }

    /** `ScreenshotImage` */
    private static JSONObject encode(Bitmap bitmap, float density, String orientation) {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, bytes);
        JSONObject image = Json.object();
        Json.put(image, "png", Base64.encodeToString(bytes.toByteArray(), Base64.NO_WRAP));
        Json.put(image, "pixelWidth", bitmap.getWidth());
        Json.put(image, "pixelHeight", bitmap.getHeight());
        Json.put(image, "scale", (double) density);
        Json.put(image, "orientation", orientation);
        return image;
    }
}
