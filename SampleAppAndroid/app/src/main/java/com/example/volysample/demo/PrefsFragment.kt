package com.example.volysample.demo

import android.content.SharedPreferences
import android.os.Bundle
import android.view.View
import android.widget.SeekBar
import androidx.core.content.edit
import androidx.core.widget.doAfterTextChanged
import androidx.fragment.app.Fragment
import com.example.volysample.R
import com.example.volysample.SamplePrefs
import com.example.volysample.databinding.FragmentPrefsBinding
import kotlin.math.roundToInt

/**
 * Edits values in both preference files (see [SamplePrefs] for names and keys).
 * A control writes as soon as its value differs from what is stored; the dump at
 * the bottom shows what is stored.
 */
class PrefsFragment : Fragment(R.layout.fragment_prefs) {
    private val defaults get() = SamplePrefs.defaults(requireContext())
    private val settings get() = SamplePrefs.settings(requireContext())

    private val storedFlag get() = defaults.getBoolean(SamplePrefs.KEY_FLAG, false)
    private val storedName get() = defaults.getString(SamplePrefs.KEY_NAME, "").orEmpty()
    private val storedScale get() = settings.getFloat(SamplePrefs.KEY_TEXT_SCALE, 1f)
    private val storedFavorites get() = settings.getStringSet(SamplePrefs.KEY_FAVORITES, emptySet()).orEmpty()

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val binding = FragmentPrefsBinding.bind(view)
        val favoriteBoxes = mapOf(
            "constraint" to binding.prefsFavConstraint,
            "forms" to binding.prefsFavForms,
            "gallery" to binding.prefsFavGallery,
        )

        fun render() {
            binding.prefsCounterValue.text = defaults.getInt(SamplePrefs.KEY_COUNTER, 0).toString()
            binding.prefsScaleValue.text = storedScale.toString()
            binding.prefsLastSavedValue.text = settings.getLong(SamplePrefs.KEY_LAST_SAVED, 0L).toString()
            binding.prefsDump.text = dump(defaults.all) + "\n\n" + dump(settings.all)
        }

        /** Fills the controls from storage. The listeners below ignore values that are already stored. */
        fun load() {
            binding.prefsFlagSwitch.isChecked = storedFlag
            binding.prefsNameInput.setText(storedName)
            binding.prefsScaleSeekbar.progress = (storedScale * 100).roundToInt()
            val favorites = storedFavorites
            favoriteBoxes.forEach { (name, box) -> box.isChecked = name in favorites }
            render()
        }

        load()

        binding.prefsIncrementButton.setOnClickListener {
            defaults.edit { putInt(SamplePrefs.KEY_COUNTER, defaults.getInt(SamplePrefs.KEY_COUNTER, 0) + 1) }
            render()
        }
        binding.prefsFlagSwitch.setOnCheckedChangeListener { _, isChecked ->
            if (isChecked == storedFlag) return@setOnCheckedChangeListener
            defaults.edit { putBoolean(SamplePrefs.KEY_FLAG, isChecked) }
            render()
        }
        binding.prefsNameInput.doAfterTextChanged { text ->
            if (text.toString() == storedName) return@doAfterTextChanged
            defaults.edit { putString(SamplePrefs.KEY_NAME, text.toString()) }
            render()
        }
        binding.prefsScaleSeekbar.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
                if (progress / 100f == storedScale) return
                saveSetting { putFloat(SamplePrefs.KEY_TEXT_SCALE, progress / 100f) }
                render()
            }
            override fun onStartTrackingTouch(seekBar: SeekBar) = Unit
            override fun onStopTrackingTouch(seekBar: SeekBar) = Unit
        })
        favoriteBoxes.values.forEach { box ->
            box.setOnCheckedChangeListener { _, _ ->
                val favorites = favoriteBoxes.filterValues { it.isChecked }.keys
                if (favorites == storedFavorites) return@setOnCheckedChangeListener
                saveSetting { putStringSet(SamplePrefs.KEY_FAVORITES, favorites) }
                render()
            }
        }
        binding.prefsResetButton.setOnClickListener {
            SamplePrefs.reset(requireContext())
            load()
        }
    }

    /** Writes to `voly_sample_settings` and stamps `last_saved_at`. */
    private fun saveSetting(change: SharedPreferences.Editor.() -> Unit) = settings.edit {
        change()
        putLong(SamplePrefs.KEY_LAST_SAVED, System.currentTimeMillis())
    }

    private fun dump(values: Map<String, *>): String =
        values.toSortedMap().entries.joinToString("\n") { (key, value) ->
            "$key = $value (${value?.javaClass?.simpleName})"
        }
}
