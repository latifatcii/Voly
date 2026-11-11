package dev.voly.agent;

import android.app.Activity;
import android.app.Application;
import android.content.res.Configuration;
import android.graphics.Insets;
import android.graphics.RectF;
import android.graphics.drawable.Drawable;
import android.os.Build;
import android.text.InputType;
import android.text.Layout;
import android.text.method.PasswordTransformationMethod;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.widget.AbsListView;
import android.widget.CompoundButton;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.RatingBar;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.Spinner;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Builds a `ScreenDescription`: the live view tree with what each view
 * shows and how it is styled, and flags for the usual layout suspects.
 * This is what an AI agent reads instead of guessing from a screenshot.
 *
 * Read-only, and the walk is capped.
 */
final class ScreenDescriber {
    static final int MAX_VIEWS = 2500;

    private final ObjectRegistry registry;
    private final Map<View, Object> owners;
    private final float density;
    private int remaining = MAX_VIEWS;
    private int count = 0;

    private boolean includeHidden;
    private boolean includeAccessibility;
    private Integer maxDepth;

    ScreenDescriber(ObjectRegistry registry) {
        this.registry = registry;
        this.owners = Fragments.viewOwners();
        this.density = Ui.density();
    }

    JSONObject describe(JSONObject request, String topViewController) throws AgentError {
        includeHidden = request.optBoolean("includeHidden", false);
        includeAccessibility = request.optBoolean("includeAccessibility", true);
        maxDepth = request.has("maxDepth") && !request.isNull("maxDepth") ? request.optInt("maxDepth") : null;

        List<View> roots = new ArrayList<>();
        JSONArray ancestors = null;
        JSONArray described = new JSONArray();
        boolean rooted = request.has("rootID") && !request.isNull("rootID");
        Object rootObject = rooted ? registry.objectFor(request.optLong("rootID")) : null;
        if (rootObject instanceof ComposeNode) {
            // A node of Compose content, selected in the inspector: described like a view.
            ComposeNode composeNode = (ComposeNode) rootObject;
            ComposeTree.Item item = ComposeTree.find(composeNode, ComposeTree.RECENT_ENOUGH_MS);
            View host = composeNode.host();
            if (item == null || host == null) throw AgentError.objectGone(request.optLong("rootID"));
            ancestors = ancestors(host, true);
            List<ComposeTree.Item> above = new ArrayList<>();
            for (ComposeTree.Item parent = item.parent; parent != null; parent = parent.parent) above.add(0, parent);
            for (ComposeTree.Item parent : above) {
                JSONObject entry = Json.object();
                Json.put(entry, "id", registry.idFor(parent.ref));
                Json.put(entry, "className", parent.name());
                ancestors.put(entry);
            }
            JSONObject node = describeCompose(host, item, 0);
            if (node != null) {
                Json.put(node, "layout", composeLayout(host, item));
                described.put(node);
            }
        } else if (rooted) {
            long rootId = request.optLong("rootID");
            if (!(rootObject instanceof View)) throw AgentError.objectGone(rootId);
            View view = (View) rootObject;
            roots.add(view);
            ancestors = ancestors(view, false);
        } else {
            roots.addAll(includeHidden ? Ui.allRoots() : Ui.visibleRoots());
        }

        for (View root : roots) {
            JSONObject node = describe(root, 0, false, false);
            if (node == null) continue;
            if (rooted) Json.put(node, "layout", layoutDetails(root));
            described.put(node);
        }

        Application app = Ui.application();
        int[] display = Ui.displaySizePx();
        Configuration configuration = app != null
            ? app.getResources().getConfiguration()
            : android.content.res.Resources.getSystem().getConfiguration();
        Activity top = Ui.topActivity();
        if (top != null) configuration = top.getResources().getConfiguration();
        boolean dark = (configuration.uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;

        JSONObject screen = Json.object();
        Json.put(screen, "appName", appName(app));
        Json.put(screen, "bundleIdentifier", app != null ? app.getPackageName() : null);
        Json.put(screen, "screenSize", Json.size(display[0] / density, display[1] / density));
        Json.put(screen, "scale", (double) density);
        Json.put(screen, "orientation", Ui.orientation());
        Json.put(screen, "appearance", dark ? "dark" : "light");
        Json.put(screen, "contentSizeCategory", Properties.trim(configuration.fontScale) + "x");
        Json.put(screen, "topViewController", topViewController);
        Json.put(screen, "roots", described);
        if (ancestors != null) Json.put(screen, "ancestors", ancestors);
        Json.put(screen, "viewCount", count);
        Json.put(screen, "isTruncated", remaining <= 0);
        return screen;
    }

    static String appName(Application app) {
        if (app == null) return "App";
        try {
            CharSequence label = app.getPackageManager().getApplicationLabel(app.getApplicationInfo());
            if (label != null && label.length() > 0) return label.toString();
        } catch (Throwable ignored) {
        }
        return app.getPackageName();
    }

    /** The views above `view`, outermost first; with `inclusive`, `view` itself is the last of them. */
    private JSONArray ancestors(View view, boolean inclusive) {
        List<View> chain = new ArrayList<>();
        if (inclusive) chain.add(view);
        for (Object parent = view.getParent(); parent instanceof View; parent = ((View) parent).getParent()) {
            chain.add(0, (View) parent);
        }
        JSONArray ancestors = new JSONArray();
        for (View ancestor : chain) {
            JSONObject entry = Json.object();
            Json.put(entry, "id", registry.idFor(ancestor));
            Json.put(entry, "className", Classes.displayName(ancestor.getClass()));
            Json.put(entry, "viewController", ownerName(ancestor));
            ancestors.put(entry);
        }
        return ancestors;
    }

    /** Class of the fragment or activity whose root view this is. */
    private String ownerName(View view) {
        Object owner = Snapshots.owner(view, owners);
        return owner == null ? null : Classes.displayName(owner.getClass());
    }

    // MARK: One view

    /**
     * @param scrollsX an ancestor scrolls horizontally, so being out of view sideways is normal
     * @param scrollsY the same, vertically
     */
    private JSONObject describe(View view, int depth, boolean scrollsX, boolean scrollsY) {
        if (remaining <= 0) return null;
        remaining--;
        count++;

        RectF onScreen = view.isAttachedToWindow()
            ? Ui.rectOnScreen(view)
            : new RectF(view.getLeft(), view.getTop(), view.getRight(), view.getBottom());
        JSONObject node = Json.object();
        Json.put(node, "id", registry.idFor(view));
        Json.put(node, "className", Classes.displayName(view.getClass()));
        Json.put(node, "frame", Ui.points(onScreen));
        boolean hidden = view.getVisibility() != View.VISIBLE;
        Json.put(node, "isHidden", hidden);
        Json.put(node, "alpha", (double) view.getAlpha());
        Json.put(node, "clipsToBounds", Snapshots.clipsToBounds(view));
        Json.put(node, "accessibilityIdentifier", Snapshots.resourceName(view));
        Json.put(node, "viewController", ownerName(view));
        Integer background = Style.backgroundColor(view);
        if (background != null && (background >>> 24) != 0) Json.put(node, "backgroundColor", Json.hex(background));
        float radius = Style.cornerRadius(view);
        if (radius > 0) Json.put(node, "cornerRadius", (double) (radius / density));
        Style.Border border = Style.border(view);
        if (border != null) {
            Json.put(node, "borderWidth", (double) (border.width / density));
            Json.put(node, "borderColor", Json.hex(border.color));
        }

        List<String> state = new ArrayList<>();
        List<String> flags = new ArrayList<>();
        Content content = describeContent(view, node, state, flags);

        // The usual suspects.
        boolean visible = !hidden && view.getAlpha() > 0.01f;
        if (visible && (view.getWidth() == 0 || view.getHeight() == 0) && shouldHaveSize(view, content, background)) {
            flags.add("zeroSize");
        }
        View root = view.getRootView();
        if (visible && view != root && view.isAttachedToWindow() && view.getWidth() > 0 && view.getHeight() > 0) {
            RectF inRoot = Ui.rectInRoot(view);
            boolean outsideX = inRoot.right <= 0 || inRoot.left >= root.getWidth();
            boolean outsideY = inRoot.bottom <= 0 || inRoot.top >= root.getHeight();
            if ((outsideX && !scrollsX) || (outsideY && !scrollsY)) flags.add("offscreen");
        }

        // Children.
        int omitted = 0;
        JSONArray children = new JSONArray();
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) view;
            List<View> shown = new ArrayList<>();
            for (int index = 0; index < group.getChildCount(); index++) {
                View child = group.getChildAt(index);
                if (includeHidden || Ui.isVisible(child)) shown.add(child);
                else omitted++;
            }
            if (maxDepth != null && depth >= maxDepth) {
                omitted += shown.size();
            } else {
                boolean childrenScrollX = scrollsX || scrollsHorizontally(view);
                boolean childrenScrollY = scrollsY || scrollsVertically(view);
                for (View child : shown) {
                    JSONObject described = describe(child, depth + 1, childrenScrollX, childrenScrollY);
                    if (described != null) children.put(described);
                    else omitted++;
                }
            }
        }

        if (includeAccessibility && visible && ComposeSemantics.isComposeView(view)) {
            JSONArray elements = ComposeSemantics.elements(view, registry);
            if (elements != null) Json.put(node, "accessibilityElements", elements);
        }

        Json.put(node, "state", Json.array(state));
        Json.put(node, "flags", Json.array(flags));
        Json.put(node, "children", children);
        Json.put(node, "omittedChildren", omitted);
        return node;
    }

    // MARK: One node of Compose content

    /** `ViewDescription` of a Compose node, from what its semantics and modifiers tell. */
    private JSONObject describeCompose(View host, ComposeTree.Item item, int depth) {
        if (remaining <= 0) return null;
        remaining--;
        count++;

        ComposeProperties.Rows rows = ComposeProperties.read(item, host);
        RectF onScreen = Ui.rectInRoot(host, item.local);
        int[] origin = Ui.rootOrigin(host.getRootView());
        onScreen.offset(origin[0], origin[1]);

        JSONObject node = Json.object();
        Json.put(node, "id", registry.idFor(item.ref));
        Json.put(node, "className", item.name());
        Json.put(node, "frame", Ui.points(onScreen));
        Json.put(node, "isHidden", false);
        Json.put(node, "alpha", 1.0);
        Json.put(node, "clipsToBounds", item.clips);
        Json.put(node, "accessibilityIdentifier", item.testTag);
        Json.put(node, "accessibilityLabel", rows.get("contentDescription", String.class));
        Json.put(node, "text", rows.get("text", String.class));
        Json.put(node, "placeholder", rows.get("hint", String.class));
        String value = rows.get("toggleableState", String.class);
        Json.put(node, "value", value != null ? value : rows.get("stateDescription", String.class));

        List<String> font = new ArrayList<>();
        String family = rows.get("fontFamily", String.class), weight = rows.get("fontWeight", String.class);
        if (family != null) font.add(family);
        // "Medium (500)" → "Medium"
        if (weight != null) font.add(weight.contains(" ") ? weight.substring(0, weight.indexOf(' ')) : weight);
        if (Boolean.TRUE.equals(rows.get("isItalic", Boolean.class))) font.add("Italic");
        Double size = rows.get("textSize", Double.class);
        if (size != null) font.add(Properties.trim(size) + "sp");
        else if (rows.get("textSize", String.class) != null) font.add(rows.get("textSize", String.class));
        if (!font.isEmpty()) Json.put(node, "font", android.text.TextUtils.join(" ", font));
        Integer textColor = rows.get("textColor", Integer.class);
        if (textColor != null) Json.put(node, "textColor", Json.hex(textColor));
        String align = rows.get("textAlign", String.class);
        if (align != null && !align.equals("Start") && !align.equals("Left")) {
            Json.put(node, "textAlignment", align.toLowerCase(java.util.Locale.US));
        }
        Double lines = rows.get("maxLines", Double.class);
        if (lines != null) Json.put(node, "numberOfLines", lines.intValue());

        Integer background = rows.get("background", Integer.class);
        if (background != null && (background >>> 24) != 0) Json.put(node, "backgroundColor", Json.hex(background));
        Double radius = cornerRadius(rows.get("backgroundShape", String.class));
        if (radius != null && radius > 0) Json.put(node, "cornerRadius", radius);

        List<String> state = new ArrayList<>();
        if (Boolean.FALSE.equals(rows.get("isEnabled", Boolean.class))) state.add("disabled");
        if (Boolean.TRUE.equals(rows.get("isSelected", Boolean.class))) state.add("selected");

        int omitted = 0;
        JSONArray children = new JSONArray();
        if (maxDepth != null && depth >= maxDepth) {
            omitted = item.children.size();
        } else {
            for (ComposeTree.Item child : item.children) {
                JSONObject described = describeCompose(host, child, depth + 1);
                if (described != null) children.put(described);
                else omitted++;
            }
        }
        Json.put(node, "state", Json.array(state));
        Json.put(node, "flags", new JSONArray());
        Json.put(node, "children", children);
        Json.put(node, "omittedChildren", omitted);
        return node;
    }

    /** `RoundedCornerShape(12dp)` → 12; null for a shape that isn't one radius in dp. */
    private static Double cornerRadius(String shape) {
        if (shape == null || !shape.startsWith("RoundedCornerShape(") || !shape.endsWith("dp)")) return null;
        try {
            return Double.parseDouble(shape.substring("RoundedCornerShape(".length(), shape.length() - 3));
        } catch (NumberFormatException e) {
            return null;
        }
    }

    /** `LayoutDetails` for a Compose node: there are no layout params, the modifiers are the layout. */
    private JSONObject composeLayout(View host, ComposeTree.Item item) {
        double width = item.local.width() / density, height = item.local.height() / density;
        JSONObject details = Json.object();
        Json.put(details, "bounds", Json.rect(0, 0, width, height));
        Json.put(details, "usesAutoLayout", false);
        Json.put(details, "huggingHorizontal", 0.0);
        Json.put(details, "huggingVertical", 0.0);
        Json.put(details, "compressionResistanceHorizontal", 0.0);
        Json.put(details, "compressionResistanceVertical", 0.0);
        double[] insets = systemInsets(host);
        Json.put(details, "safeAreaInsets", Json.insets(insets[0], insets[1], insets[2], insets[3]));
        Json.put(details, "layoutMargins", Json.insets(0, 0, 0, 0));

        ComposeProperties.Rows rows = ComposeProperties.read(item, host);
        List<String> parts = new ArrayList<>();
        parts.add("Jetpack Compose content, read-only; child of "
            + (item.parent != null ? item.parent.name() : Classes.displayName(host.getClass())));
        String policy = rows.get("measurePolicy", String.class);
        if (policy != null) parts.add("measured by " + policy);
        // As they are written in source: padding(8dp) → background(#FFFFFFFF, RoundedCornerShape(12dp)) → …
        List<String> names = new ArrayList<>();
        List<String> arguments = new ArrayList<>();
        for (ComposeProperties.Row row : rows.list) {
            if (!row.modifier) continue;
            String argument = row.type.equals("color") ? Json.hex((Integer) row.value) : String.valueOf(row.value);
            // The panel needs unique names ("padding 2") and one value a row ("backgroundShape").
            String name = row.name.replaceAll(" \\d+$", "");
            int last = names.size() - 1;
            if (last >= 0 && name.startsWith(names.get(last)) && name.length() > names.get(last).length()) {
                String detail = name.endsWith("Alpha") ? "alpha " + argument : argument;
                arguments.set(last, arguments.get(last).isEmpty() ? detail : arguments.get(last) + ", " + detail);
                continue;
            }
            names.add(name);
            arguments.add(argument);
        }
        List<String> modifiers = new ArrayList<>();
        for (int index = 0; index < names.size(); index++) {
            modifiers.add(arguments.get(index).isEmpty() ? names.get(index) : names.get(index) + "(" + arguments.get(index) + ")");
        }
        if (!modifiers.isEmpty()) parts.add("modifiers, outermost first: " + android.text.TextUtils.join(" → ", modifiers));
        parts.add("size " + Properties.trim(width) + "×" + Properties.trim(height) + " dp");
        Json.put(details, "summary", android.text.TextUtils.join("; ", parts));
        return details;
    }

    /** What was read from a view, for the checks that depend on it. */
    private static final class Content {
        boolean hasText;
        boolean hasImage;
    }

    /** Text, fonts, colors and control state for the widget classes that carry them. */
    private Content describeContent(View view, JSONObject node, List<String> state, List<String> flags) {
        Content content = new Content();
        CharSequence label = view.getContentDescription();
        if (label != null && label.length() > 0) Json.put(node, "accessibilityLabel", label.toString());

        if (view instanceof TextView) {
            TextView text = (TextView) view;
            CharSequence shown = text.getText();
            boolean secure = isSecure(text);
            if (shown != null && shown.length() > 0) {
                // What is typed into a password field stays in the app.
                Json.put(node, "text", secure ? "(secure text, " + shown.length() + " characters)" : shown.toString());
                content.hasText = true;
            }
            if (secure) state.add("secure");
            CharSequence hint = text.getHint();
            if (hint != null && hint.length() > 0) {
                Json.put(node, "placeholder", hint.toString());
                content.hasText = true;
            }
            Json.put(node, "font", Properties.typeface(text.getTypeface()) + " " + Properties.trim(Properties.textSizeSp(text)) + "sp");
            Json.put(node, "textColor", Json.hex(text.getCurrentTextColor()));
            Json.put(node, "textAlignment", alignment(text));
            if (text.getMaxLines() != Integer.MAX_VALUE && text.getMaxLines() > 0) {
                Json.put(node, "numberOfLines", text.getMaxLines());
            }
            if (isTruncated(text)) flags.add("truncated");
        }
        if (view instanceof ImageView) {
            ImageView image = (ImageView) view;
            Drawable drawable = image.getDrawable();
            if (drawable != null) {
                String size = drawable.getIntrinsicWidth() > 0 && drawable.getIntrinsicHeight() > 0
                    ? Properties.trim(drawable.getIntrinsicWidth() / density) + "×"
                        + Properties.trim(drawable.getIntrinsicHeight() / density) + " "
                    : "";
                Json.put(node, "image", size + Properties.scaleTypeName(image.getScaleType()));
                content.hasImage = true;
            }
            Integer tint = Style.tintColor(view);
            if (tint != null) Json.put(node, "tintColor", Json.hex(tint));
        }
        if (view instanceof CompoundButton) {
            Json.put(node, "value", ((CompoundButton) view).isChecked() ? "on" : "off");
        } else if (view instanceof RatingBar) {
            RatingBar rating = (RatingBar) view;
            Json.put(node, "value", Properties.trim(rating.getRating()) + " of " + rating.getNumStars());
        } else if (view instanceof SeekBar || view instanceof ProgressBar) {
            ProgressBar bar = (ProgressBar) view;
            if (bar.isIndeterminate()) {
                Json.put(node, "value", "indeterminate");
            } else {
                int minimum = Build.VERSION.SDK_INT >= 26 ? bar.getMin() : 0;
                Json.put(node, "value", bar.getProgress() + " in " + minimum + "…" + bar.getMax());
            }
        } else if (view instanceof Spinner) {
            Object selected = ((Spinner) view).getSelectedItem();
            if (selected != null) Json.put(node, "value", "selected: " + selected);
        }
        if (view instanceof LinearLayout) {
            LinearLayout layout = (LinearLayout) view;
            String description = layout.getOrientation() == LinearLayout.VERTICAL ? "vertical" : "horizontal";
            String gravity = Properties.gravity(layout.getGravity());
            if (!gravity.equals("none") && !gravity.equals("top|start") && !gravity.equals("top|left")) {
                description += " gravity=" + gravity;
            }
            if (layout.getWeightSum() > 0) description += " weightSum=" + Properties.trim(layout.getWeightSum());
            Json.put(node, "stack", description);
        }
        String scroll = scrollDescription(view);
        if (scroll != null) Json.put(node, "scroll", scroll);

        if (!view.isEnabled()) state.add("disabled");
        if (view.isSelected()) state.add("selected");
        if (view.isPressed()) state.add("highlighted");
        if (view.isFocused()) state.add("focused");
        return content;
    }

    // MARK: Helpers

    private static boolean isSecure(TextView text) {
        if (text.getTransformationMethod() instanceof PasswordTransformationMethod) return true;
        int type = text.getInputType();
        int variation = type & (InputType.TYPE_MASK_CLASS | InputType.TYPE_MASK_VARIATION);
        return variation == (InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD)
            || variation == (InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD)
            || variation == (InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_VARIATION_PASSWORD);
    }

    /** Only spelled out when it isn't the default (start-aligned). */
    private static String alignment(TextView text) {
        int horizontal = text.getGravity() & Gravity.RELATIVE_HORIZONTAL_GRAVITY_MASK;
        int absolute = horizontal & Gravity.HORIZONTAL_GRAVITY_MASK;
        if (absolute == Gravity.CENTER_HORIZONTAL) return "center";
        boolean relative = (horizontal & Gravity.RELATIVE_LAYOUT_DIRECTION) != 0;
        boolean rtl = text.getLayoutDirection() == View.LAYOUT_DIRECTION_RTL;
        if (absolute == Gravity.RIGHT) return relative ? (rtl ? "left" : "right") : (rtl ? null : "right");
        if (absolute == Gravity.LEFT && !relative && rtl) return "left";
        return null;
    }

    /** Text that doesn't fit: ellipsized, or cut off by the view's height or line limit. */
    private static boolean isTruncated(TextView text) {
        if (!Ui.isVisible(text) || text.getWidth() <= 0 || text.getHeight() <= 0) return false;
        Layout layout = text.getLayout();
        CharSequence shown = text.getText();
        if (layout == null || shown == null || shown.length() == 0) return false;
        // Editable and scrolling text is meant to exceed its box.
        if (text.onCheckIsTextEditor() || text.getMovementMethod() != null && text.canScrollVertically(1)) return false;
        int lines = layout.getLineCount();
        for (int line = 0; line < lines; line++) {
            if (layout.getEllipsisCount(line) > 0) return true;
        }
        int available = text.getHeight() - text.getCompoundPaddingTop() - text.getCompoundPaddingBottom();
        if (layout.getHeight() > available + 1) return true;
        // A single unwrapped line wider than the view is clipped.
        if (lines == 1) {
            int width = text.getWidth() - text.getCompoundPaddingLeft() - text.getCompoundPaddingRight();
            if (layout.getLineWidth(0) > width + 1 && !text.canScrollHorizontally(1) && !text.canScrollHorizontally(-1)) {
                return true;
            }
        }
        return false;
    }

    private static boolean scrollsVertically(View view) {
        if (view instanceof ScrollView || view instanceof AbsListView
            || Reflect.isInstance(view, "androidx.core.widget.NestedScrollView")) {
            return true;
        }
        if (Reflect.isInstance(view, "androidx.recyclerview.widget.RecyclerView")) {
            Object manager = Reflect.call(view, "getLayoutManager");
            return manager == null || !Boolean.FALSE.equals(Reflect.call(manager, "canScrollVertically"));
        }
        return view.canScrollVertically(1) || view.canScrollVertically(-1);
    }

    private static boolean scrollsHorizontally(View view) {
        if (view instanceof HorizontalScrollView
            || Reflect.isInstance(view, "androidx.viewpager.widget.ViewPager")
            || Reflect.isInstance(view, "androidx.viewpager2.widget.ViewPager2")) {
            return true;
        }
        if (Reflect.isInstance(view, "androidx.recyclerview.widget.RecyclerView")) {
            Object manager = Reflect.call(view, "getLayoutManager");
            return manager == null || !Boolean.FALSE.equals(Reflect.call(manager, "canScrollHorizontally"));
        }
        return view.canScrollHorizontally(1) || view.canScrollHorizontally(-1);
    }

    /** `content 393×1840 offset 0,212` for things that scroll. */
    private String scrollDescription(View view) {
        if (!(view instanceof ScrollView || view instanceof HorizontalScrollView || view instanceof AbsListView
            || Reflect.isInstance(view, "androidx.recyclerview.widget.RecyclerView")
            || Reflect.isInstance(view, "androidx.core.widget.NestedScrollView"))) {
            return null;
        }
        Object rangeX = Reflect.call(view, "computeHorizontalScrollRange");
        Object rangeY = Reflect.call(view, "computeVerticalScrollRange");
        Object offsetX = Reflect.call(view, "computeHorizontalScrollOffset");
        Object offsetY = Reflect.call(view, "computeVerticalScrollOffset");
        if (!(rangeX instanceof Integer) || !(rangeY instanceof Integer)) return null;
        int width = Math.max((Integer) rangeX, view.getWidth()), height = Math.max((Integer) rangeY, view.getHeight());
        int x = offsetX instanceof Integer ? (Integer) offsetX : view.getScrollX();
        int y = offsetY instanceof Integer ? (Integer) offsetY : view.getScrollY();
        return "content " + Math.round(width / density) + "×" + Math.round(height / density)
            + " offset " + Math.round(x / density) + "," + Math.round(y / density);
    }

    /** Zero size is only worth a flag on views meant to show something. */
    private static boolean shouldHaveSize(View view, Content content, Integer background) {
        if (content.hasText || content.hasImage) return true;
        if (background != null && (background >>> 24) != 0) return true;
        if (view.isClickable()) return true;
        return view instanceof ViewGroup && ((ViewGroup) view).getChildCount() > 0;
    }

    // MARK: Layout details

    /** `LayoutDetails` for the view a request is rooted at. */
    private JSONObject layoutDetails(View view) {
        ViewGroup.LayoutParams params = view.getLayoutParams();
        JSONObject details = Json.object();
        Json.put(details, "bounds", Json.rect(
            view.getScrollX() / density, view.getScrollY() / density, view.getWidth() / density, view.getHeight() / density));
        Json.put(details, "usesAutoLayout", LayoutConstraints.isConstraintParams(params));
        Json.put(details, "huggingHorizontal", 0.0);
        Json.put(details, "huggingVertical", 0.0);
        Json.put(details, "compressionResistanceHorizontal", 0.0);
        Json.put(details, "compressionResistanceVertical", 0.0);
        double[] insets = systemInsets(view);
        Json.put(details, "safeAreaInsets", Json.insets(insets[0], insets[1], insets[2], insets[3]));
        Json.put(details, "layoutMargins", Json.insets(0, 0, 0, 0));

        // What an Android developer would look for, in their own terms.
        List<String> parts = new ArrayList<>();
        View parent = view.getParent() instanceof View ? (View) view.getParent() : null;
        parts.add(parent != null ? "child of " + Classes.displayName(parent.getClass()) : "a window's root view");
        if (params != null) {
            parts.add("layout_width=" + Properties.dimension(params.width, density)
                + " layout_height=" + Properties.dimension(params.height, density));
            if (params instanceof ViewGroup.MarginLayoutParams) {
                ViewGroup.MarginLayoutParams margins = (ViewGroup.MarginLayoutParams) params;
                if (margins.leftMargin != 0 || margins.topMargin != 0 || margins.rightMargin != 0 || margins.bottomMargin != 0) {
                    parts.add("margins " + sides(margins.leftMargin, margins.topMargin, margins.rightMargin, margins.bottomMargin));
                }
            }
            if (params instanceof LinearLayout.LayoutParams && ((LinearLayout.LayoutParams) params).weight != 0) {
                parts.add("layout_weight=" + Properties.trim(((LinearLayout.LayoutParams) params).weight));
            }
        }
        if (view.getPaddingLeft() != 0 || view.getPaddingTop() != 0 || view.getPaddingRight() != 0 || view.getPaddingBottom() != 0) {
            parts.add("padding " + sides(view.getPaddingLeft(), view.getPaddingTop(), view.getPaddingRight(), view.getPaddingBottom()));
        }
        parts.add("size " + Properties.trim(view.getWidth() / density) + "×" + Properties.trim(view.getHeight() / density) + " dp");
        if (view.getMinimumWidth() > 0 || view.getMinimumHeight() > 0) {
            parts.add("minimum " + Properties.trim(view.getMinimumWidth() / density) + "×"
                + Properties.trim(view.getMinimumHeight() / density));
        }
        if (view.getLayoutDirection() == View.LAYOUT_DIRECTION_RTL) parts.add("right-to-left");
        if (insets[0] != 0 || insets[1] != 0 || insets[2] != 0 || insets[3] != 0) {
            parts.add("system bars top " + Properties.trim(insets[0]) + " left " + Properties.trim(insets[1])
                + " bottom " + Properties.trim(insets[2]) + " right " + Properties.trim(insets[3]));
        }
        StringBuilder summary = new StringBuilder();
        for (String part : parts) {
            if (summary.length() > 0) summary.append("; ");
            summary.append(part);
        }
        Json.put(details, "summary", summary.toString());
        return details;
    }

    private String sides(int left, int top, int right, int bottom) {
        return "left " + Properties.trim(left / density) + " top " + Properties.trim(top / density)
            + " right " + Properties.trim(right / density) + " bottom " + Properties.trim(bottom / density);
    }

    /** Top, left, bottom, right of the system bars and cutout, in dp. */
    private double[] systemInsets(View view) {
        try {
            WindowInsets insets = view.getRootWindowInsets();
            if (insets == null) return new double[4];
            if (Build.VERSION.SDK_INT >= 30) {
                Insets bars = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                return new double[] {bars.top / density, bars.left / density, bars.bottom / density, bars.right / density};
            }
            return new double[] {
                insets.getSystemWindowInsetTop() / density, insets.getSystemWindowInsetLeft() / density,
                insets.getSystemWindowInsetBottom() / density, insets.getSystemWindowInsetRight() / density,
            };
        } catch (Throwable e) {
            return new double[4];
        }
    }
}
