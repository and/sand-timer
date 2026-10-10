package io.github.and.sandtimer.data

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import java.time.ZoneId

/** The few choices that aren't the timer itself. */
data class Settings(
    /** Play the chime when the sand runs out. */
    val chime: Boolean = true,
    /** A daily target in minutes; 0 for none. */
    val targetMinutes: Int = 0,
    /** Keep the project for the whole session, as the Mac does by default. */
    val oneThingAtATime: Boolean = true,
    /** Keep the screen awake while the sand runs and the timer is showing. */
    val keepScreenOn: Boolean = true,
    /** Turn on Sand Timer's own Do Not Disturb mode while the sand runs. */
    val focus: Boolean = false,
    /** While the sand runs, hide everything but the glass until the phone moves. */
    val calm: Boolean = true,
    /** Come to the front when the linked Mac starts the timer, while the screen is on. */
    val openOnMacStart: Boolean = false,
)

/** How linking stands, for the Settings screen. */
data class LinkInfo(
    /** Turned on in Settings: until then the app doesn't touch Bluetooth. */
    val enabled: Boolean = false,
    val linked: Boolean = false,
    val devices: List<io.github.and.sandtimer.link.LinkedDevice> = emptyList(),
    /** The ids of the devices connected right now. */
    val connected: Set<String> = emptySet(),
    /** Why the phone can't reach the Mac, when it can't: Bluetooth off or not allowed. */
    val problem: String? = null,
)

/** Everything the screens draw. */
data class AppState(
    val timer: Timer = Timer(TimerState(), SandLog()),
    val projects: ProjectList = ProjectList(),
    /** The project new sessions count against; null for none. */
    val activeProject: String? = null,
    /** Linked devices' records, added together. */
    val linkedLog: SandLog = SandLog(),
    val settings: Settings = Settings(),
    val link: LinkInfo = LinkInfo(),
) {
    /** This phone's record with the linked devices': what Statistics and the target count. */
    val wholeLog: SandLog get() = timer.log.including(linkedLog)
}

/**
 * The app's state, kept in its private settings and handed out as a flow. Every change goes through here, so the
 * screens, the notification and the alarm always agree.
 */
object Store {
    private lateinit var prefs: SharedPreferences
    private val json = Json { ignoreUnknownKeys = true }
    private val _state = MutableStateFlow(AppState())
    val state: StateFlow<AppState> = _state.asStateFlow()
    val zone: ZoneId get() = ZoneId.systemDefault()
    /** Called after a change to the projects made here, so a linked Mac hears of it. */
    var onProjectsChanged: () -> Unit = {}
    /** Called after the project that's on changes here, which a linked Mac shows too. */
    var onActiveProjectChanged: () -> Unit = {}

    /** The private settings, for the link to keep what it knows beside everything else. */
    val linkStorage = object : io.github.and.sandtimer.link.LinkStorage {
        override fun get(key: String): String? = prefs.getString(key, null)
        override fun put(key: String, value: String?) {
            prefs.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
        }
    }

    fun init(context: Context) {
        if (::prefs.isInitialized) return
        prefs = context.applicationContext.getSharedPreferences("sandtimer", Context.MODE_PRIVATE)
        _state.value = load()
    }

    private fun load(): AppState {
        val timer = prefs.getString("timer", null)?.let { runCatching { json.decodeFromString<TimerState>(it) }.getOrNull() } ?: TimerState()
        return AppState(
            timer = Timer(timer, SandLog.fromJson(obj("log"))),
            projects = ProjectList.fromJson(prefs.getString("projects", null)?.let { runCatching { json.parseToJsonElement(it).jsonArray }.getOrNull() }),
            activeProject = prefs.getString("activeProject", null),
            linkedLog = linkedLog(obj("linkedLogs")),
            settings = Settings(
                chime = prefs.getBoolean("chime", true),
                targetMinutes = prefs.getInt("targetMinutes", 0),
                oneThingAtATime = prefs.getBoolean("oneThingAtATime", true),
                keepScreenOn = prefs.getBoolean("keepScreenOn", true),
                focus = prefs.getBoolean("focus", false),
                calm = prefs.getBoolean("calm", true),
                openOnMacStart = prefs.getBoolean("openOnMacStart", false),
            ),
        )
    }

    private fun obj(key: String): JsonObject? =
        prefs.getString(key, null)?.let { runCatching { json.parseToJsonElement(it).jsonObject }.getOrNull() }

    private fun linkedLog(records: JsonObject?): SandLog =
        records.orEmpty().values.fold(SandLog()) { sum, record -> sum.including(SandLog.fromJson(record as? JsonObject)) }

    // Changes

    /** Changes the timer and its record together, keeping the record pruned. */
    @Synchronized
    fun updateTimer(change: (Timer) -> Timer) {
        val before = _state.value.timer
        val after = change(before).let { it.copy(log = it.log.pruned(java.time.LocalDate.now(zone))) }
        if (after == before) return
        prefs.edit()
            .putString("timer", json.encodeToString(TimerState.serializer(), after.state))
            .apply { if (after.log != before.log) putString("log", after.log.toJson().toString()) }
            .apply()
        _state.value = _state.value.copy(timer = after)
    }

    /** A change made here: the projects it touched are stamped now, for merging with a linked Mac's. */
    fun updateProjects(list: ProjectList) {
        setProjects(list.stamped(_state.value.projects, System.currentTimeMillis() / 1000.0))
        onProjectsChanged()
    }

    /** Takes a list as it stands: from [updateProjects], or put together with a linked Mac's. */
    @Synchronized
    fun setProjects(list: ProjectList) {
        prefs.edit().putString("projects", list.toJson().toString()).apply()
        var active = _state.value.activeProject
        if (list.project(active)?.archived != false) active = null
        prefs.edit().putString("activeProject", active).apply()
        _state.value = _state.value.copy(projects = list, activeProject = active)
    }

    fun setActiveProject(id: String?) {
        if (id == _state.value.activeProject) return
        prefs.edit().putString("activeProject", id).apply()
        _state.value = _state.value.copy(activeProject = id)
        onActiveProjectChanged()
    }

    fun updateSettings(change: (Settings) -> Settings) {
        val s = change(_state.value.settings)
        prefs.edit().putBoolean("chime", s.chime).putInt("targetMinutes", s.targetMinutes)
            .putBoolean("oneThingAtATime", s.oneThingAtATime).putBoolean("keepScreenOn", s.keepScreenOn)
            .putBoolean("focus", s.focus).putBoolean("calm", s.calm)
            .putBoolean("openOnMacStart", s.openOnMacStart).apply()
        _state.value = _state.value.copy(settings = s)
    }

    // Linking

    /** The link's news, for the screens: the linked records again, and how the devices stand. */
    fun linkChanged(info: LinkInfo) {
        _state.value = _state.value.copy(linkedLog = linkedLog(obj("linkedLogs")), link = info)
    }
}

private fun JsonObject?.orEmpty(): Map<String, kotlinx.serialization.json.JsonElement> = this ?: emptyMap()

