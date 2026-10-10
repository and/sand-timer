package io.github.and.sandtimer.ui

import android.Manifest
import android.text.format.DateUtils
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.RemoveCircleOutline
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import io.github.and.sandtimer.BuildConfig
import io.github.and.sandtimer.data.Project
import io.github.and.sandtimer.data.ProjectList
import io.github.and.sandtimer.data.SandLog
import io.github.and.sandtimer.data.Store
import io.github.and.sandtimer.link.Link
import io.github.and.sandtimer.timer.Engine
import io.github.and.sandtimer.timer.Focus

@Composable
fun SettingsScreen(modifier: Modifier = Modifier) {
    val app by Store.state.collectAsState()
    Column(modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)) {
        LinkSection()
        Divider()
        Heading("Projects", "Time counts toward the project that's on.")
        ProjectsEditor(app.projects)
        Divider()
        Heading("Daily target", "A bar under the timer fills as the day's time runs.")
        val target = app.settings.targetMinutes
        SwitchRow("Aim for a daily target", target > 0) { on -> Store.updateSettings { it.copy(targetMinutes = if (on) 60 else 0) } }
        if (target > 0) {
            Text(SandLog.durationLabel(target * 60.0) + " a day", color = Color.White.copy(alpha = 0.75f))
            Slider(
                value = target.toFloat(), valueRange = 15f..720f, steps = 46,
                onValueChange = { v -> Store.updateSettings { it.copy(targetMinutes = (v / 15).toInt() * 15) } },
            )
        }
        Divider()
        Heading("Timer", null)
        SwitchRow("Chime when the time is up", app.settings.chime) { on -> Store.updateSettings { it.copy(chime = on) } }
        SwitchRow("One Thing at a Time", app.settings.oneThingAtATime) { on -> Store.updateSettings { it.copy(oneThingAtATime = on) } }
        Note("Keeps the project for the whole session. End the session to switch.")
        Spacer(Modifier.height(8.dp))
        SwitchRow("Keep the screen on", app.settings.keepScreenOn) { on -> Store.updateSettings { it.copy(keepScreenOn = on) } }
        Note("While the sand runs and the timer is showing.")
        Spacer(Modifier.height(8.dp))
        SwitchRow("Clean view", app.settings.calm) { on -> Store.updateSettings { it.copy(calm = on) } }
        Note("While the sand runs, everything but the glass fades away after a few still seconds. Move or touch the phone to bring it back.")
        Spacer(Modifier.height(8.dp))
        FocusRow(app.settings.focus)
        Divider()
        Note("Sand Timer ${BuildConfig.VERSION_NAME}. Your time stays on this phone unless you link it to your Mac.")
    }
}

/** Linking to a Mac, like linking a phone to a messaging account: scan the Mac's code, and share from then on. */
@Composable
private fun LinkSection() {
    val context = LocalContext.current
    val app by Store.state.collectAsState()
    var problem by remember { mutableStateOf<String?>(null) }
    val link = app.link

    fun scan() {
        problem = null
        val options = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
        GmsBarcodeScanning.getClient(context, options).startScan()
            .addOnSuccessListener { code ->
                try {
                    Link.link(code.rawValue.orEmpty())
                } catch (e: Exception) {
                    problem = e.message ?: "Couldn't link"
                }
            }
            .addOnFailureListener { problem = it.message ?: "The scanner didn't open" }
    }
    // Bluetooth is asked for only when linking is turned on.
    val turnOn = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted ->
        if (granted.values.all { it }) Link.setEnabled(true) else problem = "Linking needs Bluetooth permission to find your Mac."
    }
    val bluetooth = arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)

    Heading("Link to a Mac", null)
    Note(
        "Optional: share one timer, your projects and statistics with Sand Timer on your Mac. The two talk over " +
            "Bluetooth, encrypted, whenever they're near each other.",
    )
    SwitchRow("Link to a Mac", link.enabled) { on ->
        problem = null
        when {
            !on -> Link.setEnabled(false)
            Link.radio.allowed -> Link.setEnabled(true)
            else -> turnOn.launch(bluetooth)
        }
    }
    if (link.enabled && !link.linked) {
        Note("On the Mac, open Sand Timer's Settings, turn on Link with a phone, click Link a Phone…, then scan the code it shows.")
        Spacer(Modifier.height(8.dp))
        Button(onClick = ::scan) { Text("Scan the Mac's Code") }
    } else if (link.enabled) {
        if (link.devices.isEmpty()) Note("Linked. Looking for your Mac nearby…")
        for (device in link.devices) {
            Text(device.name, color = Color.White, fontWeight = FontWeight.Medium)
            Note(
                if (device.id in link.connected) "Connected"
                else "Last seen " + DateUtils.getRelativeTimeSpanString((device.seen * 1000).toLong()).toString().lowercase(),
            )
        }
        Spacer(Modifier.height(8.dp))
        Spacer(Modifier.height(8.dp))
        OpenOnMacStartRow(app.settings.openOnMacStart)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (!Link.radio.allowed) OutlinedButton(onClick = { turnOn.launch(bluetooth) }) { Text("Allow Bluetooth") }
            TextButton(onClick = { Link.unlink() }) { Text("Unlink This Phone") }
        }
    }
    (problem ?: link.problem)?.let { Text(it, color = Color(0xFFFF8A80), fontSize = 13.sp) }
}

/** Coming to the front when the Mac starts the timer: Android asks for "Display over other apps" first. */
@Composable
private fun OpenOnMacStartRow(on: Boolean) {
    val context = LocalContext.current
    var allowed by remember { mutableStateOf(android.provider.Settings.canDrawOverlays(context)) }
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current
    androidx.compose.runtime.DisposableEffect(lifecycle) {
        val watcher = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_RESUME) allowed = android.provider.Settings.canDrawOverlays(context)
        }
        lifecycle.lifecycle.addObserver(watcher)
        onDispose { lifecycle.lifecycle.removeObserver(watcher) }
    }
    SwitchRow("Open when the Mac starts the timer", on && allowed) { turnOn ->
        Store.updateSettings { it.copy(openOnMacStart = turnOn) }
        if (turnOn && !android.provider.Settings.canDrawOverlays(context)) {
            context.startActivity(
                android.content.Intent(android.provider.Settings.ACTION_MANAGE_OVERLAY_PERMISSION, android.net.Uri.parse("package:${context.packageName}")),
            )
        }
    }
    Note(
        if (on && !allowed) "Allow Sand Timer under Display over other apps, then come back."
        else "Sand Timer comes to the front as the Mac flips the glass, waking the phone and showing over the lock screen if the screen is off.",
    )
}

/** Do Not Disturb while the sand runs. Turning it on asks Android for permission to manage it, once. */
@Composable
private fun FocusRow(on: Boolean) {
    val context = LocalContext.current
    // Coming back from Android's permission page: the switch shows what was decided there.
    var allowed by remember { mutableStateOf(Focus.allowed(context)) }
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current
    androidx.compose.runtime.DisposableEffect(lifecycle) {
        val watcher = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_RESUME) {
                allowed = Focus.allowed(context)
                Engine.sync(context)
            }
        }
        lifecycle.lifecycle.addObserver(watcher)
        onDispose { lifecycle.lifecycle.removeObserver(watcher) }
    }
    SwitchRow("Do Not Disturb while the sand runs", on && allowed) { turnOn ->
        Store.updateSettings { it.copy(focus = turnOn) }
        if (turnOn && !Focus.allowed(context)) Focus.ask(context)
        Engine.sync(context)
    }
    Note(
        if (on && !allowed) "Allow Sand Timer under Do Not Disturb access, then come back."
        else "Turns on a Do Not Disturb mode called Sand Timer while the sand runs, and off when it stops. " +
            "Change what it lets through in the phone's Modes settings.",
    )
}

@Composable
private fun ProjectsEditor(projects: ProjectList) {
    for (project in projects.visible) ProjectRow(project, projects)
    Spacer(Modifier.height(6.dp))
    OutlinedButton(onClick = {
        val used = projects.visible.map { it.color }.toSet()
        val color = ProjectList.palette.firstOrNull { it !in used } ?: ProjectList.palette[projects.all.size % ProjectList.palette.size]
        Store.updateProjects(projects.copy(all = projects.all + Project(name = "Project ${projects.visible.size + 1}", color = color)))
    }) { Text("Add Project") }
}

@Composable
private fun ProjectRow(project: Project, projects: ProjectList) {
    var name by remember(project.id) { mutableStateOf(project.name) }
    var choosing by remember { mutableStateOf(false) }
    fun change(edit: (Project) -> Project) =
        Store.updateProjects(projects.copy(all = projects.all.map { if (it.id == project.id) edit(it) else it }))

    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(28.dp).clip(CircleShape).background(sandColor(project.color)).clickable { choosing = !choosing })
        Spacer(Modifier.width(10.dp))
        OutlinedTextField(
            value = name, singleLine = true, modifier = Modifier.weight(1f),
            onValueChange = { text ->
                name = text
                if (text.isNotBlank()) change { it.copy(name = text.trim()) }
            },
        )
        IconButton(onClick = { change { it.copy(archived = true) } }) {
            Icon(Icons.Filled.RemoveCircleOutline, contentDescription = "Remove ${project.name}", tint = Color.White.copy(alpha = 0.6f))
        }
    }
    if (choosing) {
        Row(Modifier.padding(start = 38.dp, top = 6.dp, bottom = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for (hex in ProjectList.palette) {
                Box(
                    Modifier.size(24.dp).clip(CircleShape).background(sandColor(hex))
                        .border(2.dp, if (hex.equals(project.color, true)) Color.White else Color.Transparent, CircleShape)
                        .clickable { change { it.copy(color = hex) }; choosing = false },
                )
            }
        }
    }
    Spacer(Modifier.height(6.dp))
}

@Composable
private fun Heading(title: String, hint: String?) {
    Text(title, color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
    if (hint != null) Note(hint)
    Spacer(Modifier.height(8.dp))
}

@Composable
private fun Note(text: String) = Text(text, color = Color.White.copy(alpha = 0.55f), fontSize = 13.sp)

@Composable
private fun SwitchRow(title: String, on: Boolean, toggle: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, color = Color.White, modifier = Modifier.weight(1f))
        Switch(checked = on, onCheckedChange = toggle)
    }
}

@Composable
private fun Divider() {
    Spacer(Modifier.height(16.dp))
    HorizontalDivider(color = Color.White.copy(alpha = 0.08f))
    Spacer(Modifier.height(16.dp))
}
