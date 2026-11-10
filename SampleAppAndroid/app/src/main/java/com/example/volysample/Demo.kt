package com.example.volysample

import androidx.annotation.StringRes
import androidx.fragment.app.Fragment
import com.example.volysample.demo.ComposeDemoFragment
import com.example.volysample.demo.ConstraintDemoFragment
import com.example.volysample.demo.DialogsFragment
import com.example.volysample.demo.FormControlsFragment
import com.example.volysample.demo.GalleryFragment
import com.example.volysample.demo.LayoutProblemsFragment
import com.example.volysample.demo.LocalizationFragment
import com.example.volysample.demo.PrefsFragment

/**
 * The demo screens, in list order. [route] is the deep-link name
 * (`volysample://demo/<route>`), the fragment tag and the back stack entry name.
 */
enum class Demo(
    val route: String,
    @param:StringRes val title: Int,
    @param:StringRes val subtitle: Int,
    val color: Int,
    val create: () -> Fragment,
) {
    CONSTRAINT("constraint", R.string.demo_constraint_title, R.string.demo_constraint_subtitle, 0xFF3F51B5.toInt(), ::ConstraintDemoFragment),
    FORMS("forms", R.string.demo_forms_title, R.string.demo_forms_subtitle, 0xFF00897B.toInt(), ::FormControlsFragment),
    LOCALIZATION("localization", R.string.demo_localization_title, R.string.demo_localization_subtitle, 0xFFF4511E.toInt(), ::LocalizationFragment),
    PROBLEMS("problems", R.string.demo_problems_title, R.string.demo_problems_subtitle, 0xFFD81B60.toInt(), ::LayoutProblemsFragment),
    GALLERY("gallery", R.string.demo_gallery_title, R.string.demo_gallery_subtitle, 0xFF8E24AA.toInt(), ::GalleryFragment),
    COMPOSE("compose", R.string.demo_compose_title, R.string.demo_compose_subtitle, 0xFF43A047.toInt(), ::ComposeDemoFragment),
    DIALOGS("dialogs", R.string.demo_dialogs_title, R.string.demo_dialogs_subtitle, 0xFF6D4C41.toInt(), ::DialogsFragment),
    PREFS("prefs", R.string.demo_prefs_title, R.string.demo_prefs_subtitle, 0xFF546E7A.toInt(), ::PrefsFragment);

    companion object {
        fun fromRoute(route: String?): Demo? = entries.firstOrNull { it.route == route }
    }
}
