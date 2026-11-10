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

    Screenshots(Overlay overlay) {
        this.overlay = overlay;
    }

    void captureApplication(Completion completion) {
        withoutOverlay(() -> {
            List<View> roots = Ui.visibleRoots();
            if (roots.isEmpty()) {
                finish(completion, null, AgentError.unavailable("The app has no visible window."));
                return;
            }
            int[] display = Ui.displaySizePx();
            Bitmap bitmap = Bitmap.createBitmap(Math.max(1, display[0]), Math.max(1, display[1]), Bitmap.Config.ARGB_8888);
            copyNext(roots, 0, new Canvas(bitmap), () -> finish(completion, encode(bitmap), null));
        });
    }

    void captureView(View view, Completion completion) {
        if (!view.isAttachedToWindow() || view.getWidth() <= 0 || view.getHeight() <= 0) {
            completion.done(null, AgentError.unavailable("That view is not on screen or has no size."));
            return;
        }
        withoutOverlay(() -> {
            View root = view.getRootView();
            RectF inRoot = Ui.rectInRoot(view);
            Rect source = new Rect(
                Math.max(0, Math.round(inRoot.left)), Math.max(0, Math.round(inRoot.top)),
                Math.min(root.getWidth(), Math.round(inRoot.right)), Math.min(root.getHeight(), Math.round(inRoot.bottom)));
            if (source.width() <= 0 || source.height() <= 0) {
                // Scrolled out of its window: draw it ourselves.
                Bitmap drawn = draw(view);
                finish(completion, drawn == null ? null : encode(drawn),
                    drawn == null ? AgentError.unavailable("That view is outside its window and could not be drawn.") : null);
                return;
            }
            Bitmap bitmap = Bitmap.createBitmap(source.width(), source.height(), Bitmap.Config.ARGB_8888);
            copy(root, source, bitmap, copied -> {
                if (copied) {
                    finish(completion, encode(bitmap), null);
                    return;
                }
                Bitmap drawn = draw(view);
                finish(completion, drawn == null ? null : encode(drawn),
                    drawn == null ? AgentError.unavailable("The view could not be captured.") : null);
            });
        });
    }

    private void finish(Completion completion, JSONObject image, AgentError error) {
        overlay.setSuppressed(false);
        completion.done(image, error);
    }

    /** Run `work` once Voly's own drawing is off the screen. */
    private void withoutOverlay(Runnable work) {
        if (!overlay.setSuppressed(true)) {
            work.run();
            return;
        }
        // The windows have to draw a frame without the overlay first.
        Ui.MAIN.postDelayed(work, 80);
    }

    private interface Copied {
        void done(boolean success);
    }

    /** Composite the windows bottom-up, each at its place on the display. */
    private void copyNext(List<View> roots, int index, Canvas canvas, Runnable done) {
        if (index >= roots.size()) {
            done.run();
            return;
        }
        View root = roots.get(index);
        int[] origin = Ui.rootOrigin(root);
        Bitmap part = Bitmap.createBitmap(root.getWidth(), root.getHeight(), Bitmap.Config.ARGB_8888);
        copy(root, new Rect(0, 0, root.getWidth(), root.getHeight()), part, copied -> {
            Bitmap usable = copied ? part : draw(root);
            if (usable != null) canvas.drawBitmap(usable, origin[0], origin[1], null);
            copyNext(roots, index + 1, canvas, done);
        });
    }

    private void copy(View root, Rect source, Bitmap into, Copied done) {
        Window window = Ui.windowOf(root);
        if (window == null || window.peekDecorView() == null) {
            done.done(false);
            return;
        }
        try {
            PixelCopy.request(window, source, into, result -> done.done(result == PixelCopy.SUCCESS), Ui.MAIN);
        } catch (Throwable e) {
            done.done(false);
        }
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
    private static JSONObject encode(Bitmap bitmap) {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, bytes);
        JSONObject image = Json.object();
        Json.put(image, "png", Base64.encodeToString(bytes.toByteArray(), Base64.NO_WRAP));
        Json.put(image, "pixelWidth", bitmap.getWidth());
        Json.put(image, "pixelHeight", bitmap.getHeight());
        Json.put(image, "scale", (double) Ui.density());
        Json.put(image, "orientation", Ui.orientation());
        return image;
    }
}
