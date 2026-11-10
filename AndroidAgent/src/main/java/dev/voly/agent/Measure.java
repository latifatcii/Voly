package dev.voly.agent;

import android.graphics.RectF;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

/**
 * The geometry of measuring one view against another: the guide segments
 * to draw and the summary for the host's badge. A port of
 * `FrameMeasurement` in VolyModels — the two must agree, since the host
 * draws the same thing from its own snapshot when it isn't hovering.
 *
 * All rectangles are in points (dp), in display coordinates.
 */
final class Measure {
    private Measure() {}

    static final class Guide {
        final boolean horizontal;
        /** Horizontal: y, x1, x2. Vertical: x, y1, y2. */
        final double position, from, to;
        final String label;

        Guide(boolean horizontal, double position, double from, double to, String label) {
            this.horizontal = horizontal;
            this.position = position;
            this.from = from;
            this.to = to;
            this.label = label;
        }

        /** `MeasurementGuide` */
        JSONObject toJson() {
            JSONObject values = Json.object();
            if (horizontal) {
                Json.put(values, "y", position);
                Json.put(values, "x1", from);
                Json.put(values, "x2", to);
            } else {
                Json.put(values, "x", position);
                Json.put(values, "y1", from);
                Json.put(values, "y2", to);
            }
            Json.put(values, "label", label);
            return Json.enumCaseLabeled(horizontal ? "horizontal" : "vertical", values);
        }

        static Guide fromJson(JSONObject json) {
            JSONObject h = json.optJSONObject("horizontal");
            if (h != null) return new Guide(true, h.optDouble("y"), h.optDouble("x1"), h.optDouble("x2"), h.optString("label"));
            JSONObject v = json.optJSONObject("vertical");
            if (v != null) return new Guide(false, v.optDouble("x"), v.optDouble("y1"), v.optDouble("y2"), v.optString("label"));
            return null;
        }
    }

    static final class Result {
        final RectF other;
        final boolean transformed;
        final List<Guide> guides;
        final String kind;
        final Double horizontal, vertical;

        Result(RectF other, boolean transformed, List<Guide> guides, String kind, Double horizontal, Double vertical) {
            this.other = other;
            this.transformed = transformed;
            this.guides = guides;
            this.kind = kind;
            this.horizontal = horizontal;
            this.vertical = vertical;
        }

        /** `MeasurementSummary` */
        JSONObject summary() {
            return Measure.summary(kind, horizontal, vertical);
        }
    }

    static JSONObject summary(String kind, Double horizontal, Double vertical) {
        JSONObject summary = Json.object();
        Json.put(summary, "kind", kind);
        Json.put(summary, "horizontal", horizontal);
        Json.put(summary, "vertical", vertical);
        return summary;
    }

    /** Null when there is nothing sensible to measure (an empty or non-finite frame). */
    static Result compute(RectF a, RectF b, boolean transformed) {
        if (!usable(a) || !usable(b)) return null;
        if (a.equals(b)) return new Result(b, transformed, new ArrayList<Guide>(), "sameView", null, null);
        boolean intersects = a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
        if (!intersects) return sideBySide(a, b, transformed);
        if (a.contains(b)) return containment(a, b, b, transformed);
        if (b.contains(a)) return containment(b, a, b, transformed);
        return overlap(a, b, transformed);
    }

    private static Result sideBySide(RectF a, RectF b, boolean transformed) {
        List<Guide> guides = new ArrayList<>();
        Double horizontal = null, vertical = null;
        if (a.right <= b.left) {
            horizontal = (double) (b.left - a.right);
            guides.add(new Guide(true, sharedMid(a.top, a.bottom, b.top, b.bottom), a.right, b.left, label(horizontal)));
        } else if (b.right <= a.left) {
            horizontal = (double) (a.left - b.right);
            guides.add(new Guide(true, sharedMid(a.top, a.bottom, b.top, b.bottom), b.right, a.left, label(horizontal)));
        }
        if (a.bottom <= b.top) {
            vertical = (double) (b.top - a.bottom);
            guides.add(new Guide(false, sharedMid(a.left, a.right, b.left, b.right), a.bottom, b.top, label(vertical)));
        } else if (b.bottom <= a.top) {
            vertical = (double) (a.top - b.bottom);
            guides.add(new Guide(false, sharedMid(a.left, a.right, b.left, b.right), b.bottom, a.top, label(vertical)));
        }
        return new Result(b, transformed, guides, "sideBySide", horizontal, vertical);
    }

    private static Result containment(RectF outer, RectF inner, RectF other, boolean transformed) {
        double top = inner.top - outer.top, right = outer.right - inner.right;
        double bottom = outer.bottom - inner.bottom, left = inner.left - outer.left;
        List<Guide> guides = new ArrayList<>();
        guides.add(new Guide(false, inner.centerX(), outer.top, inner.top, label(top)));
        guides.add(new Guide(true, inner.centerY(), inner.right, outer.right, label(right)));
        guides.add(new Guide(false, inner.centerX(), inner.bottom, outer.bottom, label(bottom)));
        guides.add(new Guide(true, inner.centerY(), outer.left, inner.left, label(left)));
        return new Result(other, transformed, guides, "containment", Math.min(left, right), Math.min(top, bottom));
    }

    private static Result overlap(RectF a, RectF b, boolean transformed) {
        double ax = a.centerX(), ay = a.centerY(), bx = b.centerX(), by = b.centerY();
        double dx = bx - ax, dy = by - ay;
        List<Guide> guides = new ArrayList<>();
        if (Math.abs(dx) > 0.5) guides.add(new Guide(true, ay, ax, bx, label(Math.abs(dx))));
        if (Math.abs(dy) > 0.5) guides.add(new Guide(false, bx, ay, by, label(Math.abs(dy))));
        if (guides.isEmpty()) guides.add(new Guide(true, ay, ax, ax, label(Math.sqrt(dx * dx + dy * dy))));
        return new Result(b, transformed, guides, "overlap", null, null);
    }

    private static double sharedMid(double a1, double a2, double b1, double b2) {
        double low = Math.max(a1, b1), high = Math.min(a2, b2);
        if (high > low) return (low + high) / 2;
        return (Math.min(a1, b1) + Math.max(a2, b2)) / 2;
    }

    private static String label(double points) {
        return String.valueOf(Math.round(points));
    }

    private static boolean usable(RectF rect) {
        return !Float.isNaN(rect.left) && !Float.isNaN(rect.top) && !Float.isInfinite(rect.left)
            && !Float.isInfinite(rect.top) && rect.width() > 0 && rect.height() > 0
            && !Float.isInfinite(rect.width()) && !Float.isInfinite(rect.height());
    }

    static JSONArray guides(List<Guide> guides) {
        JSONArray array = new JSONArray();
        for (Guide guide : guides) array.put(guide.toJson());
        return array;
    }
}
