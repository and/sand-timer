package io.github.and.sandtimer.link

import android.annotation.SuppressLint
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.github.and.sandtimer.data.LinkInfo
import io.github.and.sandtimer.data.ProjectList
import io.github.and.sandtimer.data.SandLog
import io.github.and.sandtimer.data.Store
import io.github.and.sandtimer.timer.Engine

/**
 * This phone as a linked device of a Mac, the way a phone links to a messaging account. The Mac's QR code carries
 * a key; with it the phone finds the Mac over Bluetooth whenever they're near each other, and the two share one
 * timer, the projects and the record (see [LinkEngine]). While linked, [LinkService] keeps the app connected in the
 * background.
 */
@SuppressLint("StaticFieldLeak")  // the application's context, which lives as long as the app does
object Link {
    private lateinit var context: Context
    private val main = Handler(Looper.getMainLooper())
    lateinit var engine: LinkEngine
        private set
    lateinit var radio: Radio
        private set

    fun init(context: Context) {
        if (::engine.isInitialized) return
        this.context = context.applicationContext
        engine = LinkEngine(deviceName(), "android", isHub = false, Store.linkStorage, later = { ms, block -> main.postDelayed(block, ms) })
        radio = Radio(this.context, engine, main)
        engine.host = Host
        engine.transport = radio
        engine.onChange = ::publish
        radio.onChange = ::publish
        Store.onProjectsChanged = { engine.projectsChanged() }
        Store.onActiveProjectChanged = { engine.timerChanged() }
        engine.start()
        publish()
        LinkService.start(this.context)
    }

    /** Joins the Mac whose code was scanned. */
    fun link(code: String) {
        engine.link(code)
        LinkService.start(context)
    }

    /** Turns linking on or off. Off means no Bluetooth at all; the link is kept for when it's turned on again. */
    fun setEnabled(on: Boolean) {
        engine.setEnabled(on)
        if (on) LinkService.start(context) else LinkService.stop(context)
        publish()
    }

    /** Says goodbye to the Mac and forgets the link. This phone's time already shared stays in the Mac's statistics. */
    fun unlink() {
        engine.unlink()
        main.postDelayed({ LinkService.stop(context) }, 1500)
    }

    /** The app came to the front, or Bluetooth came on, or permission was given: look for the Mac now. */
    fun wake() {
        if (!engine.isLinked || !engine.isEnabled) return
        engine.start()
        radio.wake()
        LinkService.start(context)
        publish()
    }

    /** The timer changed here. */
    fun timerChanged() = engine.timerChanged()

    private fun publish() {
        Store.linkChanged(LinkInfo(engine.isEnabled, engine.isLinked, engine.devices, engine.connected, radio.problem.takeIf { engine.isEnabled }))
        LinkService.update(context)
    }

    private fun deviceName(): String =
        Build.MODEL.let { model -> if (model.startsWith(Build.MANUFACTURER, ignoreCase = true)) model else "${Build.MANUFACTURER} $model" }
            .replaceFirstChar { it.uppercase() }

    /** The app, as the link sees it. */
    private object Host : LinkHost {
        override val projects: ProjectList get() = Store.state.value.projects

        override fun takeLinkedProjects(list: ProjectList) = Store.setProjects(list)

        override fun ownLog(): SandLog {
            Engine.refresh(context)  // the time run so far counts, not just finished stretches
            return Store.state.value.timer.log
        }

        override fun localTimer(): SharedTimer {
            val app = Store.state.value
            val state = app.timer.state
            val now = System.currentTimeMillis()
            val inSession = state.inSession(now)
            return SharedTimer(
                minutes = state.minutes,
                started = state.started?.takeIf { inSession }?.let { it / 1000.0 },
                runningUntil = state.runningUntil?.takeIf { state.isRunning(now) }?.let { it / 1000.0 },
                pausedWith = state.pausedWith?.takeIf { state.isPaused(now) }?.let { it / 1000.0 },
                project = if (inSession) state.project else app.activeProject,
            )
        }

        override fun adopt(timer: SharedTimer, counts: Boolean) = Engine.adopt(context, timer, counts)

        override fun linkChanged() = publish()
    }
}
