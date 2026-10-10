package io.github.and.sandtimer

import io.github.and.sandtimer.data.Project
import io.github.and.sandtimer.data.ProjectList
import io.github.and.sandtimer.data.SandLog
import io.github.and.sandtimer.data.Timer
import io.github.and.sandtimer.data.TimerState
import io.github.and.sandtimer.link.Crypto
import io.github.and.sandtimer.link.LinkCode
import io.github.and.sandtimer.link.Reassembler
import org.junit.Assert.assertArrayEquals
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.util.Base64

class DataTest {
    private val zone: ZoneId = ZoneOffset.UTC
    private fun at(h: Int, m: Int = 0) = LocalDateTime.of(2026, 10, 7, h, m).toInstant(ZoneOffset.UTC).toEpochMilli()

    @Test fun `a run is counted hour by hour, against its project`() {
        val log = SandLog().addRun(java.time.Instant.ofEpochMilli(at(9, 50)), java.time.Instant.ofEpochMilli(at(10, 20)), "a", zone)
        val day = log.days.getValue("2026-10-07")
        assertEquals(1800.0, day.seconds, 0.001)
        assertEquals(600.0, day.hours.getValue(9).seconds, 0.001)
        assertEquals(1200.0, day.hours.getValue(10).projects.getValue("a").seconds, 0.001)
    }

    @Test fun `a timer that runs out while nobody looks is counted and finished`() {
        val t = Timer(TimerState(), SandLog()).started(at(9), 25, "a", zone)
        val later = t.settled(at(11), zone)
        assertTrue(!later.state.inSession(at(11)))
        val day = later.log.days.getValue("2026-10-07")
        assertEquals(1500.0, day.seconds, 0.001)
        assertEquals(1, day.finished)
    }

    @Test fun `a pause stops the count and keeps what's left`() {
        val t = Timer(TimerState(), SandLog()).started(at(9), 25, null, zone).paused(at(9, 10), zone)
        assertEquals(15 * 60_000L, t.state.remaining(at(12)))
        assertEquals(600.0, t.log.allTime.seconds, 0.001)
        val resumed = t.resumed(at(12), zone).ended(at(12, 5), zone)
        assertEquals(900.0, resumed.log.allTime.seconds, 0.001)
        assertEquals(0, resumed.log.allTime.finished)
    }

    @Test fun `the stored form is the Mac's`() {
        // As the Mac's SandLog.stored writes it (Sources/Stats.swift).
        val mac = """{"2026-10-07":{"seconds":600,"finished":1,"projects":{"A":{"seconds":600,"finished":1}},
            "hours":{"9":{"seconds":600,"finished":1,"projects":{"A":{"seconds":600,"finished":1}}}}}}"""
        val log = SandLog.fromJson(Json.parseToJsonElement(mac).jsonObject)
        val day = log.days.getValue("2026-10-07")
        assertEquals(600.0, day.hours.getValue(9).projects.getValue("A").seconds, 0.001)
        assertEquals(log, SandLog.fromJson(log.toJson()))
        assertEquals(setOf("2026-10"), log.byMonth().keys)
    }

    @Test fun `projects merge the way the Mac merges them`() {
        val mine = ProjectList(listOf(Project("a", "Phone name", "#111111", updated = 2000.0), Project("b", "Old", "#222222", updated = 1000.0)))
        val theirs = ProjectList(listOf(Project("b", "Mac name", "#222222", archived = true, updated = 2000.0), Project("c", "New", "#333333")))
        val merged = mine.merged(theirs)
        assertEquals(listOf("a", "b", "c"), merged.all.map { it.id })
        assertEquals(listOf("Phone name", "Mac name", "New"), merged.all.map { it.name })
        assertEquals(merged, merged.merged(theirs))
        val stamped = merged.copy(all = merged.all.map { if (it.id == "a") it.copy(name = "Renamed") else it }).stamped(merged, 3000.0)
        assertEquals(listOf(3000.0, 2000.0, Project.DISTANT_PAST), stamped.all.map { it.updated })
    }

    @Test fun `a project from the Mac reads back`() {
        val json = """{"id":"X","name":"Writing","color":"#E8833A","shakes":true,"archived":false,"updated":1791369600.5}"""
        val p = Project.fromJson(Json.parseToJsonElement(json).jsonObject)!!
        assertEquals(1791369600.5, p.updated, 0.0)
        assertEquals(p, Project.fromJson(p.toJson()))
    }

    @Test fun `what is sealed opens with the key, in the Mac's layout`() {
        val key = ByteArray(32) { it.toByte() }
        val sealed = Crypto.seal("{\"a\":1}".toByteArray(), key)
        assertEquals("{\"a\":1}", String(Crypto.open(sealed, key)))
        assertEquals(12 + 7 + 16, sealed.size)
    }

    @Test fun `the Mac's code gives the key, and names the Mac's service`() {
        val key = ByteArray(32) { it.toByte() }
        // Both made by the Mac's own LinkFormat for this key.
        assertArrayEquals(key, LinkCode.parse("sandtimer-link:2:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"))
        assertEquals("7ffbb136-ef18-4037-9eb1-66e3a521c091", Crypto.serviceUuid(key).toString())
        assertNull(LinkCode.parse("anchor-pair:2:x"))
        assertNull(LinkCode.parse(LinkCode.PREFIX + "short"))
        assertNull(LinkCode.parse("sandtimer-link:1:token:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"))
    }

    @Test fun `a message goes in Bluetooth-sized pieces and comes back whole`() {
        val message = ByteArray(1000) { it.toByte() }
        val frames = Crypto.frames(message, 182)
        assertTrue(frames.all { it.size <= 182 })
        val whole = Reassembler()
        val results = frames.map { whole.add(it) }
        assertTrue(results.dropLast(1).all { it == null })
        assertArrayEquals(message, results.last())
        assertEquals(1, Crypto.frames(ByteArray(0), 20).size)
    }

    @Test fun `a digest ignores the order keys were written in`() {
        val a = Json.parseToJsonElement("""{"b":1,"a":{"y":2,"x":3}}""")
        val b = Json.parseToJsonElement("""{"a":{"x":3,"y":2},"b":1}""")
        assertEquals(Crypto.digest(a), Crypto.digest(b))
        assertNotEquals(Crypto.digest(a), Crypto.digest(Json.parseToJsonElement("""{"b":2,"a":{"y":2,"x":3}}""")))
    }

    @Test fun `buckets put the day's time in today's bar`() {
        val log = SandLog().add(seconds = 60.0, project = "a", at = LocalDateTime.of(2026, 10, 7, 9, 0))
            .add(seconds = 30.0, at = LocalDateTime.of(2026, 10, 6, 9, 0))
        val days = log.buckets(SandLog.Period.DAILY, LocalDateTime.of(2026, 10, 7, 12, 0))
        assertEquals(14, days.size)
        assertEquals(60.0, days.last().total.seconds, 0.001)
        assertEquals("Yesterday", days[12].title)
        assertEquals(30.0, days[12].projects.getValue("").seconds, 0.001)
    }
}
