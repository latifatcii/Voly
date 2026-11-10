package com.example.volysample.demo

import android.os.Bundle
import android.view.View
import android.widget.SeekBar
import androidx.fragment.app.Fragment
import com.example.volysample.R
import com.example.volysample.databinding.FragmentFormsBinding

class FormControlsFragment : Fragment(R.layout.fragment_forms) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val binding = FragmentFormsBinding.bind(view)

        binding.formsSeekbar.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
                binding.formsProgress.progress = progress
                binding.formsSeekbarValue.text = getString(R.string.forms_volume_value, progress)
            }
            override fun onStartTrackingTouch(seekBar: SeekBar) = Unit
            override fun onStopTrackingTouch(seekBar: SeekBar) = Unit
        })
        binding.formsSeekbarValue.text = getString(R.string.forms_volume_value, binding.formsSeekbar.progress)

        binding.formsSubmitButton.setOnClickListener {
            binding.formsStatus.text = getString(
                R.string.forms_status_submitted,
                binding.formsNameInput.text.toString(),
                binding.formsSwitch.isChecked.toString(),
                binding.formsSpinner.selectedItem.toString(),
            )
        }
    }
}
