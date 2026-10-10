package io.github.and.sandtimer.data

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.put
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.time.temporal.ChronoUnit
import java.time.temporal.TemporalAdjusters
import java.time.temporal.WeekFields
import java.util.Locale
import kotlin.math.max

/** Time run and timers finished. */
data class Tally(val seconds: Double = 0.0, val finished: Int = 0) {
    operator fun plus(other: Tally) = Tally(seconds + other.seconds, finished + other.finished)
}

/** One hour of a day. */
data class Slot(val seconds: Double = 0.0, val finished: Int = 0, val projects: Map<String, Tally> = emptyMap()) {
    val byProject: Map<String, Tally> get() = withRemainder(projects, seconds, finished)
}

/** One day: its time, finishes, the same by project id ("" for none), and hour by hour (0 to 23, local time). */
data class Day(
    val seconds: Double = 0.0,
    val finished: Int = 0,
    val projects: Map<String, Tally> = emptyMap(),
    val hours: Map<Int, Slot> = emptyMap(),
) {
    val byProject: Map<String, Tally> get() = withRemainder(projects, seconds, finished)
}

/** [projects] with any time the totals hold beyond them put under "", the untagged, as the Mac counts it. */
private fun withRemainder(projects: Map<String, Tally>, seconds: Double, finished: Int): Map<String, Tally> {
    val counted = projects.values.fold(Tally()) { a, b -> a + b }
    val rest = Tally(max(0.0, seconds - counted.seconds), max(0, finished - counted.finished))
    if (rest.seconds <= 0.5 && rest.finished == 0) return projects
    return projects + ("" to ((projects[""] ?: Tally()) + rest))
}

private fun Map<String, Tally>.plusTallies(other: Map<String, Tally>): Map<String, Tally> {
    val sum = toMutableMap()
    for ((id, tally) in other) sum[id] = (sum[id] ?: Tally()) + tally
    return sum
}

/**
 * What the timer has done, one entry per day keyed yyyy-MM-dd in local time: the same record the Mac keeps
 * (Sources/Stats.swift), written in the same form, so a linked Mac counts the phone's time beside its own.
 */
data class SandLog(val days: Map<String, Day> = emptyMap()) {

    /** Counts [seconds] and [finished] on the day and hour [at] falls in, against [project] ("" for none). */
    fun add(seconds: Double = 0.0, finished: Int = 0, project: String = "", at: LocalDateTime): SandLog {
        if (seconds <= 0 && finished <= 0) return this
        val run = max(0.0, seconds)
        val key = dayKey(at.toLocalDate())
        val day = days[key] ?: Day()
        val tally = Tally(run, finished)
        val hour = at.hour
        val slot = day.hours[hour] ?: Slot()
        val newSlot = Slot(slot.seconds + run, slot.finished + finished, slot.projects.plusTallies(mapOf(project to tally)))
        val newDay = Day(
            day.seconds + run, day.finished + finished,
            day.projects.plusTallies(mapOf(project to tally)), day.hours + (hour to newSlot),
        )
        return SandLog(days + (key to newDay))
    }

    /** Counts the sand running from [from] to [until], split at each hour it crosses, so the hourly view is right. */
    fun addRun(from: Instant, until: Instant, project: String, zone: ZoneId): SandLog {
        var log = this
        var start = from
        while (start < until) {
            val local = LocalDateTime.ofInstant(start, zone)
            val nextHour = local.truncatedTo(ChronoUnit.HOURS).plusHours(1).atZone(zone).toInstant()
            val end = if (nextHour < until) nextHour else until
            log = log.add(seconds = (end.toEpochMilli() - start.toEpochMilli()) / 1000.0, project = project, at = local)
            start = end
        }
        return log
    }

    /** This record with [other]'s added in, day by day, hour by hour and project by project. */
    fun including(other: SandLog): SandLog {
        val sum = days.toMutableMap()
        for ((key, theirs) in other.days) {
            val mine = sum[key] ?: Day()
            val hours = mine.hours.toMutableMap()
            for ((hour, slot) in theirs.hours) {
                val m = hours[hour] ?: Slot()
                hours[hour] = Slot(m.seconds + slot.seconds, m.finished + slot.finished, m.projects.plusTallies(slot.projects))
            }
            sum[key] = Day(mine.seconds + theirs.seconds, mine.finished + theirs.finished, mine.projects.plusTallies(theirs.projects), hours)
        }
        return SandLog(sum)
    }

    /** The record as if only [project] had ever been run. */
    fun only(project: String): SandLog = SandLog(days.mapNotNull { (key, day) ->
        val tally = day.byProject[project] ?: return@mapNotNull null
        val hours = day.hours.mapNotNull { (hour, slot) ->
            slot.byProject[project]?.let { hour to Slot(it.seconds, it.finished, mapOf(project to it)) }
        }.toMap()
        key to Day(tally.seconds, tally.finished, mapOf(project to tally), hours)
    }.toMap())

    fun on(date: LocalDate): Day = days[dayKey(date)] ?: Day()

    val allTime: Tally get() = days.values.fold(Tally()) { a, d -> a + Tally(d.seconds, d.finished) }

    val projectIds: Set<String> get() = days.values.flatMap { it.byProject.keys }.toSet()

    fun firstDay(): LocalDate? =
        days.filter { it.value.seconds > 0 || it.value.finished > 0 }.keys.minOrNull()?.let(LocalDate::parse)

    /** Forgets days older than five calendar years, and the hours of days more than a year ago, as the Mac does. */
    fun pruned(today: LocalDate): SandLog {
        val cutoff = dayKey(today.withDayOfYear(1).minusYears(4))
        val detailCutoff = dayKey(today.minusYears(1))
        return SandLog(days.filterKeys { it >= cutoff }.mapValues { (key, day) ->
            if (key < detailCutoff && day.hours.isNotEmpty()) day.copy(hours = emptyMap()) else day
        })
    }

    // Stored form: {day key: {seconds, finished, projects: {id: {seconds, finished}}, hours: {"9": {…}}}}

    fun toJson(): JsonObject = JsonObject(days.mapValues { (_, day) -> dayJson(day) })

    /** The record cut into months, keyed yyyy-MM: how it is sent to a linked Mac, a document a month. */
    fun byMonth(): Map<String, JsonObject> =
        days.entries.groupBy { it.key.take(7) }.mapValues { (_, entries) -> JsonObject(entries.associate { it.key to dayJson(it.value) }) }

    enum class Period(val title: String, val span: Int, val current: String) {
        HOURLY("Hourly", 24, "This hour"),
        DAILY("Daily", 14, "Today"),
        WEEKLY("Weekly", 12, "This week"),
        MONTHLY("Monthly", 12, "This month"),
        YEARLY("Yearly", 5, "This year"),
    }

    /** One bar of the chart: a span, with what the timer did in it. */
    data class Bucket(val label: String, val title: String, val start: LocalDateTime, val total: Tally, val projects: Map<String, Tally>)

    /** The last `period.span` spans, oldest first, the one happening now last. */
    fun buckets(period: Period, now: LocalDateTime, locale: Locale = Locale.getDefault()): List<Bucket> {
        val firstDayOfWeek = WeekFields.of(locale).firstDayOfWeek
        fun startOf(t: LocalDateTime): LocalDateTime = when (period) {
            Period.HOURLY -> t.truncatedTo(ChronoUnit.HOURS)
            Period.DAILY -> t.toLocalDate().atStartOfDay()
            Period.WEEKLY -> t.toLocalDate().with(TemporalAdjusters.previousOrSame(firstDayOfWeek)).atStartOfDay()
            Period.MONTHLY -> t.toLocalDate().withDayOfMonth(1).atStartOfDay()
            Period.YEARLY -> t.toLocalDate().withDayOfYear(1).atStartOfDay()
        }
        fun step(t: LocalDateTime, n: Long): LocalDateTime = when (period) {
            Period.HOURLY -> t.plusHours(n)
            Period.DAILY -> t.plusDays(n)
            Period.WEEKLY -> t.plusWeeks(n)
            Period.MONTHLY -> t.plusMonths(n)
            Period.YEARLY -> t.plusYears(n)
        }
        val current = startOf(now)
        val starts = (period.span - 1 downTo 0).map { step(current, -it.toLong()) }
        val first = starts.first()
        val totals = MutableList(starts.size) { Tally() }
        val parts = MutableList(starts.size) { emptyMap<String, Tally>() }
        fun add(at: LocalDateTime, tally: Tally, projects: Map<String, Tally>) {
            if (at < first) return
            val index = starts.indexOfLast { it <= at }
            if (index < 0) return
            totals[index] = totals[index] + tally
            parts[index] = parts[index].plusTallies(projects)
        }
        for ((key, day) in days) {
            val date = runCatching { LocalDate.parse(key) }.getOrNull() ?: continue
            if (period == Period.HOURLY) {
                for ((hour, slot) in day.hours) add(date.atTime(hour, 0), Tally(slot.seconds, slot.finished), slot.byProject)
            } else {
                add(date.atStartOfDay(), Tally(day.seconds, day.finished), day.byProject)
            }
        }
        return starts.mapIndexed { index, start ->
            val last = index == starts.lastIndex
            val label = when (period) {
                Period.HOURLY -> start.format(DateTimeFormatter.ofPattern("H"))
                Period.DAILY -> start.dayOfMonth.toString()
                Period.WEEKLY -> start.format(DateTimeFormatter.ofPattern("d MMM", locale))
                Period.MONTHLY -> start.month.getDisplayName(TextStyle.SHORT, locale)
                Period.YEARLY -> start.year.toString()
            }
            val title = when {
                last -> period.current
                period == Period.DAILY && index == starts.lastIndex - 1 -> "Yesterday"
                period == Period.HOURLY && index == starts.lastIndex - 1 -> "Last hour"
                period == Period.HOURLY -> start.format(DateTimeFormatter.ofPattern("EEEE H:00", locale))
                period == Period.DAILY -> start.format(DateTimeFormatter.ofPattern("EEEE d MMM", locale))
                period == Period.WEEKLY -> "Week of " + start.format(DateTimeFormatter.ofPattern("d MMM", locale))
                period == Period.MONTHLY -> start.format(DateTimeFormatter.ofPattern("MMMM yyyy", locale))
                else -> start.year.toString()
            }
            Bucket(label, title, start, totals[index], parts[index])
        }
    }

    companion object {
        fun dayKey(date: LocalDate): String = date.toString()  // ISO: yyyy-MM-dd

        fun fromJson(json: JsonObject?): SandLog = SandLog((json ?: JsonObject(emptyMap())).mapNotNull { (key, value) ->
            val entry = value as? JsonObject ?: return@mapNotNull null
            val hours = (entry["hours"] as? JsonObject).orEmpty().mapNotNull { (hour, slot) ->
                val h = hour.toIntOrNull()?.takeIf { it in 0..23 } ?: return@mapNotNull null
                val s = slot as? JsonObject ?: return@mapNotNull null
                h to Slot(s.num("seconds"), s.num("finished").toInt(), tallies(s["projects"]))
            }.toMap()
            key to Day(entry.num("seconds"), entry.num("finished").toInt(), tallies(entry["projects"]), hours)
        }.toMap())

        private fun JsonObject.num(key: String): Double = (this[key] as? JsonPrimitive)?.doubleOrNull ?: 0.0

        private fun tallies(json: Any?): Map<String, Tally> = (json as? JsonObject).orEmpty().mapNotNull { (id, value) ->
            val t = value as? JsonObject ?: return@mapNotNull null
            id to Tally(t.num("seconds"), t.num("finished").toInt())
        }.toMap()

        private fun talliesJson(tallies: Map<String, Tally>) = JsonObject(tallies.mapValues { (_, t) ->
            buildJsonObject { put("seconds", t.seconds); put("finished", t.finished) }
        })

        private fun dayJson(day: Day) = buildJsonObject {
            put("seconds", day.seconds)
            put("finished", day.finished)
            if (day.projects.isNotEmpty()) put("projects", talliesJson(day.projects))
            if (day.hours.isNotEmpty()) put("hours", JsonObject(day.hours.entries.associate { (hour, slot) ->
                hour.toString() to buildJsonObject {
                    put("seconds", slot.seconds)
                    put("finished", slot.finished)
                    if (slot.projects.isNotEmpty()) put("projects", talliesJson(slot.projects))
                }
            }))
        }

        /** "3h 20m", "45m", "12s". */
        fun durationLabel(seconds: Double): String {
            val total = Math.round(seconds).toInt()
            if (total < 60) return "${total}s"
            val minutes = total / 60
            if (minutes < 60) return "${minutes}m"
            return if (minutes % 60 == 0) "${minutes / 60}h" else "${minutes / 60}h ${minutes % 60}m"
        }

        fun timersLabel(count: Int) = "$count timer" + if (count == 1) "" else "s"
    }
}

private fun JsonObject?.orEmpty(): Map<String, kotlinx.serialization.json.JsonElement> = this ?: emptyMap()
