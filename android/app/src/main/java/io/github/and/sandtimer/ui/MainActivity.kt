package io.github.and.sandtimer.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsIgnoringVisibility
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsIgnoringVisibility
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.remember
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.HourglassBottom
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import io.github.and.sandtimer.data.Store
import io.github.and.sandtimer.link.Link
import io.github.and.sandtimer.timer.Engine

/** Night-desk colours: the glass shows best on dark. */
val Ink = Color(0xFF12161C)
val Panel = Color(0xFF1C222B)
val Amber = Color(0xFFD9A441)

class MainActivity : ComponentActivity() {
    private val askNotifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent?.getBooleanExtra(SHOW_TIMER, false) == true) showTimer.value++
        enableEdgeToEdge()
        Store.init(this)
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        setContent {
            MaterialTheme(colorScheme = darkColorScheme(primary = Amber, background = Ink, surface = Ink, surfaceContainer = Panel)) {
                App()
            }
        }
    }

    /** Opened again to show a timer the Mac just started: the Timer tab, whichever was showing. */
    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        if (intent.getBooleanExtra(SHOW_TIMER, false)) showTimer.value++
    }

    companion object {
        const val SHOW_TIMER = "showTimer"
        /** Bumped each time the Timer tab should come to the front. */
        val showTimer = kotlinx.coroutines.flow.MutableStateFlow(0)
    }

    override fun onResume() {
        super.onResume()
        Engine.refresh(this)
        Link.wake()
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun App() {
    var tab by rememberSaveable { mutableIntStateOf(0) }
    val showTimer by MainActivity.showTimer.collectAsState()
    LaunchedEffect(showTimer) { if (showTimer > 0) tab = 0 }
    val calm by Calm.hidden.collectAsState()
    val shown by animateFloatAsState(if (calm) 0f else 1f, tween(if (calm) 900 else 200), label = "bars")
    // The phone's own bars go too in the clean view; a swipe from the edge brings them back for a moment.
    val view = LocalView.current
    LaunchedEffect(calm) {
        val window = (view.context as? android.app.Activity)?.window ?: return@LaunchedEffect
        val bars = WindowCompat.getInsetsController(window, view)
        bars.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        if (calm) bars.hide(WindowInsetsCompat.Type.systemBars()) else bars.show(WindowInsetsCompat.Type.systemBars())
    }
    Box(Modifier.fillMaxSize()) {
    Scaffold(
        containerColor = Ink,
        // The same room whether the bars show or not, so the glass doesn't jump as they come and go.
        contentWindowInsets = WindowInsets.systemBarsIgnoringVisibility,
        bottomBar = {
            NavigationBar(containerColor = Panel, modifier = Modifier.alpha(shown), windowInsets = WindowInsets.navigationBarsIgnoringVisibility) {
                listOf("Timer" to Icons.Filled.HourglassBottom, "Statistics" to Icons.Filled.BarChart, "Settings" to Icons.Filled.Settings)
                    .forEachIndexed { index, (title, icon) ->
                        NavigationBarItem(
                            selected = tab == index, onClick = { tab = index },
                            icon = { Icon(icon, contentDescription = null) }, label = { Text(title) },
                        )
                    }
            }
        },
    ) { padding ->
        val modifier = Modifier.padding(padding)
        when (tab) {
            0 -> TimerScreen(modifier)
            1 -> StatsScreen(modifier)
            else -> SettingsScreen(modifier)
        }
    }
    // While everything is hidden, a touch anywhere only brings it back: nothing invisible gets pressed by mistake.
    if (calm) {
        Box(Modifier.fillMaxSize().clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { Calm.wake() })
    }
    }
}
