package dev.voly.agent;

import android.graphics.Canvas;
import android.graphics.ColorFilter;
import android.graphics.DashPathEffect;
import android.graphics.Paint;
import android.graphics.PixelFormat;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.Window;

import java.util.ArrayList;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;

/**
 * Everything Voly shows and intercepts inside the app: the selection
 * highlight, measurement guides, and pick mode.
 *
 * Nothing is added to the app's view tree. Drawing goes through each
 * window's `ViewOverlay`, and pick mode wraps each window's
 * `Window.Callback` to take the touches — both come off again without a
 * trace.
 */
final class Overlay {
    interface PickListener {
        void onPicked(View view);
    }

    private static final int BLUE = 0xFF0A84FF;
    private static final int ORANGE = 0xFFFF9500;

    private final Map<View, Layer> layers = new IdentityHashMap<>();
    private final Map<Window, PickCallback> callbacks = new IdentityHashMap<>();
    private PickListener pickListener;
    private boolean picking;
    private boolean suppressed;

    private View highlighted;
    private View measureRoot;
    private RectF measureOther;
    private boolean measureTransformed;
    private List<Measure.Guide> measureGuides = new ArrayList<>();

    private final Runnable reconcile = new Runnable() {
        @Override
        public void run() {
            if (!picking && highlighted == null && measureRoot == null) return;
            refresh();
            Ui.MAIN.postDelayed(this, 300);
        }
    };

    void setPickListener(PickListener listener) {
        pickListener = listener;
    }

    boolean isPicking() {
        return picking;
    }

    View highlightedView() {
        return highlighted;
    }

    // MARK: Pick mode

    void enterPickMode() {
        if (picking) return;
        picking = true;
        refresh();
        schedule();
    }

    void exitPickMode() {
        if (!picking) return;
        picking = false;
        for (Map.Entry<Window, PickCallback> entry : callbacks.entrySet()) restore(entry.getKey(), entry.getValue());
        callbacks.clear();
        refresh();
    }

    private void restore(Window window, PickCallback callback) {
        // Only if nobody wrapped the callback again in the meantime.
        if (window.getCallback() == callback) window.setCallback(callback.wrapped());
        else callback.disable();
    }

    // MARK: Highlight and measurement

    void highlight(View view) {
        highlighted = view;
        refresh();
        schedule();
    }

    void clear() {
        highlighted = null;
        clearMeasurement();
    }

    /** Guides in display points, as the host or `Measure` computed them. */
    void showMeasurement(RectF otherPoints, boolean transformed, List<Measure.Guide> guides) {
        measureRoot = Ui.rootFor(highlighted);
        measureOther = otherPoints;
        measureTransformed = transformed;
        measureGuides = guides;
        refresh();
        schedule();
    }

    void clearMeasurement() {
        measureRoot = null;
        measureOther = null;
        measureGuides = new ArrayList<>();
        refresh();
    }

    /** Take Voly's drawing off screen for a screenshot. Returns whether anything was showing. */
    boolean setSuppressed(boolean value) {
        boolean wasDrawing = !layers.isEmpty();
        suppressed = value;
        refresh();
        return wasDrawing;
    }

    private void schedule() {
        Ui.MAIN.removeCallbacks(reconcile);
        Ui.MAIN.postDelayed(reconcile, 300);
    }

    /** Bring every window's drawing and touch handling in line with the current state. */
    private void refresh() {
        List<View> roots = Ui.visibleRoots();
        if (highlighted != null && !highlighted.isAttachedToWindow()) highlighted = null;
        View highlightRoot = highlighted != null ? highlighted.getRootView() : null;
        if (measureRoot != null && !roots.contains(measureRoot)) measureRoot = highlightRoot;

        // Windows that went away take their layer with them.
        List<View> gone = new ArrayList<>();
        for (View root : layers.keySet()) {
            if (!roots.contains(root)) gone.add(root);
        }
        for (View root : gone) removeLayer(root);

        for (View root : roots) {
            boolean wanted = !suppressed && (picking || root == highlightRoot || root == measureRoot);
            if (!wanted) {
                removeLayer(root);
                continue;
            }
            Layer layer = layers.get(root);
            if (layer == null) {
                layer = new Layer(root);
                layers.put(root, layer);
                root.getOverlay().add(layer);
            }
            layer.setBounds(0, 0, root.getWidth(), root.getHeight());
            layer.tinted = picking;
            layer.highlight = root == highlightRoot ? Ui.rectInRoot(highlighted) : null;
            if (root == measureRoot && measureOther != null) {
                layer.measureOther = measureOther;
                layer.guides = measureGuides;
                layer.transformed = measureTransformed;
            } else {
                layer.measureOther = null;
                layer.guides = null;
            }
            layer.invalidateSelf();
            root.invalidate();
        }

        if (picking) {
            for (View root : roots) {
                Window window = Ui.windowOf(root);
                if (window == null || callbacks.containsKey(window)) continue;
                Window.Callback current = window.getCallback();
                if (current == null || current instanceof PickCallback) continue;
                PickCallback callback = new PickCallback(current, this);
                window.setCallback(callback);
                callbacks.put(window, callback);
            }
        }
    }

    private void removeLayer(View root) {
        Layer layer = layers.remove(root);
        if (layer == null) return;
        try {
            root.getOverlay().remove(layer);
            root.invalidate();
        } catch (Throwable ignored) {
        }
    }

    // MARK: Touches in pick mode

    private float downX, downY;
    private boolean dragging;

    /** Called for every touch event of a hooked window; true means "swallowed". */
    boolean onTouch(MotionEvent event) {
        if (!picking) return false;
        float x = event.getRawX(), y = event.getRawY();
        switch (event.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                downX = x;
                downY = y;
                dragging = false;
                break;
            case MotionEvent.ACTION_MOVE: {
                View anchor = highlighted;
                int slop = anchor != null ? ViewConfiguration.get(anchor.getContext()).getScaledTouchSlop() : 24;
                if (!dragging && Math.hypot(x - downX, y - downY) > slop) dragging = true;
                // Dragging with a selection measures it against whatever is under the finger.
                if (dragging && anchor != null) measureAgainst(anchor, Ui.hitTest(x, y));
                break;
            }
            case MotionEvent.ACTION_UP:
                if (dragging) {
                    clearMeasurement();
                } else {
                    View picked = Ui.hitTest(x, y);
                    if (picked != null && pickListener != null) pickListener.onPicked(picked);
                }
                dragging = false;
                break;
            case MotionEvent.ACTION_CANCEL:
                dragging = false;
                clearMeasurement();
                break;
            default:
                break;
        }
        return true;
    }

    /** A mouse pointer moving over the window without a button down. */
    boolean onHover(MotionEvent event) {
        if (!picking) return false;
        View anchor = highlighted;
        if (anchor != null && event.getActionMasked() == MotionEvent.ACTION_HOVER_MOVE) {
            measureAgainst(anchor, Ui.hitTest(event.getRawX(), event.getRawY()));
        } else if (event.getActionMasked() == MotionEvent.ACTION_HOVER_EXIT) {
            clearMeasurement();
        }
        return true;
    }

    /** Measure `anchor` against `other` and draw it. Returns null when there is nothing to draw. */
    Measure.Result measureAgainst(View anchor, View other) {
        if (anchor == null || other == null || !anchor.isAttachedToWindow() || !other.isAttachedToWindow()) {
            clearMeasurement();
            return null;
        }
        float density = Ui.density();
        RectF a = scaled(Ui.rectOnScreen(anchor), 1 / density), b = scaled(Ui.rectOnScreen(other), 1 / density);
        Measure.Result result = Measure.compute(a, b, Ui.hasTransform(anchor) || Ui.hasTransform(other));
        if (result == null || result.kind.equals("sameView")) {
            clearMeasurement();
            return result;
        }
        showMeasurement(result.other, result.transformed, result.guides);
        return result;
    }

    static RectF scaled(RectF rect, float factor) {
        return new RectF(rect.left * factor, rect.top * factor, rect.right * factor, rect.bottom * factor);
    }

    // MARK: Drawing

    /** What Voly draws over one window, in that window's root coordinates (pixels). */
    private static final class Layer extends Drawable {
        private final View root;
        boolean tinted;
        RectF highlight;
        RectF measureOther;
        List<Measure.Guide> guides;
        boolean transformed;

        private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint stroke = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint text = new Paint(Paint.ANTI_ALIAS_FLAG);

        Layer(View root) {
            this.root = root;
            stroke.setStyle(Paint.Style.STROKE);
            text.setTypeface(Typeface.create(Typeface.MONOSPACE, Typeface.BOLD));
            text.setTextAlign(Paint.Align.CENTER);
        }

        @Override
        public void draw(Canvas canvas) {
            float density = Ui.density();
            if (tinted) canvas.drawColor(0x140A84FF);
            if (highlight != null) {
                fill.setStyle(Paint.Style.FILL);
                fill.setColor(0x2E0A84FF);
                canvas.drawRect(highlight, fill);
                stroke.setColor(BLUE);
                stroke.setStrokeWidth(density);
                stroke.setPathEffect(null);
                canvas.drawRect(highlight, stroke);
            }
            if (measureOther == null || guides == null) return;

            // Guides arrive in display points; this window's root may not sit at 0,0.
            int[] origin = Ui.rootOrigin(root);
            stroke.setColor(ORANGE);
            stroke.setStrokeWidth(density);
            float dash = (transformed ? 2 : 4) * density, gap = (transformed ? 3 : 4) * density;
            stroke.setPathEffect(new DashPathEffect(new float[] {dash, gap}, 0));
            canvas.drawRect(
                measureOther.left * density - origin[0], measureOther.top * density - origin[1],
                measureOther.right * density - origin[0], measureOther.bottom * density - origin[1], stroke);
            text.setTextSize(10 * density);
            for (Measure.Guide guide : guides) {
                float centerX, centerY;
                if (guide.horizontal) {
                    float y = (float) guide.position * density - origin[1];
                    float x1 = (float) guide.from * density - origin[0], x2 = (float) guide.to * density - origin[0];
                    canvas.drawLine(x1, y, x2, y, stroke);
                    centerX = (x1 + x2) / 2;
                    centerY = y - 8 * density;
                } else {
                    float x = (float) guide.position * density - origin[0];
                    float y1 = (float) guide.from * density - origin[1], y2 = (float) guide.to * density - origin[1];
                    canvas.drawLine(x, y1, x, y2, stroke);
                    centerX = x + 18 * density;
                    centerY = (y1 + y2) / 2;
                }
                String label = guide.label + " dp";
                float width = Math.max(36 * density, text.measureText(label) + 10 * density), height = 14 * density;
                RectF badge = new RectF(centerX - width / 2, centerY - height / 2, centerX + width / 2, centerY + height / 2);
                fill.setStyle(Paint.Style.FILL);
                fill.setColor(ORANGE);
                canvas.drawRoundRect(badge, 3 * density, 3 * density, fill);
                text.setColor(0xFFFFFFFF);
                canvas.drawText(label, centerX, centerY - (text.ascent() + text.descent()) / 2, text);
            }
        }

        @Override
        public void setAlpha(int alpha) {
        }

        @Override
        public void setColorFilter(ColorFilter filter) {
        }

        @Override
        public int getOpacity() {
            return PixelFormat.TRANSLUCENT;
        }
    }
}
