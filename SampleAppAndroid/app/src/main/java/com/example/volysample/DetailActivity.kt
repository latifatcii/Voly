package com.example.volysample

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import com.example.volysample.databinding.ActivityDetailBinding

/** A second activity: title + body, with an Up button back to [MainActivity]. */
class DetailActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val binding = ActivityDetailBinding.inflate(layoutInflater)
        setContentView(binding.root)
        binding.root.applySystemBarInsets()
        setSupportActionBar(binding.detailToolbar)
        supportActionBar?.setDisplayHomeAsUpEnabled(true)

        binding.detailTitle.text = intent.getStringExtra(EXTRA_TITLE) ?: getString(R.string.detail_default_title)
        binding.detailBody.text = intent.getStringExtra(EXTRA_BODY) ?: getString(R.string.detail_default_body)
    }

    override fun onSupportNavigateUp(): Boolean {
        finish()
        return true
    }

    companion object {
        const val EXTRA_TITLE = "title"
        const val EXTRA_BODY = "body"

        fun intent(context: Context, title: String?, body: String? = null): Intent =
            Intent(context, DetailActivity::class.java)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_BODY, body)
    }
}
