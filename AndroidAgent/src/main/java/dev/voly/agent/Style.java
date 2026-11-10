package dev.voly.agent;

import android.content.res.ColorStateList;
import android.graphics.Outline;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.DrawableWrapper;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.InsetDrawable;
import android.graphics.drawable.LayerDrawable;
import android.graphics.drawable.RippleDrawable;
import android.graphics.drawable.StateListDrawable;
import android.os.Build;
import android.view.View;
import android.widget.ImageView;

/**
 * What a view's background amounts to — fill color, corner radius, border —
 * read from the drawable types that carry such things, and how to change
 * them without throwing the rest of the background away.
 *
 * Sizes are in pixels here; callers convert.
 */
final class Style {
    private Style() {}

    static final String MATERIAL_SHAPE = "com.google.android.material.shape.MaterialShapeDrawable";
    static final String CARD_VIEW = "androidx.cardview.widget.CardView";

    /** The drawable that actually paints the shape: unwraps ripples, insets, state lists. */
    static Drawable shapeDrawable(Drawable drawable) {
        for (int depth = 0; drawable != null && depth < 6; depth++) {
            if (drawable instanceof GradientDrawable || drawable instanceof ColorDrawable
                || Reflect.isInstance(drawable, MATERIAL_SHAPE)) {
                return drawable;
            }
            if (drawable instanceof StateListDrawable) {
                drawable = drawable.getCurrent();
            } else if (drawable instanceof RippleDrawable || drawable instanceof LayerDrawable) {
                // The content sits under the ripple / at the bottom of the stack.
                LayerDrawable layers = (LayerDrawable) drawable;
                Drawable content = null;
                for (int index = 0; index < layers.getNumberOfLayers(); index++) {
                    if (drawable instanceof RippleDrawable && layers.getId(index) == android.R.id.mask) continue;
                    content = layers.getDrawable(index);
                    if (content != null) break;
                }
                drawable = content;
            } else if (drawable instanceof InsetDrawable) {
                drawable = ((InsetDrawable) drawable).getDrawable();
            } else if (Build.VERSION.SDK_INT >= 23 && drawable instanceof DrawableWrapper) {
                drawable = ((DrawableWrapper) drawable).getDrawable();
            } else {
                Object wrapped = Reflect.call(drawable, "getWrappedDrawable");
                if (!(wrapped instanceof Drawable)) wrapped = Reflect.call(drawable, "getDrawable");
                drawable = wrapped instanceof Drawable ? (Drawable) wrapped : null;
            }
        }
        return null;
    }

    private static Integer currentColor(Object colors, int[] state) {
        if (!(colors instanceof ColorStateList)) return null;
        ColorStateList list = (ColorStateList) colors;
        return list.getColorForState(state, list.getDefaultColor());
    }

    /** The color a view's background fills with, as it is drawn now. Null when there is none. */
    static Integer backgroundColor(View view) {
        if (Reflect.isInstance(view, CARD_VIEW)) {
            Integer color = currentColor(Reflect.call(view, "getCardBackgroundColor"), view.getDrawableState());
            if (color != null) return color;
        }
        Drawable shape = shapeDrawable(view.getBackground());
        if (shape == null) return null;
        Integer color = null;
        if (shape instanceof ColorDrawable) {
            color = ((ColorDrawable) shape).getColor();
        } else if (shape instanceof GradientDrawable) {
            GradientDrawable gradient = (GradientDrawable) shape;
            if (Build.VERSION.SDK_INT >= 24) {
                color = currentColor(gradient.getColor(), view.getDrawableState());
                if (color == null) {
                    int[] colors = gradient.getColors();
                    if (colors != null && colors.length > 0) color = colors[0];
                }
            }
        } else {
            color = currentColor(Reflect.call(shape, "getFillColor"), view.getDrawableState());
        }
        // A tint replaces the fill (this is how Material buttons are colored).
        ColorStateList tint = view.getBackgroundTintList();
        if (tint == null && Reflect.isInstance(shape, MATERIAL_SHAPE)) {
            Object own = Reflect.call(shape, "getTintList");
            if (own instanceof ColorStateList) tint = (ColorStateList) own;
        }
        if (tint != null && !(shape instanceof ColorDrawable)) {
            color = tint.getColorForState(view.getDrawableState(), tint.getDefaultColor());
        }
        if (color == null) return null;
        int alpha = shape.getAlpha();
        if (alpha < 255) {
            int combined = ((color >>> 24) & 0xFF) * alpha / 255;
            color = (color & 0x00FFFFFF) | (combined << 24);
        }
        return color;
    }

    /** Corner radius in pixels, or 0. */
    static float cornerRadius(View view) {
        if (Reflect.isInstance(view, CARD_VIEW)) {
            Object radius = Reflect.call(view, "getRadius");
            if (radius instanceof Number) return ((Number) radius).floatValue();
        }
        Drawable shape = shapeDrawable(view.getBackground());
        if (shape instanceof GradientDrawable) {
            GradientDrawable gradient = (GradientDrawable) shape;
            if (Build.VERSION.SDK_INT >= 24) {
                try {
                    float radius = gradient.getCornerRadius();
                    if (radius > 0) return radius;
                    float[] radii = gradient.getCornerRadii();
                    if (radii != null && radii.length > 0) return radii[0];
                } catch (Throwable ignored) {
                    // getCornerRadii throws when no radii were ever set.
                }
            }
        } else if (Reflect.isInstance(shape, MATERIAL_SHAPE)) {
            Object radius = Reflect.call(shape, "getTopLeftCornerResolvedSize");
            if (radius instanceof Number) return ((Number) radius).floatValue();
        }
        // A rounded outline (clipToOutline, elevation shadows) counts too.
        try {
            if (Build.VERSION.SDK_INT >= 24 && view.getOutlineProvider() != null
                && view.getWidth() > 0 && view.getHeight() > 0 && view.getClipToOutline()) {
                Outline outline = new Outline();
                view.getOutlineProvider().getOutline(view, outline);
                float radius = outline.getRadius();
                if (radius > 0) return radius;
            }
        } catch (Throwable ignored) {
        }
        return 0;
    }

    static final class Border {
        final float width;
        final int color;

        Border(float width, int color) {
            this.width = width;
            this.color = color;
        }
    }

    /** The border's width (pixels) and color, or null. */
    static Border border(View view) {
        Drawable shape = shapeDrawable(view.getBackground());
        if (Reflect.isInstance(view, "com.google.android.material.card.MaterialCardView")) {
            Object width = Reflect.call(view, "getStrokeWidth");
            Object color = Reflect.call(view, "getStrokeColor");
            if (width instanceof Number && ((Number) width).floatValue() > 0 && color instanceof Number) {
                return new Border(((Number) width).floatValue(), ((Number) color).intValue());
            }
        }
        if (shape instanceof GradientDrawable) {
            // The stroke has no public getter; it lives in the drawable's state.
            Object state = Reflect.field(shape, "mGradientState");
            Object width = Reflect.field(state, "mStrokeWidth");
            Object colors = Reflect.field(state, "mStrokeColors");
            if (width instanceof Number && ((Number) width).floatValue() > 0) {
                Integer color = currentColor(colors, view.getDrawableState());
                return new Border(((Number) width).floatValue(), color != null ? color : 0xFF000000);
            }
        } else if (Reflect.isInstance(shape, MATERIAL_SHAPE)) {
            Object width = Reflect.call(shape, "getStrokeWidth");
            Integer color = currentColor(Reflect.call(shape, "getStrokeColor"), view.getDrawableState());
            if (width instanceof Number && ((Number) width).floatValue() > 0) {
                return new Border(((Number) width).floatValue(), color != null ? color : 0xFF000000);
            }
        }
        return null;
    }

    /** The tint a view applies to what it draws: an image's tint, else its background tint. */
    static Integer tintColor(View view) {
        ColorStateList tint = null;
        if (view instanceof ImageView) tint = ((ImageView) view).getImageTintList();
        if (tint == null) tint = view.getBackgroundTintList();
        return tint == null ? null : tint.getColorForState(view.getDrawableState(), tint.getDefaultColor());
    }

    // MARK: Changing it

    static void setBackgroundColor(View view, Integer color) {
        if (color == null) {
            view.setBackground(null);
            return;
        }
        if (Reflect.isInstance(view, CARD_VIEW)
            && Reflect.call(view, "setCardBackgroundColor", new Class<?>[] {int.class}, color) != null) {
            return;
        }
        Drawable shape = shapeDrawable(view.getBackground());
        if (shape instanceof GradientDrawable) {
            view.setBackgroundTintList(null);
            ((GradientDrawable) shape.mutate()).setColor(color);
        } else if (Reflect.isInstance(shape, MATERIAL_SHAPE)) {
            // Material widgets color their shape through the tint.
            view.setBackgroundTintList(ColorStateList.valueOf(color));
            Reflect.call(shape, "setFillColor", new Class<?>[] {ColorStateList.class}, ColorStateList.valueOf(color));
        } else if (shape instanceof ColorDrawable && shape == view.getBackground()) {
            ((ColorDrawable) shape.mutate()).setColor(color);
        } else {
            view.setBackgroundColor(color);
        }
        view.invalidate();
    }

    static void setTintColor(View view, Integer color) {
        ColorStateList tint = color == null ? null : ColorStateList.valueOf(color);
        if (view instanceof ImageView) {
            ((ImageView) view).setImageTintList(tint);
        } else {
            view.setBackgroundTintList(tint);
        }
        view.invalidate();
    }

    /** A `GradientDrawable` to carry a radius or stroke the current background can't. */
    private static GradientDrawable shapeFor(View view) {
        Drawable shape = shapeDrawable(view.getBackground());
        if (shape instanceof GradientDrawable) return (GradientDrawable) shape.mutate();
        GradientDrawable replacement = new GradientDrawable();
        Integer color = backgroundColor(view);
        replacement.setColor(color != null ? color : 0x00000000);
        view.setBackground(replacement);
        return replacement;
    }

    static void setCornerRadius(View view, float pixels) {
        if (Reflect.isInstance(view, CARD_VIEW)
            && Reflect.method(view.getClass(), "setRadius", float.class) != null) {
            Reflect.call(view, "setRadius", new Class<?>[] {float.class}, pixels);
            return;
        }
        Drawable shape = shapeDrawable(view.getBackground());
        if (Reflect.isInstance(shape, MATERIAL_SHAPE)
            && Reflect.method(shape.getClass(), "setCornerSize", float.class) != null) {
            Reflect.call(shape, "setCornerSize", new Class<?>[] {float.class}, pixels);
        } else {
            shapeFor(view).setCornerRadius(pixels);
        }
        view.invalidateOutline();
        view.invalidate();
    }

    static void setBorder(View view, Float widthPixels, Integer color) {
        Border current = border(view);
        float width = widthPixels != null ? widthPixels : (current != null ? current.width : 0);
        int strokeColor = color != null ? color : (current != null ? current.color : 0xFF000000);
        Drawable shape = shapeDrawable(view.getBackground());
        if (Reflect.isInstance(shape, MATERIAL_SHAPE)
            && Reflect.method(shape.getClass(), "setStroke", float.class, int.class) != null) {
            Reflect.call(shape, "setStroke", new Class<?>[] {float.class, int.class}, width, strokeColor);
        } else {
            shapeFor(view).setStroke(Math.round(width), strokeColor);
        }
        view.invalidate();
    }
}
