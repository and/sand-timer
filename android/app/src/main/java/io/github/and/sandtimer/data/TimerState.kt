package io.github.and.sandtimer.data

import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import kotlin.math.max
import kotlin.math.min

/**
 * What the timer is doing, as moments rather than a ticking count, so it is right whenever it is next looked at:
 * after the app was closed, the phone slept, or it restarted. Times are milliseconds since 1970.
 */
@Serializable
data class TimerState(
    /** How long a flip gives you. */
    val minutes: Int = 25,
    /** When the sand will run out, while it runs. */
    val runningUntil: Long? = null,
    /** How much is left, while paused. */
    val pausedWith: Long? = null,
    /** Where the record is counted up to while the sand runs: the time before this is already in the log. */
    val countedFrom: Long? = null,
    /** The project this session's time counts against, if any. */
    val project: String? = null,
    /** When this session began: a pause doesn't change it. A linked Mac knows the session by it. */
    val started: Long? = null,
    /** Whether this phone counts the session's time: not when a linked Mac started it and counts it there. */
    val counts: Boolean = true,
) {
    fun isRunning(now: Long) = (runningUntil ?: 0) > now
    fun isPaused(now: Long) = !isRunning(now) && (pausedWith ?: 0) > 0
    /** Running or paused: under One Thing at a Time the project waits until this is over. */
    fun inSession(now: Long) = isRunning(now) || isPaused(now)

    fun remaining(now: Long): Long = when {
        isRunning(now) -> runningUntil!! - now
        isPaused(now) -> pausedWith!!
        else -> 0
    }

    /** How much of the sand has fallen: 0 just flipped, 1 run out — and 1 while waiting to be flipped. */
    fun fallen(now: Long): Double {
        val total = minutes * 60_000.0
        if (!inSession(now) || total <= 0) return 1.0
        return min(1.0, max(0.0, 1 - remaining(now) / total))
    }
}

/** The timer and its record moving together: every change counts the sand that ran up to that moment. */
data class Timer(val state: TimerState, val log: SandLog) {

    /** Counts the sand that has run since it was last counted, stopping where the top emptied. */
    fun counted(now: Long, zone: ZoneId): Timer {
        val from = state.countedFrom ?: return this
        val until = min(now, state.runningUntil ?: now)
        if (until <= from) return this
        if (!state.counts) return Timer(state.copy(countedFrom = until), log)
        val log = log.addRun(Instant.ofEpochMilli(from), Instant.ofEpochMilli(until), state.project ?: "", zone)
        return Timer(state.copy(countedFrom = until), log)
    }

    /** Puts right a run that ended while nobody was looking: its time counted, and one more timer finished. */
    fun settled(now: Long, zone: ZoneId): Timer {
        val until = state.runningUntil ?: return this
        if (until > now) return this
        val counted = counted(until, zone)
        val at = LocalDateTime.ofInstant(Instant.ofEpochMilli(until), zone)
        return Timer(
            counted.state.copy(runningUntil = null, pausedWith = null, countedFrom = null),
            if (state.counts) counted.log.add(finished = 1, project = state.project ?: "", at = at) else counted.log,
        )
    }

    /** A fresh session of [minutes] for [project], whatever was going before (its time counted). */
    fun started(now: Long, minutes: Int, project: String?, zone: ZoneId): Timer {
        val before = settled(now, zone).counted(now, zone)
        return Timer(
            TimerState(minutes = minutes, runningUntil = now + minutes * 60_000L, countedFrom = now, project = project, started = now),
            before.log,
        )
    }

    fun paused(now: Long, zone: ZoneId): Timer {
        val t = settled(now, zone)
        if (!t.state.isRunning(now)) return t
        val c = t.counted(now, zone)
        return c.copy(state = c.state.copy(runningUntil = null, pausedWith = t.state.runningUntil!! - now, countedFrom = null))
    }

    fun resumed(now: Long, zone: ZoneId): Timer {
        if (!state.isPaused(now)) return this
        return copy(state = state.copy(runningUntil = now + state.pausedWith!!, pausedWith = null, countedFrom = now))
    }

    /** Done early: the time run is kept, but it isn't a finished timer, and the sand settles to the bottom. */
    fun ended(now: Long, zone: ZoneId): Timer {
        val t = settled(now, zone).counted(now, zone)
        return t.copy(state = t.state.copy(runningUntil = null, pausedWith = null, countedFrom = null))
    }
}
