package io.github.and.sandtimer.link

import io.github.and.sandtimer.data.ProjectList
import io.github.and.sandtimer.data.SandLog
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import java.util.UUID
import kotlin.math.abs

/**
 * The timer as linked devices share it: one timer on every screen. Each device writes it when someone changes the
 * timer there, stamped with the moment, and the latest change wins. The device that started a session is its
 * [owner], and only the owner counts its time, so a session seen on two screens is counted once. Times are seconds
 * since 1970, as they travel. The Mac's is SharedTimer in Sources/LinkFormat.swift.
 */
data class SharedTimer(
    val minutes: Int,
    /** When the session began; it identifies the session across devices. */
    val started: Double? = null,
    val runningUntil: Double? = null,
    val pausedWith: Double? = null,
    val project: String? = null,
    val owner: String = "",
    val stamp: Double = DISTANT_PAST,
) {
    enum class Phase { IDLE, RUNNING, PAUSED }

    fun phase(now: Double): Phase = when {
        runningUntil != null && runningUntil > now -> Phase.RUNNING
        runningUntil == null && (pausedWith ?: 0.0) > 0 -> Phase.PAUSED
        else -> Phase.IDLE
    }

    fun remaining(now: Double): Double = when (phase(now)) {
        Phase.RUNNING -> runningUntil!! - now
        Phase.PAUSED -> pausedWith!!
        Phase.IDLE -> 0.0
    }

    /** Whether two say the same thing, near enough: an animation or a radio's delay shouldn't count as a change. */
    fun matches(other: SharedTimer, now: Double): Boolean {
        val phase = phase(now)
        if (phase != other.phase(now) || minutes != other.minutes || project != other.project) return false
        return when (phase) {
            Phase.IDLE -> true
            Phase.RUNNING -> sameSession(other) && abs(runningUntil!! - other.runningUntil!!) <= 1.5
            Phase.PAUSED -> sameSession(other) && abs(pausedWith!! - other.pausedWith!!) <= 1.5
        }
    }

    fun sameSession(other: SharedTimer): Boolean {
        if (started == null || other.started == null) return started == null && other.started == null
        return abs(started - other.started) <= 1
    }

    fun toJson() = buildJsonObject {
        put("minutes", minutes)
        put("owner", owner)
        put("stamp", stamp)
        started?.let { put("started", it) }
        runningUntil?.let { put("runningUntil", it) }
        pausedWith?.let { put("pausedWith", it) }
        project?.let { put("project", it) }
    }

    companion object {
        /** The Mac's Date.distantPast, in seconds since 1970. */
        const val DISTANT_PAST = -62135769600.0

        fun fromJson(json: JsonElement?): SharedTimer? {
            val o = json as? JsonObject ?: return null
            fun num(key: String) = (o[key] as? JsonPrimitive)?.doubleOrNull
            val minutes = (o["minutes"] as? JsonPrimitive)?.let { it.intOrNull ?: it.doubleOrNull?.toInt() } ?: return null
            return SharedTimer(
                minutes, num("started"), num("runningUntil"), num("pausedWith"),
                (o["project"] as? JsonPrimitive)?.contentOrNull, (o["owner"] as? JsonPrimitive)?.contentOrNull ?: "",
                num("stamp") ?: DISTANT_PAST,
            )
        }
    }
}

/** The app a link works for: the engine asks it for what to share, and hands it what the other devices changed. */
interface LinkHost {
    val projects: ProjectList
    fun takeLinkedProjects(list: ProjectList)
    fun ownLog(): SandLog
    /** The timer here, unstamped and with no owner. */
    fun localTimer(): SharedTimer
    /** Make the timer here what another device made it. [counts] says whether this device counts its time. */
    fun adopt(timer: SharedTimer, counts: Boolean)
    /** The linked records, the devices or their connections changed. */
    fun linkChanged()
}

/** How the engine reaches the other devices. */
interface LinkTransport {
    fun start(service: UUID)
    fun stop()
    fun send(message: ByteArray, peer: String)
}

/** Where the link keeps what it knows: the app's private settings, or a map in tests. */
interface LinkStorage {
    fun get(key: String): String?
    fun put(key: String, value: String?)
}

/** Another device this one is linked with. */
data class LinkedDevice(val id: String, val name: String, val kind: String, val seen: Double)

/**
 * Linking, as the Mac's LinkEngine (Sources/LinkEngine.swift) does it, message for message: a phone connects to the
 * Mac over Bluetooth and greets it, and from then on they share one timer, the projects and the record. The Mac is
 * the hub, passing on what one phone says to the others. All of it runs on one thread: the main one.
 */
class LinkEngine(
    private val name: String,
    private val kind: String,
    private val isHub: Boolean,
    private val storage: LinkStorage,
    /** Runs something after a delay; the app uses the main thread's handler. */
    private val later: (Long, () -> Unit) -> Unit,
    private val clock: () -> Double = { System.currentTimeMillis() / 1000.0 },
) {
    var host: LinkHost? = null
    var transport: LinkTransport? = null
    /** Told whenever something Settings shows has changed. */
    var onChange: () -> Unit = {}

    private class Peer(var device: LinkedDevice? = null, var have: MutableMap<String, MutableMap<String, String>> = mutableMapOf(), var greeted: Boolean = false)

    private val peers = mutableMapOf<String, Peer>()
    private var adopting = false
    private var logsSoon = 0

    val key: ByteArray? get() = storage.get(KEY)?.let { runCatching { Crypto.keyFromBase64(it) }.getOrNull() }?.takeIf { it.size == 32 }
    val isLinked: Boolean get() = key != null

    /**
     * Linking is off until it's turned on in Settings, and off means off: no Bluetooth at all, not even the question
     * of whether it may be used. Turning it off keeps the link, so turning it on again reconnects.
     */
    val isEnabled: Boolean get() = storage.get(ENABLED) == "true"

    fun setEnabled(on: Boolean) {
        storage.put(ENABLED, if (on) "true" else null)
        if (on) start() else {
            transport?.stop()
            for (peer in peers.keys.toList()) disconnected(peer)
        }
        onChange()
    }

    val deviceId: String
        get() = storage.get(DEVICE_ID) ?: UUID.randomUUID().toString().lowercase().also { storage.put(DEVICE_ID, it) }

    val devices: List<LinkedDevice>
        get() = array(DEVICES).mapNotNull { e ->
            val o = e as? JsonObject ?: return@mapNotNull null
            val id = o.str("id") ?: return@mapNotNull null
            LinkedDevice(id, o.str("name") ?: "Device", o.str("kind") ?: "", (o["seen"] as? JsonPrimitive)?.doubleOrNull ?: 0.0)
        }

    /** The ids of the devices connected right now. */
    val connected: Set<String> get() = peers.values.mapNotNull { it.device?.id }.toSet()

    val shared: SharedTimer? get() = SharedTimer.fromJson(obj(TIMER))

    /** Whether this device counts the time of the session going now: it does unless another device started it. */
    val countsHere: Boolean
        get() {
            val owner = shared?.owner
            return !isLinked || owner.isNullOrEmpty() || owner == deviceId
        }

    /** The other devices' records, by device id, each as SandLog's JSON. */
    val linkedLogs: JsonObject get() = obj(LOGS) ?: JsonObject(emptyMap())

    fun start() {
        if (!isEnabled) return
        val key = key ?: return
        transport?.start(Crypto.serviceUuid(key))
    }

    // Linking

    /** The Mac's QR code, making the key first if this is the first phone. */
    fun linkCode(): String {
        val made = key == null
        if (made) storage.put(KEY, Crypto.keyToBase64(ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }))
        if (!isEnabled) setEnabled(true) else if (made) start()  // a new key is a new service to offer
        return LinkCode.PREFIX + java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(key)
    }

    /** A phone joining the Mac whose code it scanned. */
    fun link(code: String) {
        val key = LinkCode.parse(code) ?: throw IllegalArgumentException("That isn't a Sand Timer code. On the Mac, open Sand Timer's Settings and click Link a Phone…")
        if (!key.contentEquals(this.key ?: ByteArray(0))) forget()
        storage.put(KEY, Crypto.keyToBase64(key))
        storage.put(ENABLED, "true")
        start()
        onChange()
    }

    /** A phone says goodbye to the Mac, or the Mac tells every phone it is no longer linked, then forgets the link. */
    fun unlink() {
        broadcast(message(if (isHub) "unlinked" else "bye") {})
        later(1000) { forget() }
    }

    /** Forgets the link here: the key, the other devices and their records. This device's own record stays. */
    fun forget() {
        transport?.stop()
        for (k in listOf(KEY, LOGS, DEVICES, DIGESTS, TIMER)) storage.put(k, null)
        peers.clear()
        host?.linkChanged()
        onChange()
    }

    // Changes made here

    /** The timer changed here: stamped and sent, unless it is only an echo of the shared one. */
    fun timerChanged() {
        val host = host ?: return
        if (!isLinked || adopting) return
        val now = clock()
        var local = host.localTimer()
        if (local.phase(now) != SharedTimer.Phase.RUNNING) sendLogsSoon()
        val before = shared
        if (before != null && before.matches(local, now)) return
        val ongoing = before != null && local.phase(now) != SharedTimer.Phase.IDLE && before.sameSession(local)
        local = local.copy(owner = if (ongoing) before!!.owner else deviceId, stamp = now)
        storage.put(TIMER, local.toJson().toString())
        broadcast(message("timer") { put("timer", local.toJson()) })
    }

    fun projectsChanged() {
        val host = host ?: return
        if (!isLinked) return
        broadcast(message("projects") { put("projects", host.projects.toJson()) })
    }

    // The transport's news

    fun connected(peer: String) {
        peers[peer] = Peer()
        if (!isHub) greet(peer)
        onChange()
    }

    fun disconnected(peer: String) {
        val gone = peers.remove(peer) ?: return
        gone.device?.let { remember(it, clock()) }
        host?.linkChanged()
        onChange()
    }

    fun received(data: ByteArray, peer: String) {
        val key = key ?: return
        if (peer !in peers) return
        val opened = runCatching { Crypto.open(data, key) }.getOrNull() ?: return
        val message = runCatching { Json.parseToJsonElement(String(opened, Charsets.UTF_8)).jsonObject }.getOrNull() ?: return
        when (message.str("t")) {
            "hello" -> hello(message, peer)
            "projects" -> takeProjects(message["projects"], peer)
            "timer" -> takeTimer(SharedTimer.fromJson(message["timer"]), peer)
            "logs" -> takeLogs(message, peer)
            "bye" -> {
                val id = peers[peer]?.device?.id
                if (id != null) storage.put(DEVICES, JsonArray(array(DEVICES).filter { (it as? JsonObject)?.str("id") != id }).toString())
                peers[peer]?.device = null
                host?.linkChanged()
                onChange()
            }
            "unlinked" -> if (!isHub) forget()
        }
    }

    /** Every so often while connected: each side has the other's latest record. */
    fun sendLogs() {
        for (peer in peers.keys.toList()) if (peers[peer]?.device != null) sendLogs(peer)
    }

    // Messages

    private fun greet(peer: String) {
        val host = host ?: return
        peers[peer]?.greeted = true
        send(message("hello") {
            put("device", buildJsonObject { put("id", deviceId); put("name", name); put("kind", kind) })
            put("have", JsonObject(have().mapValues { (_, months) -> JsonObject(months.mapValues { JsonPrimitive(it.value) }) }))
            put("projects", host.projects.toJson())
            shared?.let { put("timer", it.toJson()) }
        }, peer)
    }

    private fun hello(message: JsonObject, peer: String) {
        val info = message["device"] as? JsonObject ?: return
        val id = info.str("id") ?: return
        if (id == deviceId) return
        val device = LinkedDevice(id, info.str("name") ?: "Device", info.str("kind") ?: "", clock())
        val p = peers[peer] ?: return
        p.device = device
        p.have = (message["have"] as? JsonObject).orEmpty().mapValues { (_, months) ->
            (months as? JsonObject).orEmpty().mapValues { (it.value as? JsonPrimitive)?.contentOrNull ?: "" }.toMutableMap()
        }.toMutableMap()
        remember(device, clock())
        if (!p.greeted) greet(peer)
        takeProjects(message["projects"], peer)
        takeTimer(SharedTimer.fromJson(message["timer"]), peer)
        sendLogs(peer)
        host?.linkChanged()
        onChange()
    }

    private fun takeProjects(value: JsonElement?, peer: String) {
        val host = host ?: return
        val theirs = ProjectList.fromJson(value as? JsonArray ?: return)
        val merged = host.projects.merged(theirs)
        if (merged != host.projects) {
            host.takeLinkedProjects(merged)
            if (isHub) broadcast(message("projects") { put("projects", merged.toJson()) }, except = peer)
        }
        if (merged != theirs) send(message("projects") { put("projects", merged.toJson()) }, peer)
    }

    /** The other side's timer: taken on if it's the later change, otherwise ours goes back to it. */
    private fun takeTimer(theirs: SharedTimer?, peer: String) {
        val host = host ?: return
        var mine = shared ?: host.localTimer().copy(stamp = SharedTimer.DISTANT_PAST)
        if (mine.owner.isEmpty()) mine = mine.copy(owner = deviceId)
        if (theirs == null || theirs.stamp <= mine.stamp) {
            if (theirs?.stamp != mine.stamp) send(message("timer") { put("timer", mine.toJson()) }, peer)
            return
        }
        storage.put(TIMER, theirs.toJson().toString())
        adopting = true
        try { host.adopt(theirs, counts = theirs.owner == deviceId) } finally { adopting = false }
        if (isHub) broadcast(message("timer") { put("timer", theirs.toJson()) }, except = peer)
    }

    private fun takeLogs(message: JsonObject, peer: String) {
        val device = message.str("device") ?: return
        val month = message.str("month") ?: return
        val digest = message.str("digest") ?: return
        val days = message["days"] as? JsonObject ?: return
        if (device == deviceId) return
        val records = linkedLogs.toMutableMap()
        val record = (records[device] as? JsonObject).orEmpty().filterKeys { !it.startsWith(month) } + days
        records[device] = JsonObject(record)
        storage.put(LOGS, JsonObject(records).toString())
        val digests = digests().toMutableMap()
        digests[device] = (digests[device].orEmpty() + (month to digest))
        storage.put(DIGESTS, digestsJson(digests).toString())
        peers[peer]?.have?.getOrPut(device) { mutableMapOf() }?.put(month, digest)
        host?.linkChanged()
        if (isHub) for (other in peers.keys.toList()) if (other != peer && peers[other]?.device != null) sendLogs(other)
    }

    private fun digests(): Map<String, Map<String, String>> = (obj(DIGESTS)).orEmpty().mapValues { (_, months) ->
        (months as? JsonObject).orEmpty().mapValues { (it.value as? JsonPrimitive)?.contentOrNull ?: "" }
    }

    private fun digestsJson(d: Map<String, Map<String, String>>) =
        JsonObject(d.mapValues { (_, m) -> JsonObject(m.mapValues { JsonPrimitive(it.value) }) })

    private fun have(): Map<String, Map<String, String>> {
        val own = host?.ownLog()?.byMonth().orEmpty().mapValues { Crypto.digest(it.value) }
        return digests() + (deviceId to own)
    }

    private fun sendLogsSoon() {
        val ticket = ++logsSoon
        later(2000) { if (ticket == logsSoon) sendLogs() }
    }

    /** The months the other side lacks or holds an older copy of: this device's own, and on the Mac the others'. */
    private fun sendLogs(peer: String) {
        val host = host ?: return
        val them = peers[peer]?.device?.id ?: return
        data class Item(val device: String, val month: String, val digest: String, val days: JsonObject)
        val outgoing = mutableListOf<Item>()
        for ((month, days) in host.ownLog().byMonth()) outgoing += Item(deviceId, month, Crypto.digest(days), days)
        if (isHub) {
            val digests = digests()
            for ((device, record) in linkedLogs) {
                if (device == them) continue
                val months = (record as? JsonObject).orEmpty().entries.groupBy({ it.key.take(7) }, { it.key to it.value })
                for ((month, entries) in months) {
                    val days = JsonObject(entries.toMap())
                    outgoing += Item(device, month, digests[device]?.get(month) ?: Crypto.digest(days), days)
                }
            }
        }
        for (item in outgoing.sortedWith(compareBy({ it.month }, { it.device }))) {
            if (peers[peer]?.have?.get(item.device)?.get(item.month) == item.digest) continue
            send(message("logs") {
                put("device", item.device); put("month", item.month); put("digest", item.digest); put("days", item.days)
            }, peer)
            peers[peer]?.have?.getOrPut(item.device) { mutableMapOf() }?.put(item.month, item.digest)
        }
    }

    private fun remember(device: LinkedDevice, seen: Double) {
        val list = array(DEVICES).filter { (it as? JsonObject)?.str("id") != device.id } + buildJsonObject {
            put("id", device.id); put("name", device.name); put("kind", device.kind); put("seen", seen)
        }
        storage.put(DEVICES, JsonArray(list).toString())
    }

    private fun message(type: String, body: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit) =
        buildJsonObject { put("t", type); body() }

    private fun broadcast(message: JsonObject, except: String? = null) {
        for (peer in peers.keys.toList()) if (peer != except && (peers[peer]?.device != null || !isHub)) send(message, peer)
    }

    private fun send(message: JsonObject, peer: String) {
        val key = key ?: return
        transport?.send(Crypto.seal(message.toString().toByteArray(Charsets.UTF_8), key), peer)
    }

    private fun obj(key: String): JsonObject? = storage.get(key)?.let { runCatching { Json.parseToJsonElement(it).jsonObject }.getOrNull() }
    private fun array(key: String): List<JsonElement> =
        storage.get(key)?.let { runCatching { Json.parseToJsonElement(it) as? JsonArray }.getOrNull() }.orEmpty()

    companion object {
        const val KEY = "link.key"
        const val DEVICE_ID = "deviceId"
        const val DEVICES = "link.devices"
        const val LOGS = "linkedLogs"
        const val DIGESTS = "link.digests"
        const val TIMER = "link.timer"
        const val ENABLED = "link.enabled"
    }
}

private fun JsonObject.str(key: String) = (this[key] as? JsonPrimitive)?.contentOrNull
private fun JsonObject?.orEmpty(): Map<String, JsonElement> = this ?: emptyMap()
