package io.github.and.sandtimer

import android.app.Application
import io.github.and.sandtimer.data.Store
import io.github.and.sandtimer.link.Link
import io.github.and.sandtimer.link.LinkService
import io.github.and.sandtimer.timer.Notifications

class SandTimerApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Store.init(this)
        Notifications.createChannels(this)
        LinkService.createChannel(this)
        Link.init(this)  // finds the linked Mac over Bluetooth, if there is one
    }
}
