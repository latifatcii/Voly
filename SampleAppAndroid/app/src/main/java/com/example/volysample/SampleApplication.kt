package com.example.volysample

import android.app.Application

class SampleApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // Seed both preference files so they exist even if PrefsFragment is never opened.
        SamplePrefs.seedIfNeeded(this)
    }
}
