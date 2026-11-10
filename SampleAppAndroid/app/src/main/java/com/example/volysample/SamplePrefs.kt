package com.example.volysample

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit

/** The two SharedPreferences files the sample writes, and their keys. */
object SamplePrefs {
    const val SETTINGS_FILE = "voly_sample_settings"

    // Default file: <package>_preferences
    const val KEY_COUNTER = "counter"                 // Int
    const val KEY_FLAG = "flag_enabled"               // Boolean
    const val KEY_NAME = "display_name"               // String
    const val KEY_FIRST_LAUNCH = "first_launch_at"    // Long

    // voly_sample_settings
    const val KEY_TEXT_SCALE = "text_scale"           // Float
    const val KEY_LAST_SAVED = "last_saved_at"        // Long
    const val KEY_FAVORITES = "favorite_demos"        // Set<String>
    const val KEY_THEME = "theme_name"                // String
    const val KEY_SCHEMA = "schema_version"           // Int

    val initialFavorites = setOf("constraint", "forms")

    /** Same file `PreferenceManager.getDefaultSharedPreferences` would use. */
    fun defaults(context: Context): SharedPreferences =
        context.getSharedPreferences(context.packageName + "_preferences", Context.MODE_PRIVATE)

    fun settings(context: Context): SharedPreferences =
        context.getSharedPreferences(SETTINGS_FILE, Context.MODE_PRIVATE)

    fun seedIfNeeded(context: Context) {
        if (!defaults(context).contains(KEY_COUNTER)) writeInitialDefaults(context)
        if (!settings(context).contains(KEY_SCHEMA)) writeInitialSettings(context)
    }

    fun reset(context: Context) {
        writeInitialDefaults(context)
        writeInitialSettings(context)
    }

    private fun writeInitialDefaults(context: Context) = defaults(context).edit {
        clear()
        putInt(KEY_COUNTER, 0)
        putBoolean(KEY_FLAG, true)
        putString(KEY_NAME, "Voly Tester")
        putLong(KEY_FIRST_LAUNCH, System.currentTimeMillis())
    }

    private fun writeInitialSettings(context: Context) = settings(context).edit {
        clear()
        putFloat(KEY_TEXT_SCALE, 1.25f)
        putLong(KEY_LAST_SAVED, 0L)
        putStringSet(KEY_FAVORITES, initialFavorites)
        putString(KEY_THEME, "system")
        putInt(KEY_SCHEMA, 1)
    }
}
