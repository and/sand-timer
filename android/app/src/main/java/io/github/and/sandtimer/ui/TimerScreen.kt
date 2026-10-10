package io.github.and.sandtimer.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.runtime.mutableStateOf
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.ui.draw.alpha
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.background
import androidx.compose.runtime.withFrameMillis
import io.github.and.sandtimer.data.ProjectList
import io.github.and.sandtimer.data.SandLog
import io.github.and.sandtimer.data.Store
import io.github.and.sandtimer.timer.Engine
import io.github.and.sandtimer.timer.Notifications
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.LocalDate

/** The lengths offered at a tap, the Mac's menu among them: a 25-minute Pomodoro, and 6 and 12 for billing time. */
private val lengths = listOf(5, 6, 10, 12, 15, 25, 30, 45, 60)

@Composable
fun TimerScreen(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val app by Store.state.collectAsState()
    val state = app.timer.state
    val scope = rememberCoroutineScope()

    // The clock the drawing follows: every frame while the sand runs, once a second otherwise.
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    val running = state.isRunning(now)
    LaunchedEffect(running) {
        while (true) {
            if (running) withFrameMillis { now = System.currentTimeMillis() } else { now = System.currentTimeMillis(); delay(1000) }
            val until = Store.state.value.timer.state.runningUntil
            if (until != null && now >= until) Engine.settle(context)
        }
    }

    // Awake while the sand runs, if wanted: a glass you can't see is no use.
    val view = LocalView.current
    val awake = running && app.settings.keepScreenOn
    DisposableEffect(awake) {
        view.keepScreenOn = awake
        onDispose { view.keepScreenOn = false }
    }

    // The clean view: everything but the glass fades while the sand runs and the phone is still.
    Calm.Watch(running && app.settings.calm)
    val calm by Calm.hidden.collectAsState()
    val controls by animateFloatAsState(if (calm) 0f else 1f, tween(if (calm) 900 else 200), label = "controls")
    // Where the glass sits among the controls, and how far that is from the middle of the screen.
    var glassCenter by remember { mutableStateOf(Offset.Zero) }
    val screen = LocalWindowInfo.current.containerSize
    val centring = if (glassCenter == Offset.Zero) Offset.Zero else Offset(screen.width / 2f, screen.height / 2f) - glassCenter

    val paused = state.isPaused(now)
    // A pause lays the glass on its side; a flip turns it over before the sand starts to run.
    val tilt = remember { Animatable(if (paused) 90f else 0f) }
    LaunchedEffect(paused) { tilt.animateTo(if (paused) 90f else 0f, tween(450, easing = FastOutSlowInEasing)) }
    val flip = remember { Animatable(0f) }
    var flipping by remember { mutableLongStateOf(0L) }

    fun press() {
        if (!state.inSession(System.currentTimeMillis())) {
            scope.launch {
                flipping = 1
                flip.snapTo(0f)
                flip.animateTo(180f, tween(650, easing = FastOutSlowInEasing))
                Engine.start(context)
                flip.snapTo(0f)
                flipping = 0
            }
        } else {
            Engine.tap(context)
        }
    }

    val project = app.projects.project(app.activeProject)
    val sessionProject = app.projects.project(state.project)
    val sand = sandColor((if (state.inSession(now)) sessionProject else project)?.color)
    val canSwitch = !app.settings.oneThingAtATime || !state.inSession(now)

    Column(modifier.fillMaxSize().padding(horizontal = 16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Spacer(Modifier.height(12.dp))
        Column(Modifier.alpha(controls), horizontalAlignment = Alignment.CenterHorizontally) {
            ProjectChips(app.projects, app.activeProject, enabled = canSwitch) { Store.setActiveProject(it) }
            if (!canSwitch) {
                Text("End the session to switch projects.", color = Color.White.copy(alpha = 0.45f), fontSize = 12.sp)
            }
        }

        val left = if (state.inSession(now)) state.remaining(now) else state.minutes * 60_000L
        // The record is written at each pause and end; the stretch running now counts on screen as it goes.
        val counting = state.countedFrom?.let { (minOf(now, state.runningUntil ?: now) - it).coerceAtLeast(0) / 1000.0 } ?: 0.0
        val target = app.settings.targetMinutes
        val goal = if (target > 0) (app.wholeLog.on(LocalDate.now()).seconds + counting) / (target * 60.0) else null
        Box(
            Modifier.weight(1f).fillMaxWidth()
                .onGloballyPositioned { glassCenter = it.boundsInWindow().center }
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { if (flipping == 0L) press() },
            contentAlignment = Alignment.Center,
        ) {
            Hourglass(
                fallen = if (flipping != 0L) 1f else state.fallen(now).toFloat(),
                angle = if (flipping != 0L) flip.value else tilt.value,
                running = running && flipping == 0L,
                sand = sand,
                minutes = state.minutes,
                // The time printed on the base, the project on the top cap, and the day's target along the plate, as on the Mac.
                display = Display(Notifications.clock(left), ((if (state.inSession(now)) sessionProject else project)?.name), goal),
                time = now / 1000.0,
                // In the clean view the glass glides to the middle of the screen, the bars and controls gone.
                modifier = Modifier.fillMaxSize().padding(vertical = 8.dp).graphicsLayer {
                    translationX = centring.x * (1 - controls)
                    translationY = centring.y * (1 - controls)
                },
            )
        }

        Column(Modifier.alpha(controls), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            when {
                running -> sessionProject?.name ?: "Running"
                paused -> "Paused · ${Notifications.clock(left)} left"
                else -> "Tap the glass to start"
            },
            color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp,
        )
        Spacer(Modifier.height(12.dp))

        if (state.inSession(now)) {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(onClick = { Engine.tap(context) }) { Text(if (running) "Pause" else "Resume") }
                OutlinedButton(onClick = { Engine.end(context) }) { Text("End Session") }
            }
        } else {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                for (m in lengths) {
                    FilterChip(
                        selected = state.minutes == m, onClick = { Engine.setMinutes(context, m) },
                        label = { Text(if (m == 25) "25 🍅" else "$m") },
                    )
                }
            }
        }

        Today(app.wholeLog, counting, target)
        }
        Spacer(Modifier.height(8.dp))
    }
}

@Composable
private fun ProjectChips(projects: ProjectList, active: String?, enabled: Boolean, choose: (String?) -> Unit) {
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        val choices = listOf(null) + projects.visible.map { it.id }
        for (id in choices) {
            val p = projects.project(id)
            FilterChip(
                selected = active == id, enabled = enabled || active == id, onClick = { choose(id) },
                leadingIcon = {
                    Box(Modifier.size(10.dp).clip(CircleShape).background(if (p == null) Color.Gray else sandColor(p.color)))
                },
                label = { Text(p?.name ?: ProjectList.UNTITLED) },
                colors = FilterChipDefaults.filterChipColors(selectedContainerColor = Panel),
            )
        }
    }
}

/** Today's time, here and on a linked Mac, against the target if there is one. */
@Composable
private fun Today(log: SandLog, counting: Double, targetMinutes: Int) {
    val day = log.on(LocalDate.now())
    val today = day.copy(seconds = day.seconds + counting)
    Spacer(Modifier.height(16.dp))
    if (targetMinutes > 0) {
        val fraction = (today.seconds / (targetMinutes * 60.0)).toFloat()
        LinearProgressIndicator(
            progress = { fraction.coerceIn(0f, 1f) },
            modifier = Modifier.width(220.dp).height(6.dp).clip(CircleShape),
            color = if (fraction >= 1f) Color(0xFF7BD389) else MaterialTheme.colorScheme.primary,
            trackColor = Panel,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            "${SandLog.durationLabel(today.seconds)} of ${SandLog.durationLabel(targetMinutes * 60.0)} today",
            color = Color.White.copy(alpha = 0.6f), fontSize = 13.sp, textAlign = TextAlign.Center,
        )
    } else {
        Text(
            "${SandLog.durationLabel(today.seconds)} today · ${SandLog.timersLabel(today.finished)} finished",
            color = Color.White.copy(alpha = 0.6f), fontSize = 13.sp,
        )
    }
}
