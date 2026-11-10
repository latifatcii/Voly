# Voly Sample (Android)

A small Android app to point Voly's inspector at. It is the Android counterpart of
`SampleApp/`: a handful of screens that exercise what an inspector looks at (view
tree and ids, layout params, custom views, Compose, dialogs, localization, RTL,
SharedPreferences, fragment and activity navigation). It is a test fixture, not a product.

Package: `com.example.volysample` (debug build, debuggable).

## Build and install

Needs JDK 17+ and the Android SDK (`platforms;android-35`, `build-tools;35.0.0`)
with `ANDROID_HOME` set.

```sh
./gradlew :app:assembleDebug   # app/build/outputs/apk/debug/app-debug.apk
./gradlew :app:installDebug    # install on the running emulator or device
```

## Screens

`MainActivity` shows a list of demos. Each demo is a fragment pushed on the back
stack; back returns to the list.

| Deep-link name | Fragment | What it shows |
| --- | --- | --- |
| `constraint` | `ConstraintDemoFragment` | ConstraintLayout: margins, bias, 0dp, ratio, guideline, barrier |
| `forms` | `FormControlsFragment` | EditText, password, switch, checkbox, seek bar, radio group, spinner, buttons |
| `localization` | `LocalizationFragment` | Strings in English, Turkish, French and Arabic (RTL); in-app language switch |
| `problems` | `LayoutProblemsFragment` | Truncated text, zero-size, off-screen, translucent, invisible and gone views |
| `gallery` | `GalleryFragment` | 3-column grid of 40 cells |
| `compose` | `ComposeDemoFragment` | A Jetpack Compose (Material 3) screen in a `ComposeView` |
| `dialogs` | `DialogsFragment` | Alert dialog, bottom sheet, popup menu |
| `prefs` | `PrefsFragment` | Reads and writes two SharedPreferences files |

`DetailActivity` is a second activity, opened from the localization screen
("Show details") or by deep link.

## Deep links

```sh
adb shell am start -a android.intent.action.VIEW -d volysample://demo/forms
adb shell am start -a android.intent.action.VIEW -d "volysample://detail?title=Hello"
```

`volysample://demo/<name>` takes the names in the table above.
`volysample://detail` takes `title` and an optional `body`.

## SharedPreferences

Both files are written on first launch (`SampleApplication`), so they exist even
if the preferences screen is never opened. Keys are listed in `SamplePrefs.kt`.

- `com.example.volysample_preferences` (the default file): `counter` (Int),
  `flag_enabled` (Boolean), `display_name` (String), `first_launch_at` (Long)
- `voly_sample_settings`: `text_scale` (Float), `last_saved_at` (Long),
  `favorite_demos` (String set), `theme_name` (String), `schema_version` (Int)

## Languages

Per-app language can be changed from the localization screen, from the system
settings, or with:

```sh
adb shell cmd locale set-app-locales com.example.volysample --locales ar
```
