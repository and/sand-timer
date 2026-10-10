package io.github.and.sandtimer.link

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import io.github.and.sandtimer.R
import io.github.and.sandtimer.data.Store
import io.github.and.sandtimer.ui.MainActivity

/**
 * Keeps the app running while linked, so the phone stays connected to the Mac with the app closed: a session
 * started on the Mac shows here, and one paused here pauses there. Android asks for a notification while it runs;
 * it sits quietly at the bottom of the shade, and can be swiped away or turned off in the app's notification settings.
 */
class LinkService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private val logs = object : Runnable {
        override fun run() {
            Link.engine.sendLogs()
            main.postDelayed(this, 5 * 60_000L)
        }
    }
    private val bluetooth = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, 0) == BluetoothAdapter.STATE_ON) Link.wake()
            else Link.radio.onChange()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Store.init(this)
        Link.init(this)
        startForeground(ID, notification(this), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        registerReceiver(bluetooth, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
        main.postDelayed(logs, 5 * 60_000L)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        main.removeCallbacks(logs)
        unregisterReceiver(bluetooth)
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "link"
        private const val ID = 3
        private var running = false

        /** Runs while linked, once Bluetooth may be used. */
        fun start(context: Context) {
            if (!Link.engine.isEnabled || !Link.engine.isLinked || !Link.radio.allowed || running) return
            runCatching { context.startForegroundService(Intent(context, LinkService::class.java)) }
                .onSuccess { running = true }
        }

        fun stop(context: Context) {
            running = false
            context.stopService(Intent(context, LinkService::class.java))
        }

        fun createChannel(context: Context) {
            context.getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, "Linked to your Mac", NotificationManager.IMPORTANCE_MIN).apply {
                    description = "Keeps Sand Timer connected to your Mac in the background"
                    setShowBadge(false)
                },
            )
        }

        /** The notification says whether the Mac is connected. */
        fun update(context: Context) {
            if (!running) return
            context.getSystemService(NotificationManager::class.java).notify(ID, notification(context))
        }

        private fun notification(context: Context): Notification {
            val link = Store.state.value.link
            val mac = link.devices.firstOrNull { it.id in link.connected }
            val text = when {
                link.problem != null -> link.problem
                mac != null -> "Connected to ${mac.name}"
                else -> "Looking for your Mac nearby"
            }
            val open = PendingIntent.getActivity(
                context, 0, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE,
            )
            return Notification.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle("Linked to your Mac")
                .setContentText(text)
                .setContentIntent(open)
                .setOngoing(true)
                .setShowWhen(false)
                .build()
        }
    }
}
