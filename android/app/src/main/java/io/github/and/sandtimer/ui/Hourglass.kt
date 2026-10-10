package io.github.and.sandtimer.ui

import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import android.graphics.Typeface
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathOperation
import androidx.compose.ui.graphics.PointMode
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/*
 * The Mac's timer, drawn the same way (Sources/HourglassRenderer.swift, Sources/SandPhysics.swift and the
 * HourglassGeometry in Sources/Model.swift): a 200 × 400 unit space, y down, the neck at (100, 200). The glass is a
 * turned profile; the sand in the top drains as a funnel crater and builds a cone at the angle of repose below.
 */

private const val CX = 100.0
private const val NECK_Y = 200.0

/** The glass's profile and the volumes it holds, as the Mac's `HourglassGeometry`. */
private object Geo {
    const val HALF_LENGTH = 154.0
    const val BULB_RADIUS = 55.0
    const val NECK_RADIUS = 4.5
    const val NECK_HALF = 3.0
    const val TAPER_LENGTH = 68.0
    const val WALL = 2.2
    const val SAND_FULL_HEIGHT = 76.0
    const val STEP = 0.25

    fun outerRadius(distance: Double, neckScale: Double = 1.0): Double {
        val d = abs(distance)
        val neck = NECK_RADIUS * max(1.0, neckScale)
        if (d <= NECK_HALF) return neck
        val u = min(1.0, (d - NECK_HALF) / (TAPER_LENGTH - NECK_HALF))
        val easeOut = 1 - (1 - u).pow(2.5)
        val smooth = u * u * (3 - 2 * u)
        return neck + (BULB_RADIUS - neck) * (0.6 * easeOut + 0.4 * smooth)
    }

    fun innerRadius(distance: Double, neckScale: Double = 1.0): Double {
        val plain = outerRadius(distance, neckScale) - WALL
        if (neckScale >= 1) return max(1.2 * neckScale, plain)
        val bore = (NECK_RADIUS - WALL) * neckScale
        val extra = (NECK_RADIUS - WALL) - bore
        return max(bore, plain - extra * exp(-abs(distance) / 6))
    }

    private val cumulative: DoubleArray = run {
        val n = (HALF_LENGTH / STEP).toInt()
        val c = DoubleArray(n + 1)
        var prev = innerRadius(0.0)
        for (i in 1..n) {
            val r = innerRadius(i * STEP)
            c[i] = c[i - 1] + PI * (prev * prev + r * r) / 2 * STEP
            prev = r
        }
        c
    }
    val halfVolume get() = cumulative.last()
    val sandVolume by lazy { volume(SAND_FULL_HEIGHT) }

    fun volume(distance: Double): Double {
        val x = min(max(distance, 0.0), HALF_LENGTH) / STEP
        val i = min(x.toInt(), cumulative.size - 2)
        return cumulative[i] + (cumulative[i + 1] - cumulative[i]) * (x - i)
    }

    fun distance(forVolume: Double): Double {
        val v = min(max(forVolume, 0.0), halfVolume)
        var lo = 0
        var hi = cumulative.size - 1
        while (hi - lo > 1) {
            val mid = (lo + hi) / 2
            if (cumulative[mid] < v) lo = mid else hi = mid
        }
        val span = cumulative[hi] - cumulative[lo]
        return (lo + if (span > 0) (v - cumulative[lo]) / span else 0.0) * STEP
    }

    fun topSandHeight(p: Double) = if (p >= 1) 0.0 else distance(sandVolume * (1 - p))
    fun bottomSurfaceDistance(p: Double) = distance(halfVolume - sandVolume * p)
}

/** The resting shapes of the sand, as the Mac's `SandPhysics`. */
private object Physics {
    const val REPOSE = 0.5

    fun neckScale(minutes: Int): Double {
        val width = (25.0 / max(minutes.toDouble(), 0.01)).pow(0.4)
        return min(2.6, max(0.6, if (width < 1) sqrt(width) else width))
    }

    fun funnelLength(neckScale: Double) = 2 + 1.5 * neckScale

    private inline fun integrate(upper: Double, f: (Double) -> Double): Double {
        if (upper <= 0) return 0.0
        var total = 0.0
        var start = 0.0
        while (start < upper) {
            val end = min(start + 1.0, upper)
            total += f((start + end) / 2) * (end - start)
            start = end
        }
        return total
    }

    private inline fun bisect(low: Double, high: Double, isBelow: (Double) -> Boolean): Double {
        var lo = low
        var hi = high
        repeat(40) {
            val mid = (lo + hi) / 2
            if (isBelow(mid)) lo = mid else hi = mid
        }
        return (lo + hi) / 2
    }

    fun pileVolume(peak: Double) = integrate(min(peak, Geo.HALF_LENGTH)) { z ->
        val radius = min(Geo.innerRadius(Geo.HALF_LENGTH - z), (peak - z) / REPOSE)
        PI * radius * radius
    }

    fun pilePeak(volume: Double): Double =
        if (volume <= 0) 0.0 else bisect(0.0, Geo.HALF_LENGTH + REPOSE * Geo.BULB_RADIUS) { pileVolume(it) < volume }

    fun craterVolume(tip: Double, flatLevel: Double) = integrate(min(flatLevel, Geo.HALF_LENGTH)) { d ->
        val wall = Geo.innerRadius(d)
        val hole = max(0.0, (d - tip) / REPOSE)
        if (hole < wall) PI * (wall * wall - hole * hole) else 0.0
    }

    fun craterTip(volume: Double, flatLevel: Double): Double {
        val lowest = -REPOSE * (Geo.BULB_RADIUS + 1)
        if (volume >= craterVolume(flatLevel, flatLevel)) return flatLevel
        if (volume <= 0) return lowest
        return bisect(lowest, flatLevel) { craterVolume(it, flatLevel) < volume }
    }

    fun smoothMax(a: Double, b: Double, width: Double): Double {
        val h = max(width - abs(a - b), 0.0) / width
        return max(a, b) + h * h * width / 4
    }

    fun smoothMin(a: Double, b: Double, width: Double) = -smoothMax(-a, -b, width)

    fun roundedCone(peak: Double, radius: Double, tipRadius: Double) =
        peak - REPOSE * (sqrt(radius * radius + tipRadius * tipRadius) - tipRadius)

    fun roughness(at: Double) = 0.45 * sin(at * 0.83 + 1.3) + 0.3 * sin(at * 2.1 + 0.4) + 0.2 * sin(at * 4.7 + 2.2)

    /** The top's sand: flat at `level`, with a funnel crater down to `tip`. */
    class Crater(val level: Double, val tip: Double) {
        fun height(offset: Double): Double {
            val funnel = tip + REPOSE * (sqrt(offset * offset + 16) - 4)
            val surface = smoothMin(level, funnel, 4.0)
            return smoothMax(0.0, surface, 1.5) + 0.5 * roughness(offset + 17)
        }
        val rim get() = max(0.0, min(Geo.BULB_RADIUS, (level - tip) / REPOSE))
    }

    /** The bottom's sand: a cone of `peak` on a flat `layer`. */
    class Pile(val layer: Double, val peak: Double) {
        fun height(offset: Double): Double {
            val heap = smoothMax(0.0, roundedCone(peak, abs(offset), 5.0), 3.0)
            return layer + heap + 0.7 * roughness(offset)
        }
        val foot get() = min(Geo.innerRadius(Geo.HALF_LENGTH - layer), peak / REPOSE)
    }

    fun crater(p: Double) = Geo.topSandHeight(0.0).let { level -> Crater(level, craterTip(Geo.sandVolume * (1 - p), level)) }
    fun pile(p: Double) = Pile(0.0, pilePeak(Geo.sandVolume * max(0.0, p)))

    // Sand lying flat whichever way the glass is turned: a bulb's outline clipped by a level line.

    private fun bulb(upper: Boolean): List<Offset> {
        val sign = if (upper) -1.0 else 1.0
        val distances = generateSequence(0.0) { it + 2 }.takeWhile { it < Geo.HALF_LENGTH }.toList() + Geo.HALF_LENGTH
        val right = distances.map { Offset((CX + Geo.innerRadius(it)).toFloat(), (NECK_Y + sign * it).toFloat()) }
        return right + right.reversed().map { Offset((2 * CX - it.x).toFloat(), it.y) }
    }
    private val upperBulb = bulb(true)
    private val lowerBulb = bulb(false)

    fun clip(poly: List<Offset>, gx: Double, gy: Double, offset: Double): List<Offset> {
        if (poly.isEmpty()) return poly
        fun side(p: Offset) = p.x * gx + p.y * gy - offset
        val out = ArrayList<Offset>()
        var previous = poly.last()
        for (current in poly) {
            val a = side(previous)
            val b = side(current)
            if ((a >= 0) != (b >= 0)) {
                val t = (a / (a - b)).toFloat()
                out += Offset(previous.x + (current.x - previous.x) * t, previous.y + (current.y - previous.y) * t)
            }
            if (b >= 0) out += current
            previous = current
        }
        return out
    }

    fun area(poly: List<Offset>): Double {
        if (poly.size < 3) return 0.0
        var sum = 0.0
        for (i in poly.indices) {
            val a = poly[i]
            val b = poly[(i + 1) % poly.size]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    fun flatArea(upper: Boolean, distance: Double): Double =
        area(clip(if (upper) upperBulb else lowerBulb, 0.0, 1.0, NECK_Y + if (upper) -distance else distance))

    /** The sand in a bulb holding `target` area, settled flat against gravity (`gx`, `gy` in the glass's frame). */
    fun settled(upper: Boolean, target: Double, gx: Double, gy: Double): List<Offset> {
        if (target <= 0.5) return emptyList()
        val poly = if (upper) upperBulb else lowerBulb
        val dots = poly.map { it.x * gx + it.y * gy }
        val offset = bisect(dots.min(), dots.max()) { area(clip(poly, gx, gy, it)) > target }
        return clip(poly, gx, gy, offset)
    }
}

/** What the caps show: the time on the base's ring, the project on the top's, and the day's target on the plate. */
data class Display(val time: String, val project: String?, val goal: Double?)

/** Grains seen through the round glass, crowding toward the walls: the Mac's cylindrical-lens speckles. */
private class Speckles {
    val light = ArrayList<Offset>()
    val dark = ArrayList<Offset>()

    init {
        var seed = 7uL
        fun random(): Double {
            seed += 0x9E3779B97F4A7C15uL
            var z = seed
            z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9uL
            z = (z xor (z shr 27)) * 0x94D049BB133111EBuL
            return ((z xor (z shr 31)) shr 11).toDouble() / (1uL shl 53).toDouble()
        }
        val lens = 54.0
        repeat(1100) {
            val u = max(-1.0, min(1.0, (random() * 112 - 56) / lens))
            val point = Offset((CX + lens * sin(PI / 2 * u)).toFloat(), (44 + random() * 312).toFloat())
            if (random() < 0.5) light += point else dark += point
        }
    }
}

private fun hash(i: Int, k: Int): Double {
    val v = sin(i * 12.9898 + k * 78.233) * 43758.5453
    return v - floor(v)
}

private fun mix(a: Color, b: Color, t: Float) = Color(
    a.red + (b.red - a.red) * t, a.green + (b.green - a.green) * t, a.blue + (b.blue - a.blue) * t, a.alpha,
)

/**
 * The timer, [fallen] of its sand run through (0 just flipped, 1 all below), turned [angle] degrees (90 lies it on
 * its side as a pause does; 180 is a flip). While [running] and upright the stream pours, [time] (seconds) moving
 * its grains. [minutes] sets the neck, wide for short timers and narrow for long ones, as on the Mac.
 */
@Composable
fun Hourglass(
    fallen: Float, angle: Float, running: Boolean, sand: Color, minutes: Int, display: Display, time: Double,
    modifier: Modifier = Modifier,
) {
    val speckles = remember { Speckles() }
    val neckScale = Physics.neckScale(minutes)
    val glass = remember(neckScale) { Pair(glassPath(false, neckScale), glassPath(true, neckScale)) }
    val p = fallen.toDouble().coerceIn(0.0, 1.0)
    val crater = remember(p) { Physics.crater(p) }
    val pile = remember(p) { Physics.pile(p) }

    Canvas(modifier) {
        // Fit standing up, lying down, or anywhere between as it turns.
        val lying = abs(sin(Math.toRadians(angle.toDouble()))).toFloat()
        val standing = min(size.width / 212f, size.height / 412f)
        val onSide = min(size.width / 412f, size.height / 212f)
        val unit = standing + (onSide - standing) * lying
        val pivot = Offset(CX.toFloat(), NECK_Y.toFloat())
        withTransform({
            translate(size.width / 2 - pivot.x, size.height / 2 - pivot.y)
            rotate(angle, pivot)
            scale(unit, unit, pivot)
        }) {
            drawGlassBody(glass.first)
            clipPath(glass.second) {
                if (abs(angle) < 0.5f) {
                    drawRestingSand(p, crater, pile, running, sand, neckScale, speckles, time)
                } else {
                    val rad = Math.toRadians(angle.toDouble())
                    val upper = Physics.flatArea(true, Geo.topSandHeight(p))
                    val lower = Physics.flatArea(false, Geo.bottomSurfaceDistance(p))
                    for (outline in listOf(Physics.settled(true, upper, sin(rad), cos(rad)), Physics.settled(false, lower, sin(rad), cos(rad)))) {
                        if (outline.size > 2) fillSand(polygon(outline), sand, speckles)
                    }
                }
            }
            drawGlassFront(glass.first, glass.second)
            drawCap(top = true)
            drawCap(top = false)
            printOnRing(display.time, Rect(19f, 354f, 181f, 382f), Rect(19f, 354f, 181f, 377f), 365.5f, 1f)
            // The project is a mark moulded into the top ring rather than a second display, so the eye goes to the time.
            display.project?.let { printOnRing(it, Rect(19f, 18f, 181f, 46f), Rect(19f, 23f, 181f, 46f), 34.5f, 0.42f) }
            display.goal?.let { drawGoal(it, sand) }
        }
    }
}

private fun glassPath(inner: Boolean, neckScale: Double): Path {
    val right = (0..180).map { i ->
        val y = 20.0 + i * 2
        val d = min(abs(y - NECK_Y), Geo.HALF_LENGTH)
        val r = if (inner) Geo.innerRadius(d, neckScale) else Geo.outerRadius(d, neckScale)
        Offset((CX + r).toFloat(), y.toFloat())
    }
    return Path().apply {
        moveTo(right[0].x, right[0].y)
        right.drop(1).forEach { lineTo(it.x, it.y) }
        right.reversed().forEach { lineTo((2 * CX).toFloat() - it.x, it.y) }
        close()
    }
}

private fun polygon(points: List<Offset>) = Path().apply {
    moveTo(points[0].x, points[0].y)
    points.drop(1).forEach { lineTo(it.x, it.y) }
    close()
}

private fun DrawScope.drawGlassBody(outer: Path) {
    val b = outer.getBounds()
    drawPath(outer, Brush.horizontalGradient(
        0f to Color(0.72f, 0.72f, 0.72f, 0.42f), 0.2f to Color(1f, 1f, 1f, 0.16f),
        0.65f to Color(1f, 1f, 1f, 0.10f), 1f to Color(0.72f, 0.72f, 0.72f, 0.38f),
        startX = b.left, endX = b.right,
    ))
}

private fun DrawScope.drawGlassFront(outer: Path, inner: Path) {
    clipPath(inner) { drawHighlights() }
    // The thickness of the wall, slightly darker where you look through more glass.
    drawPath(Path.combine(PathOperation.Difference, outer, inner), Color(0.45f, 0.45f, 0.45f, 0.16f))
    // A bright rim just inside the silhouette, where the curved glass catches the light.
    clipPath(outer) { drawPath(outer, Color.White.copy(alpha = 0.35f), style = Stroke(3f)) }
    drawPath(outer, Color(0.2f, 0.2f, 0.2f, 0.45f), style = Stroke(1.2f))
    drawPath(inner, Color.White.copy(alpha = 0.55f), style = Stroke(0.8f))
}

/** Soft reflections that follow the curve of each bulb. */
private fun DrawScope.drawHighlights() {
    for (sign in listOf(-1.0, 1.0)) {
        for ((offset, width, alpha) in listOf(Triple(-0.74, 4.5f, 0.55), Triple(0.8, 2.2f, 0.28))) {
            var previous: Offset? = null
            for (i in 0..40) {
                val s = i / 40.0
                val d = 10 + s * (Geo.HALF_LENGTH - 18)
                val point = Offset((CX + Geo.innerRadius(d) * offset).toFloat(), (NECK_Y + sign * d).toFloat())
                previous?.let {
                    drawLine(Color.White.copy(alpha = (alpha * sin(PI * s)).toFloat()), it, point, width, cap = StrokeCap.Round)
                }
                previous = point
            }
        }
    }
}

/** Sand shaded like a heap seen through round glass: dark at the walls, lit just off centre, with grains in it. */
private fun DrawScope.fillSand(path: Path, sand: Color, speckles: Speckles) {
    val b = path.getBounds()
    val edge = mix(sand, Color.Black, 0.45f)
    val lit = mix(sand, Color.White, 0.14f)
    drawPath(path, Brush.horizontalGradient(
        0f to edge, 0.22f to sand, 0.45f to lit, 0.78f to sand, 1f to edge, startX = b.left, endX = b.right,
    ))
    clipPath(path) {
        drawPoints(speckles.light, PointMode.Points, mix(sand, Color.White, 0.4f).copy(alpha = 0.55f), 1.3f, StrokeCap.Square)
        drawPoints(speckles.dark, PointMode.Points, mix(sand, Color.Black, 0.45f).copy(alpha = 0.5f), 1.3f, StrokeCap.Square)
    }
}

/** Standing up: the crater draining into the neck, the stream, and the pile building below. */
private fun DrawScope.drawRestingSand(
    p: Double, crater: Physics.Crater, pile: Physics.Pile, running: Boolean, sand: Color, neckScale: Double,
    speckles: Speckles, time: Double,
) {
    val bottomY = NECK_Y + Geo.HALF_LENGTH
    val flatTop = Geo.topSandHeight(p)
    val pouring = running && p < 1
    fun topY(offset: Double) = NECK_Y - crater.height(offset)
    fun bottomYAt(offset: Double) = bottomY - pile.height(offset)

    // The area under a surface, closed off below; while sand pours the top's narrows through the neck into the stream.
    fun region(y: (Double) -> Double, closingY: Double, lowest: Double, funnel: Boolean) = Path().apply {
        val half = 60.0
        val close = if (funnel) NECK_Y - 1 else closingY
        moveTo((CX - half).toFloat(), close.toFloat())
        for (i in 0..120) {
            val offset = -half + 2 * half * i / 120
            lineTo((CX + offset).toFloat(), min(lowest, y(offset)).toFloat())
        }
        lineTo((CX + half).toFloat(), close.toFloat())
        if (funnel) {
            val bore = Geo.innerRadius(0.0, neckScale) + 0.5
            val exit = 2.2 * neckScale
            val end = NECK_Y + Physics.funnelLength(neckScale)
            lineTo((CX + bore).toFloat(), close.toFloat())
            lineTo((CX + exit / 2).toFloat(), end.toFloat())
            lineTo((CX - exit / 2).toFloat(), end.toFloat())
            lineTo((CX - bore).toFloat(), close.toFloat())
        }
        close()
    }

    if (flatTop > 0.3) fillSand(region(::topY, NECK_Y + 1, NECK_Y + 1, pouring), sand, speckles)
    if (Geo.sandVolume * p > 1) fillSand(region(::bottomYAt, bottomY + 8, bottomY + 1, false), sand, speckles)
    if (!pouring) return

    val light = mix(sand, Color.White, 0.45f)
    val dark = mix(sand, Color.Black, 0.3f)
    // Grains creeping down the crater walls toward the neck.
    val slideTo = max(0.0, -crater.tip / Physics.REPOSE)
    if (flatTop > 0.3 && crater.rim - slideTo > 2) {
        for (i in 0 until 16) {
            val period = 1.4 + hash(i, 1) * 1.6
            val u = ((time + hash(i, 2) * period) / period).let { it - floor(it) }
            val side = if (hash(i, 3) < 0.5) -1 else 1
            val start = slideTo + (crater.rim - slideTo) * (0.3 + 0.7 * hash(i, 4))
            val offset = side * (slideTo + (start - slideTo) * (1 - u * u))
            drawRect(if (i % 3 == 0) light else dark, Offset((CX + offset - 0.8).toFloat(), (topY(offset) - 1.4).toFloat()), Size(1.6f, 1.6f))
        }
    }
    // The stream: a thin, steady thread as wide as the opening, with fine grains moving down it.
    val landing = bottomYAt(0.0).coerceAtMost(bottomY)
    val opening = 2.2 * neckScale * (1 + 0.02 * (sin(time * 17.3) + 0.5 * sin(time * 29.7 + 1.1)))
    val coreTop = NECK_Y + Physics.funnelLength(neckScale) - 0.5
    val loose = mix(sand, Color.White, 0.06f)
    val wobble = sin(time * 23) * 0.1
    val drop = max(1.0, landing - NECK_Y)
    for (k in 0 until 24) {
        val y0 = coreTop + (landing - coreTop) * k / 24
        val y1 = coreTop + (landing - coreTop) * (k + 1) / 24
        val f = ((y0 + y1) / 2 - NECK_Y) / drop
        val width = opening * (1 - 0.1 * f)
        drawRect(loose.copy(alpha = (0.95 - 0.1 * f).toFloat()),
            Offset((CX - width / 2 + wobble).toFloat(), y0.toFloat()), Size(width.toFloat(), (y1 - y0 + 0.3).toFloat()))
    }
    val length = landing - (NECK_Y - 3)
    for (i in 0 until max(1, (length / 6 * neckScale).toInt())) {
        val speed = 170 + hash(i, 5) * 60
        val y = NECK_Y - 3 + ((time * speed + hash(i, 6) * length) % length)
        if (y < coreTop || y > landing) continue
        val f = (y - NECK_Y) / drop
        val stray = (hash(i, 20) * 2 - 1) * opening * (0.1 + 0.15 * f) / 2
        val size = (0.9 + 0.3 * hash(i, 21)).toFloat()
        val color = if (i % 2 == 0) mix(sand, Color.White, 0.25f).copy(alpha = 0.7f) else mix(sand, Color.Black, 0.15f).copy(alpha = 0.6f)
        drawRect(color, Offset((CX + stray + wobble).toFloat() - size / 2, y.toFloat() - size / 2), Size(size, size))
    }
    // A few grains trickling down the pile's slopes from where the stream lands.
    if (Geo.sandVolume * p > 1) {
        for (i in 0 until 8) {
            val period = 1.2 + hash(i, 7) * 1.2
            val u = ((time + hash(i, 8) * period) / period).let { it - floor(it) }
            val side = if (hash(i, 9) < 0.5) -1 else 1
            val offset = side * pile.foot * (0.3 + 0.5 * hash(i, 10)) * u * u
            drawRect(mix(sand, Color.Black, 0.15f).copy(alpha = 0.7f),
                Offset((CX + offset - 0.6).toFloat(), (bottomYAt(offset) - 1.2).toFloat()), Size(1.2f, 1.2f))
        }
    }
}

// The caps and their print: black plastic, as the Mac's black base.

private val Cap = Color(22 / 255f, 22 / 255f, 24 / 255f)
private val CapDark = mix(Cap, Color.Black, 0.35f)
private val CapLit = mix(Cap, Color.White, 0.22f)
private val glint = listOf(Color.White.copy(alpha = 0f), Color.White, Color.White.copy(alpha = 0f))

private fun DrawScope.drawCap(top: Boolean) {
    val band = Rect(19f, if (top) 18f else 354f, 181f, if (top) 46f else 382f)
    val disc = Rect(7f, if (top) 0f else 377f, 193f, if (top) 23f else 400f)

    drawRoundRect(Brush.horizontalGradient(0f to CapDark, 0.22f to CapLit, 0.6f to Cap, 1f to CapDark, startX = band.left, endX = band.right),
        band.topLeft, band.size, CornerRadius(3f))
    drawRect(Color.White.copy(alpha = 0.12f), Offset(band.left + 2, if (top) band.bottom - 1.5f else band.top + 0.5f), Size(band.width - 4, 1f))

    drawRoundRect(Brush.horizontalGradient(0f to CapDark, 0.2f to CapLit, 0.55f to Cap, 1f to CapDark, startX = disc.left, endX = disc.right),
        disc.topLeft, disc.size, CornerRadius(6f))
    val sheen = Rect(disc.left + 3, disc.top + 1, disc.right - 3, disc.bottom - 1)
    drawRoundRect(Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.16f), Color.White.copy(alpha = 0f)), startY = sheen.top, endY = sheen.bottom),
        sheen.topLeft, sheen.size, CornerRadius(5f))

    // Glossy plastic: a reflection streak across each part, and a bevel catching the light along the top edge.
    fun streak(rect: Rect, alpha: Float, radius: Float = 0f) = drawRoundRect(
        Brush.horizontalGradient(glint, startX = rect.left, endX = rect.right), rect.topLeft, rect.size, CornerRadius(radius), alpha = alpha,
    )
    streak(Rect(disc.left + 10, disc.top + disc.height * 0.3f, disc.right - 10, disc.top + disc.height * 0.3f + 3.5f), 0.3f, 1.75f)
    streak(Rect(band.left + 8, band.top + band.height * 0.35f, band.right - 8, band.top + band.height * 0.35f + 3f), 0.14f)
    streak(Rect(disc.left + 5, disc.top + 0.6f, disc.right - 5, disc.top + 1.5f), 0.3f)

    drawRect(Color.Black.copy(alpha = 0.35f), Offset(band.left, if (top) disc.bottom else disc.top - 1), Size(band.width, 1f))
}

private val printPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
    textSize = 16f
}

/**
 * Words printed on one of the rings as the Mac prints the time: wrapped round the cylinder (each letter pushed in
 * and narrowed by how far round it sits), pressed into the plastic, and shaded like the ring.
 */
private fun DrawScope.printOnRing(text: String, ring: Rect, clip: Rect, centerY: Float, alpha: Float) {
    val radius = ring.width / 2
    val room = ring.width - 24
    var size = 16f
    printPaint.textSize = size
    while (printPaint.measureText(text) > room && size > 11f) {
        size -= 0.5f
        printPaint.textSize = size
    }
    var shown = text
    while (printPaint.measureText(shown) > room && shown.length > 2) shown = shown.dropLast(2) + "…"
    val width = printPaint.measureText(shown)
    val baseline = centerY - printPaint.fontMetrics.ascent * 0.35f
    val ink = Color(0.84f, 0.84f, 0.84f)

    clipRect(clip.left, clip.top, clip.right, clip.bottom) {
        val canvas = drawContext.canvas.nativeCanvas
        fun pass(dy: Float, shader: Shader?, color: Int) {
            printPaint.shader = shader
            printPaint.color = color
            var x = 0f
            for (ch in shown) {
                val s = ch.toString()
                val advance = printPaint.measureText(s)
                val around = (x + advance / 2 - width / 2) / radius
                canvas.save()
                canvas.translate((CX + radius * sin(around)).toFloat(), baseline + dy)
                canvas.scale(cos(around), 1f)
                canvas.drawText(s, -advance / 2, 0f, printPaint)
                canvas.restore()
                x += advance
            }
            printPaint.shader = null
        }
        // Pressed into the plastic: light catches the lower lip, the upper edge falls into shadow.
        pass(0.6f, null, Color.White.copy(alpha = 0.16f * alpha).toArgb())
        pass(-0.5f, null, Color.Black.copy(alpha = 0.5f * alpha).toArgb())
        // The ink, shaded like the ring: darker toward its ends, brightest where it catches the light.
        val stops = intArrayOf(
            mix(ink, Color.Black, 0.5f).toArgb(), mix(ink, Color.White, 0.2f).toArgb(), ink.toArgb(), mix(ink, Color.Black, 0.55f).toArgb(),
        )
        val shader = LinearGradient(-radius, 0f, radius, 0f, stops, floatArrayOf(0f, 0.24f, 0.6f, 1f), Shader.TileMode.CLAMP)
        pass(0f, shader, Color.White.copy(alpha = alpha).toArgb())
    }
}

/** The day's progress against its target: a groove let into the front of the base plate, filling with sand. */
private fun DrawScope.drawGoal(goal: Double, sand: Color) {
    val left = 17f
    val right = 183f
    val y = 391.6f
    val width = 4.4f
    drawLine(Color.White.copy(alpha = 0.16f), Offset(left, y + 0.9f), Offset(right, y + 0.9f), width, StrokeCap.Round)
    drawLine(Color.Black.copy(alpha = 0.6f), Offset(left, y), Offset(right, y), width, StrokeCap.Round)
    drawLine(Color.Black.copy(alpha = 0.35f), Offset(left, y - 1.3f), Offset(right, y - 1.3f), 0.9f, StrokeCap.Round)
    val done = goal.coerceIn(0.0, 1.0).toFloat()
    // Once the target is met the sand warms a little.
    val fill = if (goal >= 1) mix(sand, Color(1f, 0.82f, 0.4f), 0.3f) else sand
    if (done > 0) {
        val end = left + (right - left) * done
        drawLine(Brush.verticalGradient(
            0f to mix(fill, Color.Black, 0.5f), 0.24f to mix(fill, Color.White, 0.2f), 0.6f to fill, 1f to mix(fill, Color.Black, 0.55f),
            startY = y - 2.2f, endY = y + 2.2f,
        ), Offset(left, y), Offset(end, y), width - 0.4f, StrokeCap.Round)
        drawLine(Color.White.copy(alpha = 0.38f), Offset(left, y - 1.1f), Offset(end, y - 1.1f), 0.7f, StrokeCap.Round)
    }
}

/** "#RRGGBB" as a colour, or the Mac's purple sand. */
fun sandColor(hex: String?): Color = runCatching {
    Color(android.graphics.Color.parseColor(hex ?: "#6C2ED6"))
}.getOrDefault(Color(0xFF6C2ED6))
