package io.github.and.sandtimer.ui

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlin.math.sqrt

/**
 * The clean view: while the sand runs, everything but the glass fades away after a few still seconds — the
 * controls, the tabs and the phone's own bars — and comes back the moment the phone is picked up, moved or touched.
 */
object Calm {
    /** Everything but the glass is hidden. */
    val hidden = MutableStateFlow(false)
    /** When the phone last moved or was touched. */
    private val moved = MutableStateFlow(System.currentTimeMillis())
    private const val STILL_FOR = 3_000L

    /** The phone moved or was touched: show everything, and start counting the still seconds again. */
    fun wake() {
        moved.value = System.currentTimeMillis()
        hidden.value = false
    }

    /** Watches the phone while [on]: the sand running, with the clean view turned on and the timer showing. */
    @Composable
    fun Watch(on: Boolean) {
        val context = LocalContext.current
        val last by moved.collectAsState()
        DisposableEffect(on) {
            if (!on) {
                hidden.value = false
                return@DisposableEffect onDispose {}
            }
            val stop = listen(context)
            onDispose {
                stop()
                hidden.value = false
            }
        }
        LaunchedEffect(on, last) {
            if (!on) return@LaunchedEffect
            delay(STILL_FOR)
            hidden.value = true
        }
    }

    /** Movement, from the motion sensor: a nudge worth a third of a metre per second squared is enough. */
    private fun listen(context: Context): () -> Unit {
        val sensors = context.getSystemService(SensorManager::class.java) ?: return {}
        val linear = sensors.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION)
        val sensor = linear ?: sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER) ?: return {}
        var previous: FloatArray? = null
        val listener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                val v = event.values
                // Linear acceleration is movement already; raw acceleration includes gravity, so compare with the last reading.
                val p = if (linear != null) floatArrayOf(0f, 0f, 0f) else previous ?: v.copyOf().also { previous = it }
                val dx = v[0] - p[0]
                val dy = v[1] - p[1]
                val dz = v[2] - p[2]
                if (linear == null) previous = v.copyOf()
                if (sqrt(dx * dx + dy * dy + dz * dz) > 0.35f) wake()
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
        }
        sensors.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_UI)
        return { sensors.unregisterListener(listener) }
    }
}
