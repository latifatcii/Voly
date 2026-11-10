package com.example.volysample.demo

import android.os.Bundle
import android.view.View
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ViewCompositionStrategy
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.unit.dp
import androidx.fragment.app.Fragment
import com.example.volysample.R
import com.example.volysample.databinding.FragmentComposeBinding

/** The one Compose screen, hosted in a ComposeView inside a regular fragment. */
class ComposeDemoFragment : Fragment(R.layout.fragment_compose) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        FragmentComposeBinding.bind(view).composeView.apply {
            setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnViewTreeLifecycleDestroyed)
            setContent { ComposeDemo() }
        }
    }
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun ComposeDemo() {
    var clicks by rememberSaveable { mutableIntStateOf(0) }
    var switchOn by rememberSaveable { mutableStateOf(true) }
    var checked by rememberSaveable { mutableStateOf(false) }
    var note by rememberSaveable { mutableStateOf("") }

    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme()) {
        // testTagsAsResourceId exposes the test tags as accessibility resource ids.
        Surface(Modifier.fillMaxSize().semantics { testTagsAsResourceId = true }) {
            Column(
                modifier = Modifier.padding(16.dp).testTag("compose.column"),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(
                    text = stringResource(R.string.compose_title),
                    style = MaterialTheme.typography.headlineSmall,
                    modifier = Modifier.testTag("compose.title"),
                )
                Button(onClick = { clicks++ }, modifier = Modifier.testTag("compose.button")) {
                    Text(stringResource(R.string.compose_button, clicks))
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.testTag("compose.toggles"),
                ) {
                    Switch(checked = switchOn, onCheckedChange = { switchOn = it }, modifier = Modifier.testTag("compose.switch"))
                    Checkbox(checked = checked, onCheckedChange = { checked = it }, modifier = Modifier.testTag("compose.checkbox"))
                    Text(stringResource(R.string.compose_toggles_state, switchOn.toString(), checked.toString()))
                }
                TextField(
                    value = note,
                    onValueChange = { note = it },
                    label = { Text(stringResource(R.string.compose_note_label)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().testTag("compose.textfield"),
                )
                LazyColumn(modifier = Modifier.weight(1f).testTag("compose.list")) {
                    items(ROW_COUNT) { index ->
                        Text(
                            text = stringResource(R.string.compose_row, index + 1),
                            modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp).testTag("compose.row.$index"),
                        )
                        HorizontalDivider()
                    }
                }
            }
        }
    }
}

private const val ROW_COUNT = 8
