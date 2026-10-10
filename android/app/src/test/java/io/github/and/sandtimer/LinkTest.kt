package io.github.and.sandtimer

import io.github.and.sandtimer.data.Project
import io.github.and.sandtimer.data.ProjectList
import io.github.and.sandtimer.data.SandLog
import io.github.and.sandtimer.data.Timer
import io.github.and.sandtimer.data.TimerState
import io.github.and.sandtimer.link.LinkEngine
import io.github.and.sandtimer.link.LinkHost
import io.github.and.sandtimer.link.LinkStorage
import io.github.and.sandtimer.link.LinkTransport
import io.github.and.sandtimer.link.SharedTimer
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.util.UUID

/** The phone's link engine against a hub built the same way, as the Mac's is: messages carried in memory, in order. */
class LinkTest {
    private class Host : LinkHost {
        override var projects = ProjectList()
        var log = SandLog()
        var timer = SharedTimer(25)
        val adopted = mutableListOf<Pair<SharedTimer, Boolean>>()
        override fun takeLinkedProjects(list: ProjectList) { projects = list }
        override fun ownLog() = log
        override fun localTimer() = timer.copy(owner = "", stamp = SharedTimer.DISTANT_PAST)
        override fun adopt(timer: SharedTimer, counts: Boolean) { this.timer = timer; adopted += timer to counts }
        override fun linkChanged() {}
    }

    private class Wire {
        val queue = ArrayDeque<Triple<String, String, ByteArray>>()
        val engines = mutableMapOf<String, LinkEngine>()
        var delivered = 0
        fun pump() {
            while (queue.isNotEmpty()) {
                val (from, to, message) = queue.removeFirst()
                delivered++
                engines[to]?.received(message, from)
            }
        }
    }

    private class Device(val name: String, hub: Boolean, wire: Wire, now: () -> Double) {
        val storage = object : LinkStorage {
            val map = mutableMapOf<String, String>()
            override fun get(key: String) = map[key]
            override fun put(key: String, value: String?) { if (value == null) map.remove(key) else map[key] = value }
        }
        val host = Host()
        var service: UUID? = null
        val engine = LinkEngine(name, if (hub) "mac" else "android", hub, storage, later = { _, block -> block() }, clock = now)

        init {
            engine.host = host
            engine.transport = object : LinkTransport {
                override fun start(service: UUID) { this@Device.service = service }
                override fun stop() { service = null }
                override fun send(message: ByteArray, peer: String) { wire.queue.addLast(Triple(name, peer, message)) }
            }
            wire.engines[name] = engine
        }

        fun linked(): SandLog = engine.linkedLogs.values.fold(SandLog()) { sum, r -> sum.including(SandLog.fromJson(r as JsonObject)) }
    }

    @Test fun `a Mac and two phones share one timer, the projects and every record`() {
        var now = 1_760_000_000.0
        val wire = Wire()
        val mac = Device("mac", true, wire) { now }
        val phone = Device("phone", false, wire) { now }
        val other = Device("other", false, wire) { now }
        mac.host.projects = ProjectList(listOf(Project("a", "Writing", "#111111", updated = 2000.0)))
        phone.host.projects = ProjectList(listOf(Project("a", "Old", "#111111", updated = 1000.0), Project("b", "Reading", "#222222", updated = 1000.0)))
        val noon = LocalDateTime.of(2026, 10, 7, 12, 0)
        mac.host.log = SandLog().add(seconds = 600.0, project = "a", at = noon)
        phone.host.log = SandLog().add(seconds = 300.0, finished = 1, project = "b", at = noon)

        val code = mac.engine.linkCode()
        phone.engine.link(code)
        other.engine.link(code)
        assertEquals(mac.service, phone.service)
        for (p in listOf(phone, other)) {
            mac.engine.connected(p.name)
            p.engine.connected("mac")
        }
        wire.pump()

        assertEquals(setOf(phone.engine.deviceId, other.engine.deviceId), mac.engine.connected)
        assertEquals(listOf("mac"), phone.engine.devices.map { it.name })
        for (d in listOf(mac, phone, other)) assertEquals(listOf("Writing", "Reading"), d.host.projects.all.map { it.name })
        assertEquals(300.0, mac.linked().days["2026-10-07"]!!.seconds, 1e-9)
        assertEquals(600.0, phone.linked().days["2026-10-07"]!!.seconds, 1e-9)
        assertEquals(900.0, other.linked().days["2026-10-07"]!!.seconds, 1e-9)

        // Started on the Mac: both phones show it, and neither counts it.
        now += 10
        mac.host.timer = SharedTimer(25, started = now, runningUntil = now + 1500, project = "a")
        mac.engine.timerChanged()
        wire.pump()
        val seen = phone.host.adopted.last()
        assertEquals(SharedTimer.Phase.RUNNING, seen.first.phase(now))
        assertFalse(seen.second)
        assertFalse(phone.engine.countsHere)
        assertTrue(mac.engine.countsHere)
        assertEquals(now + 1500, other.host.adopted.last().first.runningUntil!!, 1e-6)

        // An echo isn't sent back.
        val sent = wire.delivered
        phone.engine.timerChanged()
        wire.pump()
        assertEquals(sent, wire.delivered)

        // Paused on the phone: the Mac takes it, and still counts the session.
        now += 60
        phone.host.timer = phone.host.timer.copy(runningUntil = null, pausedWith = 1440.0)
        phone.engine.timerChanged()
        wire.pump()
        val pause = mac.host.adopted.last()
        assertEquals(SharedTimer.Phase.PAUSED, pause.first.phase(now))
        assertTrue(pause.second)
        assertEquals(mac.engine.deviceId, pause.first.owner)

        // Unlinked on the Mac: the phones forget the link and the others' time.
        mac.engine.unlink()
        wire.pump()
        assertFalse(phone.engine.isLinked)
        assertTrue(phone.engine.linkedLogs.isEmpty())
    }

    @Test fun `lists that say the same agree, whatever the order, a stamp's last digit or a doubled id`() {
        val a = Project("a", "A", "#111111", updated = 1_760_000_000.123)
        val b = Project("b", "B", "#222222", updated = 1_760_000_000.5)
        val mine = ProjectList(listOf(a, b))
        val theirs = ProjectList(listOf(b, a.copy(updated = a.updated + 0.0000003)))
        assertTrue(mine.agrees(theirs) && theirs.agrees(mine) && mine.merged(theirs).agrees(mine))
        val twice = ProjectList(listOf(a, b, a.copy(name = "A again")))
        assertTrue(twice.agrees(mine))
        assertEquals(2, twice.merged(mine).all.size)
        assertFalse(mine.agrees(ProjectList(listOf(a.copy(name = "Changed", updated = a.updated + 1), b))))
    }

    @Test fun `linking stays off, Bluetooth untouched, until it's turned on`() {
        val wire = Wire()
        val phone = Device("phone", false, wire) { 0.0 }
        phone.engine.start()
        assertFalse(phone.engine.isEnabled)
        assertEquals(null, phone.service)
        phone.engine.link("sandtimer-link:2:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        assertTrue(phone.engine.isEnabled && phone.service != null)
        phone.engine.setEnabled(false)
        assertTrue(phone.service == null && phone.engine.isLinked)
        phone.engine.start()
        assertEquals(null, phone.service)
    }

    @Test fun `a session shown from the Mac isn't counted on the phone`() {
        val zone = ZoneOffset.UTC
        val start = LocalDateTime.of(2026, 10, 7, 9, 0).toInstant(zone).toEpochMilli()
        val shown = Timer(TimerState(25, runningUntil = start + 1_500_000, countedFrom = start, started = start, counts = false), SandLog())
        val later = shown.counted(start + 600_000, zone).settled(start + 2_000_000, zone)
        assertTrue(later.log.days.isEmpty())
        val own = Timer(shown.state.copy(counts = true), SandLog()).settled(start + 2_000_000, zone)
        assertEquals(1500.0, own.log.days["2026-10-07"]!!.seconds, 1e-9)
        assertNotNull(own.log.days["2026-10-07"]!!.finished.takeIf { it == 1 })
    }
}
