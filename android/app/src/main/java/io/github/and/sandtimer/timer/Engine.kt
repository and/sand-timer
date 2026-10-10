package io.github.and.sandtimer.timer

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.github.and.sandtimer.data.Store
import io.github.and.sandtimer.data.Timer
import io.github.and.sandtimer.data.TimerState
import io.github.and.sandtimer.link.Link
import io.github.and.sandtimer.link.SharedTimer

/**
 * Works the timer: every change goes through [Store], and afterwards the alarm for the moment the sand runs out
 * and the notification are set to match. Nothing ticks in the background — the state is moments in time, and the
 * alarm wakes the app for the end.
 */
object Engine {
    private fun now() = System.currentTimeMillis()

    /** Brings the record up to now: a run that ended while the app was away is put right, the time so far counted. */
    fun refresh(context: Context) {
        settle(context)
        Store.updateTimer { it.counted(now(), Store.zone) }
    }

    /** A tap on the glass: flip it when it's waiting, pause it while it runs, carry on when it's paused. */
    fun tap(context: Context) {
        val state = Store.state.value.timer.state
        when {
            state.isRunning(now()) -> pause(context)
            state.isPaused(now()) -> resume(context)
            else -> start(context)
        }
    }

    fun start(context: Context, minutes: Int? = null) {
        val s = Store.state.value
        change(context) { it.started(now(), minutes ?: s.timer.state.minutes, s.activeProject, Store.zone) }
    }

    fun pause(context: Context) = change(context) { it.paused(now(), Store.zone) }

    fun resume(context: Context) = change(context) { it.resumed(now(), Store.zone) }

    fun end(context: Context) = change(context) { it.ended(now(), Store.zone) }

    /** How long the next flip gives you. While a session is under way it waits for the next one. */
    fun setMinutes(context: Context, minutes: Int) {
        Store.updateTimer { it.copy(state = it.state.copy(minutes = minutes.coerceIn(1, 60))) }
        sync(context)
        Link.timerChanged()
    }

    /**
     * Puts right a run whose sand has run out — the alarm going off, or the screen noticing first — and chimes if it
     * ran out just now. One that ran out long ago, found on opening the app, is only counted.
     */
    fun settle(context: Context) {
        val before = Store.state.value.timer.state
        Store.updateTimer { it.settled(now(), Store.zone) }
        sync(context)
        val until = before.runningUntil ?: return
        if (until > now()) return
        if (now() - until < 60_000) Notifications.finished(context, before)
        Link.timerChanged()  // nothing new for the Mac, whose sand ran out too, but the record goes across
    }

    private fun change(context: Context, edit: (Timer) -> Timer) {
        Store.updateTimer(edit)
        sync(context)
        Link.timerChanged()
    }

    /**
     * Takes on the timer as the linked Mac left it: flipped, paused, resumed, ended, or set to another length or
     * project there. The time run here so far is counted first, if it was this phone's to count.
     */
    fun adopt(context: Context, timer: SharedTimer, counts: Boolean) {
        val nowMs = now()
        val now = nowMs / 1000.0
        val projects = Store.state.value.projects
        if (timer.project == null || projects.project(timer.project) != null) Store.setActiveProject(timer.project)
        val started = timer.started?.let { (it * 1000).toLong() }
        val before = Store.state.value.timer.state
        // A session the Mac has just begun, not one going on that it paused, resumed or set the sand of.
        val fresh = timer.phase(now) == SharedTimer.Phase.RUNNING &&
            (!before.inSession(nowMs) || before.started == null || started == null || kotlin.math.abs(before.started - started) > 1000)
        Store.updateTimer { t ->
            val before = t.settled(nowMs, Store.zone).counted(nowMs, Store.zone)
            val state = when (timer.phase(now)) {
                SharedTimer.Phase.RUNNING -> TimerState(
                    minutes = timer.minutes, runningUntil = (timer.runningUntil!! * 1000).toLong(), countedFrom = nowMs,
                    project = timer.project, started = started, counts = counts,
                )
                SharedTimer.Phase.PAUSED -> TimerState(
                    minutes = timer.minutes, pausedWith = (timer.pausedWith!! * 1000).toLong(),
                    project = timer.project, started = started, counts = counts,
                )
                SharedTimer.Phase.IDLE -> TimerState(minutes = timer.minutes, project = timer.project)
            }
            Timer(state, before.log)
        }
        sync(context)
        if (fresh) bringForward(context)
    }

    /**
     * The Mac flipped the glass: come to the front to show it, if asked to, waking the phone if its screen is off and
     * showing over the lock screen, the way an alarm does. Android lets an app open itself from the background only
     * with "Display over other apps" allowed, which turning this on asks for.
     */
    private fun bringForward(context: Context) {
        if (!Store.state.value.settings.openOnMacStart || !android.provider.Settings.canDrawOverlays(context)) return
        runCatching {
            android.util.Log.i("SandTimer", "The Mac started the timer: coming to the front")
            context.startActivity(
                Intent(context, io.github.and.sandtimer.ui.MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                    .putExtra(io.github.and.sandtimer.ui.MainActivity.SHOW_TIMER, true),
            )
        }
    }

    /** Sets the alarm and the notification to match the timer. */
    fun sync(context: Context) {
        val state = Store.state.value.timer.state
        val alarms = context.getSystemService(AlarmManager::class.java)
        val intent = PendingIntent.getBroadcast(
            context, 0, Intent(context, AlarmReceiver::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val until = state.runningUntil
        if (until != null && until > now()) {
            if (alarms.canScheduleExactAlarms()) alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, until, intent)
            else alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, until, intent)
        } else {
            alarms.cancel(intent)
        }
        Notifications.update(context, state, Store.state.value.projects)
        Focus.update(context, state.isRunning(now()))
    }
}

/** The sand ran out. */
class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Store.init(context)
        Engine.settle(context)
    }
}

/** Pause, Resume and End from the notification. */
class ActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Store.init(context)
        when (intent.action) {
            ACTION_PAUSE -> Engine.pause(context)
            ACTION_RESUME -> Engine.resume(context)
            ACTION_END -> Engine.end(context)
        }
    }

    companion object {
        const val ACTION_PAUSE = "io.github.and.sandtimer.PAUSE"
        const val ACTION_RESUME = "io.github.and.sandtimer.RESUME"
        const val ACTION_END = "io.github.and.sandtimer.END"
    }
}

/**
 * Alarms don't survive a restart or an update: set it again, and the notification, for a session that was going.
 * Starting the app here also reconnects to a linked Mac (SandTimerApp).
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Store.init(context)
        Engine.refresh(context)
        // Android allows the link's background service to start only now, while this broadcast is being handled.
        Link.init(context)
        Link.wake()
    }
}
