package dev.voly.agent

import android.os.Looper
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.password
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.example.shop.Stamp
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.util.ReflectionHelpers

/**
 * The agent's reading of Compose content, against a real Compose running on
 * the JVM. What is checked is what the inspector depends on: that every
 * node is found, named, and where it is on screen; that the same node keeps
 * its id; and that the semantics tree takes over when layout nodes can't be
 * listed.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w400dp-h800dp-xhdpi")
class ComposeInspectionTest {
    private lateinit var activity: ComponentActivity
    private lateinit var host: View
    private val density = 2f

    @Before
    fun showScreen() {
        activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        val composeView = ComposeView(activity)
        composeView.setContent { Screen() }
        activity.setContentView(composeView)
        idle()
        // Robolectric lays the window out but never reports it visible, and the
        // agent only looks at windows the user can see.
        val attachInfo = ReflectionHelpers.getField<Any>(activity.window.decorView, "mAttachInfo")
        ReflectionHelpers.setField(attachInfo, "mWindowVisibility", View.VISIBLE)
        assertEquals(1, Ui.visibleRoots().size)
        host = composeView.getChildAt(0)
        assertTrue("the host is an AndroidComposeView", ComposeTree.isHost(host))
    }

    @After
    fun restore() {
        ComposeTree.useLayoutNodes = true
        taps = 0
    }

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    // MARK: The tree

    @Test
    fun everyLayoutNodeIsInTheTree() {
        val content = ComposeTree.content(host, 0)
        println("Compose ${System.getProperty("voly.compose")}, layout nodes:\n" + dump(content.roots))
        assertTrue("read from layout nodes", content.complete)

        val card = item(content, tag = "card.0")
        assertEquals("Column", card.name())
        // Containers and spacers have no semantics; only the layout tree has them.
        assertEquals(listOf("Box", "Spacer", "Text", "Row", "Text", "Stamp", "Button"), card.children.map { it.name() })
        assertEquals("PAPERORA Kaco x Pure", card.children[2].label)
        assertEquals(listOf("Text", "Spacer", "Text"), card.children[3].children.map { it.name() })

        val button = card.children[6]
        assertEquals(listOf("Text"), button.children.map { it.name() })
        assertEquals("Sepete Ekle", button.children[0].label)

        assertEquals("LazyColumn", item(content, tag = "list").name())
        assertEquals("AndroidView", item(content, tag = "interop").name())
    }

    @Test
    fun framesAreTheBoxesTheEyeSees() {
        val content = ComposeTree.content(host, 0)
        val card = item(content, tag = "card.0")
        val price = item(content, tag = "price.0")
        val button = card.children[6]

        // padding(8).background().clickable().padding(12): the card is where its background is.
        assertEquals(8f * density, card.local.left, 0.5f)
        assertEquals((400f - 16f) * density, card.local.width(), 0.5f)
        // …and its content sits 12dp inside it.
        assertEquals(12f * density, price.local.left - card.local.left, 0.5f)
        // padding(top = 4) on a text is spacing around it, not part of it.
        val rating = card.children[3]
        assertEquals(4f * density, price.local.top - rating.local.bottom, 0.5f)
        // padding(top = 8).fillMaxWidth().height(36).border(): the button is the bordered box.
        assertEquals(36f * density, button.local.height(), 0.5f)
        assertEquals(8f * density, button.local.top - item(content, tag = "stamp.0").local.bottom, 0.5f)
        assertEquals(card.local.width() - 24f * density, button.local.width(), 0.5f)
    }

    @Test
    fun semanticsTakeOverWhenLayoutNodesCannotBeListed() {
        ComposeTree.useLayoutNodes = false
        val content = ComposeTree.content(host, 0)
        println("Compose ${System.getProperty("voly.compose")}, semantics only:\n" + dump(content.roots))
        assertFalse(content.complete)

        val card = item(content, tag = "card.0")
        // No Spacer, no Row: they say nothing to accessibility. (A Box with a
        // background does since Compose 1.9, which tells its shape.)
        assertEquals(
            listOf("Text", "Text", "Text", "Text", "Stamp", "Button"),
            card.children.map { it.name() }.filter { it != "Box" },
        )
        assertEquals("519 TL", item(content, tag = "price.0").label)

        // The same nodes, at the same place, under the same ids as in the full tree.
        ComposeTree.useLayoutNodes = true
        val full = ComposeTree.content(host, 0)
        for ((id, node) in content.byId) {
            val twin = full.byId[id]
            assertNotNull("${node.name()} ${node.label} is in the full tree", twin)
            assertEquals(twin!!.local, node.local)
            assertTrue(twin.ref === node.ref)
        }
    }

    @Test
    fun nodesScrolledOutOfSightAreNotClipped() {
        val content = ComposeTree.content(host, 0)
        val cards = content.byId.values.filter { it.testTag?.startsWith("card.") == true }
        assertTrue("more than one card is composed", cards.size >= 2)
        val heights = cards.map { it.local.height() }.toSet()
        assertEquals("every card has its whole frame, also the one cut off by the screen's edge", 1, heights.size)
    }

    // MARK: Through the protocol

    @Test
    fun theViewTreeContinuesIntoComposeContent() {
        val registry = ObjectRegistry()
        val snapshots = Snapshots(registry)
        val tree = snapshots.hierarchy(64)
        val hostNode = find(tree.windows()) { it.getString("className") == "AndroidComposeView" }!!
        val children = hostNode.getJSONArray("childrenInline").objects()
        assertEquals(hostNode.getJSONArray("childIDs").length(), children.size)

        val price = find(listOf(hostNode)) { it.optString("accessibilityIdentifier") == "price.0" }!!
        assertEquals("Text", price.getString("className"))
        assertEquals("519 TL", price.getString("label"))
        val card = find(listOf(hostNode)) { it.optString("accessibilityIdentifier") == "card.0" }!!
        // A frame is relative to the node above, in dp.
        val priceParent = find(listOf(hostNode)) { node ->
            node.optJSONArray("childrenInline")?.objects()?.any { it === price } == true
        }!!
        assertEquals("card.0", priceParent.getString("accessibilityIdentifier"))
        assertEquals(12.0, price.getJSONObject("frame").getDouble("x"), 0.3)
        assertEquals(
            card.getJSONObject("windowFrame").getDouble("x") + 12.0,
            price.getJSONObject("windowFrame").getDouble("x"), 0.3,
        )

        // Ids are the node's for as long as it is on screen, and unique in the tree.
        val again = snapshots.hierarchy(64)
        val priceAgain = find(again.windows()) { it.optString("accessibilityIdentifier") == "price.0" }!!
        assertEquals(price.getLong("id"), priceAgain.getLong("id"))
        val ids = mutableListOf<Long>()
        collect(tree.windows()) { ids += it.getLong("id") }
        assertEquals(ids.size, ids.toSet().size)

        // A node can be asked for by itself.
        val subtree = snapshots.subtree(card.getLong("id"), 1)
        assertEquals(7, subtree.getJSONArray("childrenInline").length())
        assertEquals(card.getJSONObject("windowFrame").toString(), subtree.getJSONObject("windowFrame").toString())
    }

    @Test
    fun pickingAndMeasuringReachIntoComposeContent() {
        val events = mutableListOf<JSONObject>()
        val dispatcher = Dispatcher { events += it }
        val tree = send(dispatcher, """{"getHierarchy":{}}""").getJSONObject("hierarchy").getJSONObject("_0")
        val price = find(tree.windows()) { it.optString("accessibilityIdentifier") == "price.0" }!!
        val card = find(tree.windows()) { it.optString("accessibilityIdentifier") == "card.0" }!!
        val frame = price.getJSONObject("windowFrame")
        val x = frame.getDouble("x") + frame.getDouble("width") / 2
        val y = frame.getDouble("y") + frame.getDouble("height") / 2

        // A point on the price selects the price, not the view it is drawn in.
        val selected = send(dispatcher, """{"selectAt":{"x":$x,"y":$y,"sceneID":0}}""")
        assertEquals(price.getLong("id"), selected.getJSONObject("selection").getLong("_0"))

        // With the card selected, hovering the price measures it against the card's edges.
        send(dispatcher, """{"highlight":{"objectID":${card.getLong("id")}}}""")
        val measured = send(dispatcher, """{"measureHover":{"anchorID":${card.getLong("id")},"x":$x,"y":$y,"sceneID":0}}""")
            .getJSONObject("measureHoverResult")
        assertEquals(price.getLong("id"), measured.getLong("otherID"))
        val summary = measured.getJSONObject("summary")
        assertEquals("containment", summary.getString("kind"))
        assertEquals(12.0, summary.getDouble("horizontal"), 0.3)

        // An embedded Android view is still a view.
        val embedded = find(tree.windows()) { it.getString("className") == "TextView" }!!
        val embeddedFrame = embedded.getJSONObject("windowFrame")
        val inside = send(
            dispatcher,
            """{"selectAt":{"x":${embeddedFrame.getDouble("x") + 2},"y":${embeddedFrame.getDouble("y") + 2},"sceneID":0}}""",
        )
        assertEquals(embedded.getLong("id"), inside.getJSONObject("selection").getLong("_0"))
        dispatcher.reset()
    }

    @Test
    fun tapsInPickModeSelectComposeContent() {
        val events = mutableListOf<JSONObject>()
        val dispatcher = Dispatcher { events += it }
        val tree = send(dispatcher, """{"getHierarchy":{}}""").getJSONObject("hierarchy").getJSONObject("_0")
        val button = find(tree.windows()) { it.getString("className") == "Button" }!!
        val frame = button.getJSONObject("windowFrame")
        send(dispatcher, """{"enterPickMode":{}}""")

        // Next to the label: the button itself. The app must not see the tap.
        tap((frame.getDouble("x") + 8) * density, (frame.getDouble("y") + 8) * density)
        assertEquals(button.getLong("id"), events.last().getJSONObject("selectionChanged").getLong("_0"))
        assertEquals(0, taps)

        // A spacer shows nothing: a tap on it is a tap on the card behind it.
        val card = find(tree.windows()) { it.optString("accessibilityIdentifier") == "card.0" }!!
        val spacer = find(listOf(card)) { it.getString("className") == "Spacer" }!!.getJSONObject("windowFrame")
        tap((spacer.getDouble("x") + 100) * density, (spacer.getDouble("y") + spacer.getDouble("height") / 2) * density)
        assertEquals(card.getLong("id"), events.last().getJSONObject("selectionChanged").getLong("_0"))

        send(dispatcher, """{"exitPickMode":{}}""")
        tap((frame.getDouble("x") + 8) * density, (frame.getDouble("y") + 8) * density)
        assertEquals("out of pick mode the tap is the app's again", 1, taps)
        dispatcher.reset()
    }

    @Test
    fun aListClipsWhatIsScrolledOutOfIt() {
        val content = ComposeTree.content(host, 0)
        val list = item(content, tag = "list")
        assertTrue(list.clips)
        // The last composed card reaches below the list; nothing is there to pick.
        val below = list.children.maxOf { it.local.bottom }
        assertTrue("a card is cut off by the list's edge", below > list.local.bottom)
        assertNull(ComposeTree.hit(host, 100f, list.local.bottom + 2f))
    }

    @Test
    fun aNodeCanBeCapturedByItself() {
        val dispatcher = Dispatcher { }
        val tree = send(dispatcher, """{"getHierarchy":{}}""").getJSONObject("hierarchy").getJSONObject("_0")
        val card = find(tree.windows()) { it.optString("accessibilityIdentifier") == "card.0" }!!
        var response: JSONObject? = null
        dispatcher.handle(JSONObject("""{"captureScreenshot":{"_0":{"view":{"_0":${card.getLong("id")}}}}}""")) { response = it }
        for (attempt in 0 until 50) {
            if (response != null) break
            idle()
            Thread.sleep(20)
        }
        val image = response!!.getJSONObject("screenshot").getJSONObject("_0")
        val frame = card.getJSONObject("windowFrame")
        assertEquals(frame.getDouble("width") * density, image.getDouble("pixelWidth"), 1.0)
        assertEquals(frame.getDouble("height") * density, image.getDouble("pixelHeight"), 1.0)
    }

    @Test
    fun readingALongListIsQuick() {
        // Not a benchmark: a guard against reading that grows with the square of the tree.
        ComposeTree.content(host, 0)
        val started = System.nanoTime()
        var nodes = 0
        repeat(200) { nodes = ComposeTree.content(host, 0).byId.size }
        val each = (System.nanoTime() - started) / 200 / 1_000_000.0
        println("Compose ${System.getProperty("voly.compose")}: $nodes nodes read in ${"%.2f".format(each)} ms")
        assertTrue("$each ms for $nodes nodes", each < 50)
    }

    @Test
    fun propertiesSayWhatANodeShowsAndHowItIsStyled() {
        val dispatcher = Dispatcher { }
        val tree = send(dispatcher, """{"getHierarchy":{}}""").getJSONObject("hierarchy").getJSONObject("_0")
        fun rows(tag: String): Map<String, JSONObject> {
            val node = find(tree.windows()) { it.optString("accessibilityIdentifier") == tag }!!
            val bag = send(dispatcher, """{"getProperties":{"objectID":${node.getLong("id")}}}""")
                .getJSONObject("properties").getJSONObject("_0")
            assertEquals(0, bag.getJSONObject("view").length())
            return bag.getJSONArray("custom").objects().associate {
                assertTrue(it.getBoolean("isReadOnly"))
                it.getString("name") to it.getJSONObject("currentValue")
            }
        }

        val title = rows("title.0")
        assertEquals("PAPERORA Kaco x Pure", title.string("text"))
        assertEquals(14.0, title.getValue("textSize").getJSONObject("double").getDouble("_0"), 0.01)
        assertEquals("Medium (500)", title.string("fontWeight"))
        val color = title.getValue("textColor").getJSONObject("color").getJSONObject("_0")
        assertEquals(0x33 / 255.0, color.getDouble("red"), 0.001)

        val card = rows("card.0")
        println("Compose ${System.getProperty("voly.compose")}, a card's properties:\n" + card.entries.joinToString("\n") { "  ${it.key} = ${it.value}" })
        assertEquals(true, card.getValue("isClickable").getJSONObject("bool").getBoolean("_0"))
        // Modifiers in the order they apply, each with its arguments.
        val names = card.keys.toList()
        assertTrue(names.indexOf("padding") < names.indexOf("background"))
        assertTrue(names.indexOf("background") < names.indexOf("padding 2"))
        assertTrue(card.string("padding").contains("8"))
        assertTrue(card.string("padding 2").contains("12"))
        val background = card.getValue("background").getJSONObject("color").getJSONObject("_0")
        assertEquals(1.0, background.getDouble("red"), 0.001)
        assertEquals("RoundedCornerShape(12dp)", card.string("backgroundShape"))

        // Nothing of it can be set, and it has no layout params.
        val cardId = find(tree.windows()) { it.optString("accessibilityIdentifier") == "card.0" }!!.getLong("id")
        val refused = send(
            dispatcher,
            """{"setProperty":{"_0":{"objectID":$cardId,"scope":"view","change":{"property":"alpha","value":{"double":{"_0":0.5}}}}}}""",
        )
        assertTrue(refused.toString(), refused.getJSONObject("error").getJSONObject("_0").has("unavailable"))
        val constraints = send(dispatcher, """{"getConstraints":{"objectID":$cardId}}""")
        assertEquals(0, constraints.getJSONObject("constraints").getJSONArray("_0").length())
        val source = send(dispatcher, """{"resolveSource":{"objectID":$cardId}}""")
        assertEquals("Column", source.getJSONObject("sourceInfo").getJSONObject("_0").getString("className"))
    }

    @Test
    fun anAppsOwnLayoutIsNamedAfterWhereItIsWritten() {
        val content = ComposeTree.content(host, 0)
        val stamp = item(content, tag = "stamp.0")
        assertEquals("Stamp", stamp.name())
        assertEquals(listOf("Text"), stamp.children.map { it.name() })
        // The file's class is what Jump to Source is given. (Whether a class
        // is the app's own can't be told here: Robolectric loads the app and
        // the platform with one class loader, a device doesn't.)
        val policy = Reflect.get(stamp.info, "getMeasurePolicy")
        assertEquals("com.example.shop.StampKt", Classes.fileClass(policy.javaClass).name)

        // The names compilers give such classes: Kotlin's own, and the Android build tools'.
        assertEquals("ProductCard", ComposeNames.clean("com.shop.ui.ProductCardKt\$ProductCard\$1\$1"))
        assertEquals("Badge", ComposeNames.clean("com.shop.ui.BadgeKt\$\$ExternalSyntheticLambda3"))
        assertEquals("Row", ComposeNames.clean("androidx.compose.foundation.layout.RowMeasurePolicy"))
        assertEquals("Box", ComposeNames.clean("androidx.compose.foundation.layout.BoxKt\$boxMeasurePolicy\$1"))
        assertEquals("Box", ComposeNames.clean("androidx.compose.foundation.layout.BoxKt\$EmptyBoxMeasurePolicy\$1"))
        assertEquals(
            "LazyList",
            ComposeNames.clean("androidx.compose.foundation.lazy.LazyListKt\$rememberLazyListMeasurePolicy\$1\$1"),
        )
        assertNull(ComposeNames.clean("androidx.compose.foundation.text.EmptyMeasurePolicy"))
    }

    @Test
    fun aSelectedNodeCanBeDescribedToAnAiAgent() {
        val dispatcher = Dispatcher { }
        val tree = send(dispatcher, """{"getHierarchy":{}}""").getJSONObject("hierarchy").getJSONObject("_0")
        fun describe(tag: String, depth: Int): JSONObject {
            val id = find(tree.windows()) { it.optString("accessibilityIdentifier") == tag }!!.getLong("id")
            return send(dispatcher, """{"describeScreen":{"_0":{"rootID":$id,"maxDepth":$depth}}}""")
                .getJSONObject("screenDescription").getJSONObject("_0")
        }

        // What `get_selection` asks for when the selection is Compose content.
        val screen = describe("title.0", 1)
        val title = screen.getJSONArray("roots").getJSONObject(0)
        assertEquals("Text", title.getString("className"))
        assertEquals("PAPERORA Kaco x Pure", title.getString("text"))
        assertEquals("Medium 14sp", title.getString("font"))
        assertEquals("#333333FF", title.getString("textColor"))
        val above = screen.getJSONArray("ancestors").objects().map { it.getString("className") }
        assertEquals(listOf("AndroidComposeView", "Column", "LazyColumn", "Column"), above.takeLast(4))

        val card = describe("card.0", 1).getJSONArray("roots").getJSONObject(0)
        assertEquals("#FFFFFFFF", card.getString("backgroundColor"))
        assertEquals(12.0, card.getDouble("cornerRadius"), 0.01)
        assertEquals(7, card.getJSONArray("children").length())
        assertEquals(1, card.getJSONArray("children").getJSONObject(6).getInt("omittedChildren"))
        val layout = card.getJSONObject("layout").getString("summary")
        println("Compose ${System.getProperty("voly.compose")}, a card's layout: $layout")
        assertTrue(layout, layout.contains("padding(horizontal 8dp, vertical 0dp) → background(#FFFFFFFF, RoundedCornerShape(12dp)) → "))
        assertTrue(layout, layout.contains(" → padding(12dp); size 384×"))

        // The whole screen is still told the way it was: views, with Compose content as what it says.
        val whole = send(dispatcher, """{"describeScreen":{"_0":{}}}""")
            .getJSONObject("screenDescription").getJSONObject("_0")
        val spoken = mutableListOf<String>()
        fun visit(node: JSONObject) {
            node.optJSONArray("accessibilityElements")?.objects()?.forEach { element ->
                element.optString("label").takeIf { it.isNotEmpty() }?.let { spoken += it }
            }
            node.getJSONArray("children").objects().forEach(::visit)
        }
        whole.getJSONArray("roots").objects().forEach(::visit)
        // A clickable card speaks for everything in it.
        assertTrue(spoken.toString(), spoken.any { it.contains("519 TL") })
    }

    @Test
    fun aNodeThatIsGoneStopsResolving() {
        val registry = ObjectRegistry()
        val snapshots = Snapshots(registry)
        val price = find(snapshots.hierarchy(64).windows()) { it.optString("accessibilityIdentifier") == "price.0" }!!
        val target = Target.of(registry.objectFor(price.getLong("id")))
        assertTrue(target.isAttached)

        activity.setContentView(View(activity))
        idle()
        assertFalse(target.isAttached)
        assertNull(target.rectOnScreen())
    }

    // MARK: Watching one node, secrets, transforms

    @Test
    fun aNodeThatIsWatchedIsAskedAgainWithoutReadingTheWholeHost() {
        val price = item(ComposeTree.content(host, 0), tag = "price.0")
        val target = Target.of(price.ref)
        val first = target.item()
        val before = target.rectInRoot()
        // Long after any tree that was read has been dropped, as a highlight that stays on is.
        shadowOf(Looper.getMainLooper()).idleFor(2, java.util.concurrent.TimeUnit.SECONDS)
        assertSame("the node itself was asked, no new tree was read", first, target.item())
        assertEquals(before, target.rectInRoot())

        show { BasicText("Nothing else") }
        assertFalse(ComposeTree.refresh(host, first))
        assertFalse(target.isAttached)
    }

    @Test
    fun whatIsTypedIntoAPasswordFieldStaysInTheApp() {
        // Marked as a password and nothing more: Compose hands out the text as it was typed.
        show {
            BasicTextField(
                value = "hunter2", onValueChange = {},
                modifier = Modifier.testTag("secret").semantics { password() },
            )
        }
        val dispatcher = Dispatcher { }
        val tree = send(dispatcher, """{"getHierarchy":{}}""")
        assertFalse("the tree", tree.toString().contains("hunter2"))
        val field = find(tree.getJSONObject("hierarchy").getJSONObject("_0").windows()) {
            it.optString("accessibilityIdentifier") == "secret"
        }!!
        val id = field.getLong("id")
        val bag = send(dispatcher, """{"getProperties":{"objectID":$id}}""").toString()
        assertFalse("its properties: $bag", bag.contains("hunter2"))
        assertTrue(bag, bag.contains("secure text, 7 characters"))
        val described = send(dispatcher, """{"describeScreen":{"_0":{"rootID":$id,"maxDepth":0}}}""").toString()
        assertFalse("its description: $described", described.contains("hunter2"))
    }

    @Test
    fun contentTurnedByAModifierSaysSo() {
        show {
            Column {
                Box(Modifier.testTag("tilted").rotate(30f).size(80.dp)) {
                    BasicText("turned", modifier = Modifier.testTag("turned"))
                }
                BasicText("level", modifier = Modifier.testTag("level"))
            }
        }
        val content = ComposeTree.content(host, 0)
        assertTrue(item(content, tag = "tilted").transformed)
        // What is inside is turned with it.
        assertTrue(Target.of(item(content, tag = "turned").ref).hasTransform())
        assertFalse(Target.of(item(content, tag = "level").ref).hasTransform())
    }

    // MARK: Helpers

    private fun show(content: @Composable () -> Unit) {
        (host.parent as ComposeView).setContent(content)
        idle()
    }

    private fun tap(x: Double, y: Double) {
        val now = SystemClock.uptimeMillis()
        for (action in intArrayOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
            val event = MotionEvent.obtain(now, now, action, x.toFloat(), y.toFloat(), 0)
            event.source = InputDevice.SOURCE_TOUCHSCREEN
            activity.window.callback.dispatchTouchEvent(event)
            event.recycle()
        }
        idle()
    }

    private fun send(dispatcher: Dispatcher, command: String): JSONObject {
        var response: JSONObject? = null
        dispatcher.handle(JSONObject(command)) { response = it }
        idle()
        return response!!
    }

    private fun item(content: ComposeTree.Content, tag: String): ComposeTree.Item =
        content.byId.values.firstOrNull { it.testTag == tag } ?: error("no node tagged $tag")

    private fun dump(items: List<ComposeTree.Item>, indent: String = "  "): String = items.joinToString("") { item ->
        val bounds = item.local
        val frame = "${bounds.left / density},${bounds.top / density} ${bounds.width() / density}x${bounds.height() / density}"
        val extras = listOfNotNull(item.testTag?.let { "#$it" }, item.label?.let { "\"$it\"" }).joinToString(" ")
        "$indent${item.name()} $extras [$frame]\n" + dump(item.children, "$indent  ")
    }

    private fun JSONObject.windows(): List<JSONObject> =
        getJSONArray("scenes").objects().flatMap { it.getJSONArray("windowsInline").objects() }

    private fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }

    private fun Map<String, JSONObject>.string(name: String): String =
        getValue(name).getJSONObject("string").getString("_0")

    private fun collect(nodes: List<JSONObject>, visit: (JSONObject) -> Unit) {
        for (node in nodes) {
            visit(node)
            node.optJSONArray("childrenInline")?.let { collect(it.objects(), visit) }
        }
    }

    private fun find(nodes: List<JSONObject>, matches: (JSONObject) -> Boolean): JSONObject? {
        for (node in nodes) {
            if (matches(node)) return node
            node.optJSONArray("childrenInline")?.let { children -> find(children.objects(), matches)?.let { return it } }
        }
        return null
    }
}

// What a shop's product list is made of, with the modifier orders that make frames interesting.

/** How often an "add to basket" button was tapped. */
private var taps = 0

@Composable
private fun Screen() {
    Column(Modifier.fillMaxSize().background(Color(0xFFF5F5F5))) {
        AndroidView(
            factory = { context -> TextView(context).apply { text = "A view inside Compose" } },
            modifier = Modifier.fillMaxWidth().height(40.dp).testTag("interop"),
        )
        LazyColumn(Modifier.fillMaxSize().testTag("list"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(6) { index -> ProductCard(index) }
        }
    }
}

@Composable
private fun ProductCard(index: Int) {
    Column(
        Modifier
            .testTag("card.$index")
            .fillMaxWidth()
            .padding(horizontal = 8.dp)
            .background(Color.White, RoundedCornerShape(12.dp))
            .clickable { }
            .padding(12.dp),
    ) {
        Box(Modifier.size(120.dp).background(Color.Gray))
        Spacer(Modifier.height(8.dp))
        BasicText(
            "PAPERORA Kaco x Pure",
            modifier = Modifier.testTag("title.$index"),
            style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Medium, color = Color(0xFF333333)),
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            BasicText("4.9")
            Spacer(Modifier.width(4.dp))
            BasicText("(138)")
        }
        BasicText("519 TL", modifier = Modifier.padding(top = 4.dp).testTag("price.$index"))
        Stamp(Modifier.testTag("stamp.$index")) { BasicText("İyi fiyat") }
        Box(
            Modifier
                .padding(top = 8.dp)
                .fillMaxWidth()
                .height(36.dp)
                .border(1.dp, Color(0xFFF27A1A), RoundedCornerShape(6.dp))
                .clickable(role = Role.Button) { taps++ },
            contentAlignment = Alignment.Center,
        ) {
            BasicText("Sepete Ekle")
        }
    }
}
