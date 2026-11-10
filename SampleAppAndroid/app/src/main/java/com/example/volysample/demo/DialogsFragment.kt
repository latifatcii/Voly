package com.example.volysample.demo

import android.os.Bundle
import android.view.View
import androidx.appcompat.widget.PopupMenu
import androidx.fragment.app.Fragment
import com.example.volysample.R
import com.example.volysample.databinding.FragmentDialogsBinding
import com.example.volysample.databinding.SheetSampleBinding
import com.google.android.material.bottomsheet.BottomSheetDialogFragment
import com.google.android.material.dialog.MaterialAlertDialogBuilder

class DialogsFragment : Fragment(R.layout.fragment_dialogs) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val binding = FragmentDialogsBinding.bind(view)

        binding.dialogsAlertButton.setOnClickListener {
            MaterialAlertDialogBuilder(requireContext())
                .setTitle(R.string.dialogs_alert_title)
                .setMessage(R.string.dialogs_alert_message)
                .setPositiveButton(android.R.string.ok) { _, _ -> binding.dialogsResult.setText(R.string.dialogs_result_ok) }
                .setNegativeButton(android.R.string.cancel) { _, _ -> binding.dialogsResult.setText(R.string.dialogs_result_cancel) }
                .show()
        }

        binding.dialogsSheetButton.setOnClickListener {
            SampleBottomSheet().show(childFragmentManager, SampleBottomSheet.TAG)
        }

        binding.dialogsPopupButton.setOnClickListener { anchor ->
            PopupMenu(requireContext(), anchor).apply {
                inflate(R.menu.popup_sample)
                setOnMenuItemClickListener { item ->
                    binding.dialogsResult.text = getString(R.string.dialogs_result_menu, item.title)
                    true
                }
            }.show()
        }
    }
}

class SampleBottomSheet : BottomSheetDialogFragment(R.layout.sheet_sample) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        SheetSampleBinding.bind(view).sheetCloseButton.setOnClickListener { dismiss() }
    }

    companion object {
        const val TAG = "sample_sheet"
    }
}
