package com.example.volysample

import android.content.Intent
import android.os.Bundle
import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.isVisible
import androidx.fragment.app.FragmentManager
import androidx.fragment.app.commit
import androidx.recyclerview.widget.DividerItemDecoration
import androidx.recyclerview.widget.RecyclerView
import com.example.volysample.databinding.ActivityMainBinding
import com.example.volysample.databinding.ItemDemoBinding

/**
 * Toolbar + the list of demos. A demo is a fragment pushed on the back stack
 * into `demo_container`; the list is hidden while one is showing.
 */
class MainActivity : AppCompatActivity() {
    private lateinit var binding: ActivityMainBinding

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        binding.root.applySystemBarInsets()
        setSupportActionBar(binding.mainToolbar)

        binding.demoList.adapter = DemoAdapter(Demo.entries, ::openDemo)
        binding.demoList.addItemDecoration(DividerItemDecoration(this, DividerItemDecoration.VERTICAL))

        supportFragmentManager.addOnBackStackChangedListener(::syncChrome)
        syncChrome()

        if (savedInstanceState == null) handleDeepLink(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleDeepLink(intent)
    }

    override fun onSupportNavigateUp(): Boolean {
        supportFragmentManager.popBackStack()
        return true
    }

    /** `volysample://demo/<route>` opens a demo, `volysample://detail?title=…&body=…` the detail screen. */
    private fun handleDeepLink(intent: Intent?) {
        val uri = intent?.data?.takeIf { it.scheme == "volysample" } ?: return
        when (uri.host) {
            "demo" -> Demo.fromRoute(uri.lastPathSegment)?.let(::openDemo)
            "detail" -> startActivity(
                DetailActivity.intent(this, uri.getQueryParameter("title"), uri.getQueryParameter("body"))
            )
        }
    }

    private fun openDemo(demo: Demo) {
        val fragments = supportFragmentManager
        // A deep link may arrive while another demo is showing: back should still return to the list.
        fragments.popBackStack(null, FragmentManager.POP_BACK_STACK_INCLUSIVE)
        fragments.commit {
            setReorderingAllowed(true)
            replace(R.id.demo_container, demo.create(), demo.route)
            addToBackStack(demo.route)
        }
    }

    /** Title, Up arrow and list visibility follow the top of the back stack. */
    private fun syncChrome() {
        val fragments = supportFragmentManager
        val count = fragments.backStackEntryCount
        val current = if (count > 0) Demo.fromRoute(fragments.getBackStackEntryAt(count - 1).name) else null
        supportActionBar?.title = getString(current?.title ?: R.string.app_name)
        supportActionBar?.setDisplayHomeAsUpEnabled(current != null)
        binding.demoList.isVisible = current == null
    }
}

private class DemoAdapter(
    private val demos: List<Demo>,
    private val onClick: (Demo) -> Unit,
) : RecyclerView.Adapter<DemoAdapter.Holder>() {

    class Holder(val binding: ItemDemoBinding) : RecyclerView.ViewHolder(binding.root)

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) =
        Holder(ItemDemoBinding.inflate(LayoutInflater.from(parent.context), parent, false))

    override fun getItemCount() = demos.size

    override fun onBindViewHolder(holder: Holder, position: Int) {
        val demo = demos[position]
        with(holder.binding) {
            demoBadge.badgeText = (position + 1).toString()
            demoBadge.badgeColor = demo.color
            demoTitle.setText(demo.title)
            demoSubtitle.setText(demo.subtitle)
            root.setOnClickListener { onClick(demo) }
        }
    }
}
