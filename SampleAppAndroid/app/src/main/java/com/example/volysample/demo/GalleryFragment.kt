package com.example.volysample.demo

import android.graphics.Color
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.fragment.app.Fragment
import androidx.recyclerview.widget.RecyclerView
import com.example.volysample.R
import com.example.volysample.databinding.FragmentGalleryBinding
import com.example.volysample.databinding.ItemGalleryCellBinding

/** A 3-column grid (GridLayoutManager is set in the layout) of [CELL_COUNT] colored cells. */
class GalleryFragment : Fragment(R.layout.fragment_gallery) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        FragmentGalleryBinding.bind(view).galleryGrid.adapter = CellAdapter()
    }

    private class CellAdapter : RecyclerView.Adapter<CellAdapter.Holder>() {
        class Holder(val binding: ItemGalleryCellBinding) : RecyclerView.ViewHolder(binding.root)

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) =
            Holder(ItemGalleryCellBinding.inflate(LayoutInflater.from(parent.context), parent, false))

        override fun getItemCount() = CELL_COUNT

        override fun onBindViewHolder(holder: Holder, position: Int) {
            val hue = position * 360f / CELL_COUNT
            holder.binding.galleryCell.setCardBackgroundColor(Color.HSVToColor(floatArrayOf(hue, 0.55f, 0.75f)))
            holder.binding.galleryCellLabel.text =
                holder.itemView.context.getString(R.string.gallery_cell_label, position + 1)
        }
    }

    private companion object {
        const val CELL_COUNT = 40
    }
}
