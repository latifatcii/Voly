package com.example.shop

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout

/**
 * An app's own layout, in an app's own package: the one kind of Compose
 * node whose source the agent can point at, because the class of its
 * measure policy is named after this file.
 */
@Composable
fun Stamp(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Layout(content, modifier) { measurables, constraints ->
        val placeables = measurables.map { it.measure(constraints.copy(minWidth = 0, minHeight = 0)) }
        val width = placeables.maxOfOrNull { it.width } ?: 0
        val height = placeables.maxOfOrNull { it.height } ?: 0
        layout(width, height) { placeables.forEach { it.place(0, 0) } }
    }
}
