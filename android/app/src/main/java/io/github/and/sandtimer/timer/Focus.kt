package io.github.and.sandtimer.timer

import android.app.AutomaticZenRule
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.service.notification.Condition
import io.github.and.sandtimer.data.Store
import io.github.and.sandtimer.ui.MainActivity

/**
 * Focus while the sand runs: Sand Timer's own Do Not Disturb mode, on while the sand runs and off at a pause, an end
 * or the sand running out. It appears among the phone's modes as "Sand Timer", where what it lets through can be
 * changed; until then it follows the phone's own Do Not Disturb settings. Android asks once for permission to
 * manage Do Not Disturb.
 */
object Focus {
    private val condition: Uri = Uri.parse("condition://io.github.and.sandtimer/running")

    fun allowed(context: Context): Boolean =
        context.getSystemService(NotificationManager::class.java).isNotificationPolicyAccessGranted

    /** Android's page for allowing it. */
    fun ask(context: Context) =
        context.startActivity(Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))

    /** Matches the mode to the timer: on while the sand runs, if Focus is turned on and allowed. */
    fun update(context: Context, running: Boolean) {
        if (!allowed(context)) return
        val manager = context.getSystemService(NotificationManager::class.java)
        val on = running && Store.state.value.settings.focus
        val id = rule(context, manager, create = on) ?: return
        runCatching {
            manager.setAutomaticZenRuleState(
                id, Condition(condition, if (on) "The sand is running" else "", if (on) Condition.STATE_TRUE else Condition.STATE_FALSE),
            )
        }
    }

    /** The mode's id, made the first time it's needed. */
    private fun rule(context: Context, manager: NotificationManager, create: Boolean): String? {
        val prefs = context.getSharedPreferences("sandtimer", Context.MODE_PRIVATE)
        prefs.getString("focus.rule", null)?.let { if (manager.getAutomaticZenRule(it) != null) return it }
        if (!create) return null
        val rule = AutomaticZenRule(
            "Sand Timer", null, ComponentName(context, MainActivity::class.java), condition, null,
            NotificationManager.INTERRUPTION_FILTER_PRIORITY, true,
        )
        val id = runCatching { manager.addAutomaticZenRule(rule) }.getOrNull() ?: return null
        prefs.edit().putString("focus.rule", id).apply()
        return id
    }
}
