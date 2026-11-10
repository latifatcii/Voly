package com.example.volysample.demo

import android.os.Bundle
import android.view.View
import androidx.appcompat.app.AppCompatDelegate
import androidx.core.os.LocaleListCompat
import androidx.fragment.app.Fragment
import com.example.volysample.DetailActivity
import com.example.volysample.R
import com.example.volysample.databinding.FragmentLocalizationBinding

class LocalizationFragment : Fragment(R.layout.fragment_localization) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val binding = FragmentLocalizationBinding.bind(view)
        val locale = resources.configuration.locales[0]

        binding.locGreeting.text = getString(R.string.loc_greeting, "Voly")
        binding.locCurrentLocale.text = getString(R.string.loc_current_locale, locale.toLanguageTag())
        binding.locItemsCount.text = resources.getQuantityString(R.plurals.loc_items_count, 3, 3)

        binding.locDetailsButton.setOnClickListener {
            startActivity(
                DetailActivity.intent(
                    requireContext(),
                    getString(R.string.loc_detail_title),
                    getString(R.string.loc_long_text),
                )
            )
        }

        // Per-app language; an empty tag list means "follow the system".
        mapOf(
            binding.locLangSystem to "",
            binding.locLangEn to "en",
            binding.locLangTr to "tr",
            binding.locLangFr to "fr",
            binding.locLangAr to "ar",
        ).forEach { (button, tag) ->
            button.setOnClickListener {
                AppCompatDelegate.setApplicationLocales(LocaleListCompat.forLanguageTags(tag))
            }
        }
    }
}
