import CoreText
import UIKit

/// What the caps show: the time on the base's ring, the project on the top's, and the day's target along the plate.
struct GlassDisplay: Equatable {
    var time: String
    var project: String?
    var goal: Double?
}

/// The Mac's timer (Sources/HourglassRenderer.swift), drawn with UIKit: the same 200 × 400 unit space, y down, the
/// neck at (100, 200), the same glass, sand, caps and print. The sand's shapes come from the Mac's own
/// `SandPhysics` and `HourglassGeometry`, which this app shares.
final class GlassRenderer {
    private typealias G = HourglassGeometry
    private typealias P = SandPhysics
    private let geo = SandPhysics.geometry
    private let cx = CGFloat(SandPhysics.centerX)
    private let neckY = CGFloat(SandPhysics.neckY)
    private var bottomY: CGFloat { neckY + CGFloat(G.halfLength) }
    private var neckScale: CGFloat = 1
    private lazy var outerPath = glassPath(inner: false)
    private lazy var innerPath = glassPath(inner: true)
    /// Grains of several tones and sizes, the way real sand is never one colour: 0 deep, 1 dark, 2 light, 3 glint.
    private let speckles: [(rect: CGRect, tone: Int)]

    private static let cap = UIColor(red: 22 / 255, green: 22 / 255, blue: 24 / 255, alpha: 1)
    private static let ink = UIColor(white: 0.84, alpha: 1)

    init() {
        var seed: UInt64 = 7
        func random() -> CGFloat {
            seed &+= 0x9E37_79B9_7F4A_7C15
            var z = seed
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return CGFloat((z ^ (z >> 31)) >> 11) / CGFloat(1 << 53)
        }
        // Seen through a round glass, grains crowd toward the walls: spread them with a cylindrical-lens mapping.
        let lens: CGFloat = 54
        let center = CGFloat(SandPhysics.centerX)
        speckles = (0..<2400).map { _ in
            let u = max(-1, min(1, (random() * 112 - 56) / lens))
            let x = center + lens * sin(.pi / 2 * u)
            let pick = random()
            let tone = pick < 0.03 ? 3 : pick < 0.33 ? 0 : pick < 0.6 ? 1 : 2
            let size = tone == 3 ? 0.8 : 0.9 + random() * 0.8
            return (CGRect(x: x, y: 44 + random() * 312, width: size, height: size), tone)
        }
    }

    /// Draws the timer into `rect`, fitted whether it stands, lies on its side, or is anywhere between.
    /// `progress` is how much sand has fallen; `angle` (radians) turns the glass, π/2 lying it down as a pause does.
    func draw(in rect: CGRect, progress: Double, angle: Double, running: Bool, sand: UIColor, minutes: Int,
              display: GlassDisplay, time: Double) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let scale = CGFloat(P.neckScale(minutes: Double(minutes)))
        if scale != neckScale {
            neckScale = scale
            outerPath = glassPath(inner: false)
            innerPath = glassPath(inner: true)
        }
        let lying = CGFloat(abs(sin(angle)))
        let standing = min(rect.width / 212, rect.height / 412)
        let onSide = min(rect.width / 412, rect.height / 212)
        let unit = standing + (onSide - standing) * lying
        // The shadow on the ground stays upright whatever the glass does.
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.scaleBy(x: unit, y: unit)
        ctx.translateBy(x: -cx, y: -neckY)
        drawShadow(lying: lying, sand: sand)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.rotate(by: CGFloat(angle))
        ctx.scaleBy(x: unit, y: unit)
        ctx.translateBy(x: -cx, y: -neckY)

        drawGlassBody()
        ctx.saveGState()
        innerPath.addClip()
        if abs(angle) < 0.01 {
            drawRestingSand(progress: progress, running: running, sand: sand, time: time)
        } else {
            let settled = P.settledSand(
                gravityAngle: angle,
                upperArea: P.flatSandArea(upper: true, surfaceDistance: geo.topSandHeight(progress: progress)),
                lowerArea: P.flatSandArea(upper: false, surfaceDistance: geo.bottomSurfaceDistance(progress: progress)))
            for outline in [settled.upper, settled.lower] where outline.count > 2 {
                let path = UIBezierPath()
                path.move(to: CGPoint(x: outline[0].x, y: outline[0].y))
                outline.dropFirst().forEach { path.addLine(to: CGPoint(x: $0.x, y: $0.y)) }
                path.close()
                fillSand(path, sand: sand)
            }
        }
        ctx.restoreGState()
        drawGlassFront()
        drawCap(top: true)
        drawCap(top: false)
        drawCaustic(sand: sand)
        printOnRing(display.time, ring: CGRect(x: 19, y: 354, width: 162, height: 28),
                    clip: CGRect(x: 19, y: 354, width: 162, height: 23), centerY: 365.5, alpha: 1)
        // The project is a mark moulded into the top ring rather than a second display, so the eye goes to the time.
        if let project = display.project {
            printOnRing(project, ring: CGRect(x: 19, y: 18, width: 162, height: 28),
                        clip: CGRect(x: 19, y: 23, width: 162, height: 23), centerY: 34.5, alpha: 0.42)
        }
        if let goal = display.goal { drawGoal(goal, sand: sand) }
        ctx.restoreGState()
    }

    // MARK: Glass

    private func glassPath(inner: Bool) -> UIBezierPath {
        var right: [CGPoint] = []
        for i in 0...180 {
            let y = 20 + CGFloat(i) * 2
            let d = min(Double(abs(y - neckY)), G.halfLength)
            let r = inner ? G.innerRadius(d, neckScale: Double(neckScale)) : G.outerRadius(d, neckScale: Double(neckScale))
            right.append(CGPoint(x: cx + CGFloat(r), y: y))
        }
        let path = UIBezierPath()
        path.move(to: right[0])
        right.dropFirst().forEach { path.addLine(to: $0) }
        right.reversed().forEach { path.addLine(to: CGPoint(x: 2 * cx - $0.x, y: $0.y)) }
        path.close()
        return path
    }

    private func drawGlassBody() {
        fill(outerPath, [(UIColor(white: 0.72, alpha: 0.42), 0), (UIColor(white: 1, alpha: 0.16), 0.2),
                         (UIColor(white: 1, alpha: 0.10), 0.65), (UIColor(white: 0.72, alpha: 0.38), 1)])
    }

    private func drawGlassFront() {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        innerPath.addClip()
        // Thick curved glass bends what's behind it: near the walls everything is seen through more glass, and darker.
        UIColor(white: 0, alpha: 0.1).setStroke()
        innerPath.lineWidth = 14
        innerPath.stroke()
        UIColor(white: 0, alpha: 0.08).setStroke()
        innerPath.lineWidth = 6
        innerPath.stroke()
        drawHighlights()
        drawWindowReflection()
        ctx.restoreGState()

        // The thickness of the glass wall, slightly darker where you look through more glass.
        let wall = UIBezierPath()
        wall.append(outerPath)
        wall.append(innerPath)
        wall.usesEvenOddFillRule = true
        UIColor(white: 0.45, alpha: 0.16).setFill()
        wall.fill()

        // A bright rim just inside the silhouette, where the curved glass catches the light.
        ctx.saveGState()
        outerPath.addClip()
        UIColor(white: 1, alpha: 0.35).setStroke()
        outerPath.lineWidth = 3
        outerPath.stroke()
        ctx.restoreGState()

        UIColor(white: 0.2, alpha: 0.45).setStroke()
        outerPath.lineWidth = 1.2
        outerPath.stroke()
        UIColor(white: 1, alpha: 0.55).setStroke()
        innerPath.lineWidth = 0.8
        innerPath.stroke()
    }

    /// A soft oval glow, brightest in the middle, as reflections and pools of light are.
    private func glow(in oval: CGRect, _ stops: [(UIColor, CGFloat)]) {
        guard let ctx = UIGraphicsGetCurrentContext(),
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map(\.0.cgColor) as CFArray,
                                        locations: stops.map(\.1)) else { return }
        ctx.saveGState()
        ctx.translateBy(x: oval.midX, y: oval.midY)
        ctx.scaleBy(x: 1, y: oval.height / oval.width)
        ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: oval.width / 2, options: [])
        ctx.restoreGState()
    }

    /// A window behind the viewer, reflected in the front of each bulb: two soft glows, upper left.
    private func drawWindowReflection() {
        for top in [true, false] {
            let y = top ? neckY - 132 : neckY + 40
            for x in [cx - 39, cx - 27] {
                glow(in: CGRect(x: x, y: y, width: 10, height: 44),
                     [(UIColor(white: 1, alpha: 0.16), 0), (UIColor(white: 1, alpha: 0.07), 0.55), (UIColor(white: 1, alpha: 0), 1)])
            }
        }
    }

    /// Light gathered by the glass and the sand onto the base beneath: a soft bright spot, tinted by the sand.
    private func drawCaustic(sand: UIColor) {
        let tint = sand.mixed(0.55, .white)
        glow(in: CGRect(x: cx - 34, y: bottomY - 1.5, width: 76, height: 6),
             [(tint.withAlphaComponent(0.4), 0), (tint.withAlphaComponent(0.12), 0.6), (tint.withAlphaComponent(0), 1)])
    }

    /// The timer's shadow on the ground: a soft pool, darker where it touches, and beside it light that passed through
    /// the sand, faintly coloured by it. `lying` is 0 standing, 1 on its side.
    private func drawShadow(lying: CGFloat, sand: UIColor) {
        let ground = neckY + 200 * (1 - lying) + 95 * lying
        func pool(_ x: CGFloat, _ width: CGFloat, _ height: CGFloat, _ color: UIColor, _ alpha: CGFloat) {
            guard alpha > 0.005 else { return }
            glow(in: CGRect(x: x - width / 2, y: ground - height / 2, width: width, height: height),
                 [(color.withAlphaComponent(alpha), 0), (color.withAlphaComponent(alpha * 0.55), 0.35),
                  (color.withAlphaComponent(alpha * 0.18), 0.7), (color.withAlphaComponent(0), 1)])
        }
        let length = 186 + (400 - 186) * lying
        pool(cx, length + 70, 26, .black, 0.35)
        pool(cx, 175, 10, .black, 0.5 * max(0, 1 - 2 * lying))
        pool(cx + 70, 110, 12, sand.mixed(0.3, .white), 0.16 * (1 - lying))
    }

    /// Soft reflections that follow the curve of each bulb.
    private func drawHighlights() {
        for sign in [-1.0, 1.0] {
            for (offset, width, alpha) in [(-0.74, 4.5, 0.55), (0.8, 2.2, 0.28)] {
                var previous: CGPoint?
                for i in 0...40 {
                    let s = Double(i) / 40
                    let d = 10 + s * (G.halfLength - 18)
                    let point = CGPoint(x: cx + CGFloat(G.innerRadius(d) * offset), y: neckY + CGFloat(sign * d))
                    if let previous {
                        let segment = UIBezierPath()
                        segment.move(to: previous)
                        segment.addLine(to: point)
                        segment.lineWidth = width
                        segment.lineCapStyle = .round
                        UIColor(white: 1, alpha: alpha * sin(.pi * s)).setStroke()
                        segment.stroke()
                    }
                    previous = point
                }
            }
        }
    }

    // MARK: Sand

    private struct Surface {
        let y: (CGFloat) -> CGFloat
        let slideFrom: CGFloat
        let slideTo: CGFloat
        let halfWidth: CGFloat
    }

    private func drawRestingSand(progress: Double, running: Bool, sand: UIColor, time: Double) {
        // The top drains as a funnel crater into sand that was flat at the flip; the bottom piles up as a cone.
        let flat = geo.topSandHeight(progress: progress)
        let crater = P.topCrater(progress: progress, settledProgress: 0)
        let top: Surface? = flat > 0.3 ? Surface(
            y: { [neckY] offset in neckY - CGFloat(crater.naturalHeight(atOffset: Double(offset))) },
            slideFrom: CGFloat(crater.rim), slideTo: CGFloat(max(0, -crater.tip / P.reposeSlope)),
            halfWidth: CGFloat(G.innerRadius(flat))) : nil
        let pile = P.bottomPile(progress: progress, settledProgress: 0)
        let bottom: Surface? = geo.sandVolume * progress > 1 ? Surface(
            y: { [bottomY] offset in bottomY - CGFloat(pile.naturalHeight(atOffset: Double(offset))) },
            slideFrom: 0, slideTo: CGFloat(pile.foot), halfWidth: CGFloat(pile.foot)) : nil
        let pouring = running && progress < 1

        if let top {
            let funnel = pouring
                ? (bore: CGFloat(G.innerRadius(0, neckScale: Double(neckScale))) + 0.5, exit: 2.2 * neckScale,
                   length: CGFloat(P.funnelLength(neckScale: Double(neckScale))))
                : nil
            fillSand(region(under: top, closingAt: neckY + 1, lowest: neckY + 1, funnel: funnel), sand: sand)
        }
        if let bottom { fillSand(region(under: bottom, closingAt: bottomY + 8, lowest: bottomY + 1), sand: sand) }
        if pouring { drawFlow(top: top, bottom: bottom, sand: sand, time: time) }
    }

    private func region(under surface: Surface, closingAt closingY: CGFloat, lowest: CGFloat,
                        funnel: (bore: CGFloat, exit: CGFloat, length: CGFloat)? = nil) -> UIBezierPath {
        let half: CGFloat = 60, samples = 120
        let closingY = funnel == nil ? closingY : neckY - 1
        let path = UIBezierPath()
        path.move(to: CGPoint(x: cx - half, y: closingY))
        for i in 0...samples {
            let offset = -half + 2 * half * CGFloat(i) / CGFloat(samples)
            path.addLine(to: CGPoint(x: cx + offset, y: min(lowest, surface.y(offset))))
        }
        path.addLine(to: CGPoint(x: cx + half, y: closingY))
        if let funnel {
            let end = neckY + funnel.length
            path.addLine(to: CGPoint(x: cx + funnel.bore, y: closingY))
            // A short, straight taper: sand runs through the neck rather than bulging out of it like a drip.
            path.addLine(to: CGPoint(x: cx + funnel.exit / 2, y: end))
            path.addLine(to: CGPoint(x: cx - funnel.exit / 2, y: end))
            path.addLine(to: CGPoint(x: cx - funnel.bore, y: closingY))
        }
        path.close()
        return path
    }

    private func fillSand(_ path: UIBezierPath, sand: UIColor) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let edge = sand.mixed(0.45, .black), lit = sand.mixed(0.14, .white)
        fill(path, [(edge, 0), (sand, 0.22), (lit, 0.45), (sand, 0.78), (edge, 1)])
        ctx.saveGState()
        path.addClip()
        let bounds = path.bounds
        let visible = speckles.filter { bounds.intersects($0.rect) }
        let tones = [sand.mixed(0.5, .black).withAlphaComponent(0.55), sand.mixed(0.25, .black).withAlphaComponent(0.45),
                     sand.mixed(0.4, .white).withAlphaComponent(0.55), UIColor(white: 1, alpha: 0.75)]
        for (tone, color) in tones.enumerated() {
            ctx.setFillColor(color.cgColor)
            ctx.fill(visible.filter { $0.tone == tone }.map(\.rect))
        }
        // Lit from above: the top of each heap catches the light.
        gradient([(UIColor(white: 1, alpha: 0.16), 0), (UIColor(white: 1, alpha: 0), 1)],
                 in: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 12), vertical: true, clipToRect: true)
        // Where the sand presses against the glass it's in shade: a darker band along the wall.
        edge.withAlphaComponent(0.4).setStroke()
        innerPath.lineWidth = 7
        innerPath.stroke()
        ctx.restoreGState()
    }

    private static func hash(_ i: Int, _ k: Int) -> Double {
        let v = sin(Double(i) * 12.9898 + Double(k) * 78.233) * 43758.5453
        return v - v.rounded(.down)
    }

    /// Grains sliding into the crater, the stream through the neck, and grains tumbling down the pile: positions are
    /// pure functions of time, so there is no particle state.
    private func drawFlow(top: Surface?, bottom: Surface?, sand: UIColor, time: Double) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        var light: [CGRect] = [], dark: [CGRect] = []
        let landing = bottom?.y(0) ?? bottomY

        if let top, top.slideFrom - top.slideTo > 2 {
            for i in 0..<16 {
                let period = 1.4 + Self.hash(i, 1) * 1.6
                let u = CGFloat(((time + Self.hash(i, 2) * period) / period).truncatingRemainder(dividingBy: 1))
                let side: CGFloat = Self.hash(i, 3) < 0.5 ? -1 : 1
                let start = top.slideTo + (top.slideFrom - top.slideTo) * CGFloat(0.3 + 0.7 * Self.hash(i, 4))
                let offset = side * (top.slideTo + (start - top.slideTo) * (1 - u * u))
                let rect = CGRect(x: cx + offset - 0.8, y: top.y(offset) - 1.4, width: 1.6, height: 1.6)
                if i % 3 == 0 { light.append(rect) } else { dark.append(rect) }
            }
            ctx.setFillColor(sand.mixed(0.3, .black).cgColor)
            ctx.fill(dark)
            ctx.setFillColor(sand.mixed(0.45, .white).cgColor)
            ctx.fill(light)
        }

        // The stream: a thin, smooth, steady thread as wide as the opening, with fine grain texture moving down it.
        let shimmer = 1 + 0.02 * CGFloat(sin(time * 17.3) + 0.5 * sin(time * 29.7 + 1.1))
        let opening = 2.2 * neckScale * shimmer
        let coreTop = top == nil ? neckY - 3 : neckY + CGFloat(P.funnelLength(neckScale: Double(neckScale))) - 0.5
        let wobble = CGFloat(sin(time * 23) * 0.1)
        let loose = sand.mixed(0.06, .white)
        let drop = max(1, landing - neckY)
        func fraction(_ y: CGFloat) -> Double { Double((y - neckY) / drop) }
        for k in 0..<24 {
            let y0 = coreTop + (landing - coreTop) * CGFloat(k) / 24
            let y1 = coreTop + (landing - coreTop) * CGFloat(k + 1) / 24
            let slice = P.streamSlice(at: fraction((y0 + y1) / 2))
            let width = opening * CGFloat(slice.coreWidth)
            ctx.setFillColor(loose.withAlphaComponent(CGFloat(slice.coreOpacity)).cgColor)
            ctx.fill(CGRect(x: cx - width / 2 + wobble, y: y0, width: width, height: y1 - y0 + 0.3))
        }
        let length = Double(landing - (neckY - 3))
        var lighter: [CGRect] = [], darker: [CGRect] = []
        for i in 0..<max(1, Int(length / 6 * Double(neckScale))) {
            let speed = 170 + Self.hash(i, 5) * 60
            let y = neckY - 3 + CGFloat((time * speed + Self.hash(i, 6) * length).truncatingRemainder(dividingBy: length))
            guard y >= coreTop && y <= landing else { continue }
            let stray = CGFloat(Self.hash(i, 20) * 2 - 1) * opening * CGFloat(P.streamSlice(at: fraction(y)).spread) / 2
            let size = CGFloat(0.9 + 0.3 * Self.hash(i, 21))
            let rect = CGRect(x: cx + stray + wobble - size / 2, y: y - size / 2, width: size, height: size)
            if i % 2 == 0 { lighter.append(rect) } else { darker.append(rect) }
        }
        ctx.setFillColor(sand.mixed(0.25, .white).withAlphaComponent(0.7).cgColor)
        ctx.fill(lighter)
        ctx.setFillColor(sand.mixed(0.15, .black).withAlphaComponent(0.6).cgColor)
        ctx.fill(darker)

        // A few grains trickling down the pile's slopes from where the stream lands.
        if let bottom {
            var rolling: [CGRect] = []
            for i in 0..<8 {
                let period = 1.2 + Self.hash(i, 7) * 1.2
                let u = CGFloat(((time + Self.hash(i, 8) * period) / period).truncatingRemainder(dividingBy: 1))
                let side: CGFloat = Self.hash(i, 9) < 0.5 ? -1 : 1
                let offset = side * bottom.slideTo * CGFloat(0.3 + 0.5 * Self.hash(i, 10)) * u * u
                rolling.append(CGRect(x: cx + offset - 0.6, y: bottom.y(offset) - 1.2, width: 1.2, height: 1.2))
            }
            ctx.setFillColor(sand.mixed(0.15, .black).withAlphaComponent(0.7).cgColor)
            ctx.fill(rolling)
        }
    }

    // MARK: Caps and print

    private func drawCap(top: Bool) {
        let base = Self.cap
        let dark = base.mixed(0.35, .black), lit = base.mixed(0.22, .white)
        let band = CGRect(x: 19, y: top ? 18 : 354, width: 162, height: 28)
        let disc = CGRect(x: 7, y: top ? 0 : 377, width: 186, height: 23)
        let glint: [(UIColor, CGFloat)] = [(UIColor(white: 1, alpha: 0), 0), (.white, 0.5), (UIColor(white: 1, alpha: 0), 1)]

        fill(UIBezierPath(roundedRect: band, cornerRadius: 3), [(dark, 0), (lit, 0.22), (base, 0.6), (dark, 1)])
        UIColor(white: 1, alpha: 0.12).setFill()
        UIBezierPath(rect: CGRect(x: band.minX + 2, y: top ? band.maxY - 1.5 : band.minY + 0.5, width: band.width - 4, height: 1)).fill()

        fill(UIBezierPath(roundedRect: disc, cornerRadius: 6), [(dark, 0), (lit, 0.2), (base, 0.55), (dark, 1)])
        fill(UIBezierPath(roundedRect: disc.insetBy(dx: 3, dy: 1), cornerRadius: 5),
             [(UIColor(white: 1, alpha: 0.16), 0), (UIColor(white: 1, alpha: 0), 1)], vertical: true)

        // Glossy plastic: a horizontal reflection streak and a thin bevel catching light along the top edge.
        fill(UIBezierPath(roundedRect: CGRect(x: disc.minX + 10, y: disc.minY + disc.height * 0.3, width: disc.width - 20, height: 3.5),
                          cornerRadius: 1.75), glint, alpha: 0.3)
        fill(UIBezierPath(rect: CGRect(x: band.minX + 8, y: band.minY + band.height * 0.35, width: band.width - 16, height: 3)), glint, alpha: 0.14)
        fill(UIBezierPath(rect: CGRect(x: disc.minX + 5, y: disc.minY + 0.6, width: disc.width - 10, height: 0.9)), glint, alpha: 0.3)

        UIColor(white: 0, alpha: 0.35).setFill()
        UIBezierPath(rect: CGRect(x: band.minX, y: top ? disc.maxY : disc.minY - 1, width: band.width, height: 1)).fill()
    }

    /// Letters printed on one of the rings, made to read as part of the plastic: wrapped round the cylinder, pressed
    /// slightly in, the ink shaded like the ring.
    private func printOnRing(_ text: String, ring: CGRect, clip: CGRect, centerY: CGFloat, alpha: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let (shown, size) = fitted(text, room: ring.width - 24)
        let glyphs = wrappedLabelPath(shown, ringCenterY: centerY, ringRadius: ring.width / 2, size: size)
        ctx.saveGState()
        ctx.clip(to: clip)
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        func fill(offsetY: CGFloat, _ color: UIColor) {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: offsetY)
            ctx.addPath(glyphs)
            ctx.setFillColor(color.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        fill(offsetY: 0.6, UIColor(white: 1, alpha: 0.16))
        fill(offsetY: -0.5, UIColor(white: 0, alpha: 0.5))
        ctx.saveGState()
        ctx.addPath(glyphs)
        ctx.clip()
        let ink = Self.ink
        gradient([(ink.mixed(0.5, .black), 0), (ink.mixed(0.2, .white), 0.24), (ink, 0.6), (ink.mixed(0.55, .black), 1)], in: ring)
        ctx.setAlpha(0.35)
        gradient([(UIColor(white: 1, alpha: 0), 0), (.white, 0.5), (UIColor(white: 1, alpha: 0), 1)],
                 in: CGRect(x: ring.minX + 8, y: ring.minY + ring.height * 0.35, width: ring.width - 16, height: 3), clipToRect: true)
        ctx.restoreGState()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private func fitted(_ string: String, room: CGFloat, largest: CGFloat = 16, smallest: CGFloat = 11) -> (String, CGFloat) {
        func width(_ string: String, _ size: CGFloat) -> CGFloat {
            let font = UIFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
            return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font])), nil, nil, nil))
        }
        var text = string
        let size = min(largest, max(smallest, largest * room / max(1, width(text, largest))))
        while width(text, size) > room && text.count > 2 { text = String(text.dropLast(2)) + "…" }
        return (text, size)
    }

    /// Outlines of the label's glyphs, centred on the ring and wrapped around it: each character pushed toward the
    /// middle and narrowed by how far round the cylinder it sits, as seen from the front.
    private func wrappedLabelPath(_ text: String, ringCenterY: CGFloat, ringRadius: CGFloat, size: CGFloat) -> CGPath {
        let font = UIFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let baseline = ringCenterY + font.capHeight / 2
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName as String] as! CTFont  // CoreText always sets the run's font
            for i in 0..<count {
                var glyph = glyphs[i]
                guard let outline = CTFontCreatePathForGlyph(runFont, glyph, nil) else { continue }
                let advance = CGFloat(CTFontGetAdvancesForGlyphs(runFont, .horizontal, &glyph, nil, 1))
                let around = (positions[i].x + advance / 2 - width / 2) / ringRadius
                let transform = CGAffineTransform(translationX: cx + ringRadius * sin(around), y: baseline)
                    .scaledBy(x: cos(around), y: -1)
                    .translatedBy(x: -advance / 2, y: 0)
                path.addPath(outline, transform: transform)
            }
        }
        return path
    }

    /// The day's progress against its target: a groove let into the front of the base plate, filling with sand.
    private func drawGoal(_ goal: Double, sand: UIColor) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let left: CGFloat = 17, right: CGFloat = 183, y: CGFloat = 391.6, width: CGFloat = 4.4
        func stroke(from: CGFloat, to: CGFloat, drop: CGFloat = 0, width: CGFloat, _ color: UIColor) {
            ctx.move(to: CGPoint(x: from, y: y + drop))
            ctx.addLine(to: CGPoint(x: to, y: y + drop))
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.setStrokeColor(color.cgColor)
            ctx.strokePath()
        }
        stroke(from: left, to: right, drop: 0.9, width: width, UIColor(white: 1, alpha: 0.16))
        stroke(from: left, to: right, width: width, UIColor(white: 0, alpha: 0.6))
        stroke(from: left, to: right, drop: -1.3, width: 0.9, UIColor(white: 0, alpha: 0.35))
        let done = CGFloat(min(1, max(0, goal)))
        guard done > 0 else { return }
        // Once the day's target is met the sand warms a little.
        let fillColor = goal >= 1 ? sand.mixed(0.3, UIColor(red: 1, green: 0.82, blue: 0.4, alpha: 1)) : sand
        let end = left + (right - left) * done
        ctx.saveGState()
        ctx.move(to: CGPoint(x: left, y: y))
        ctx.addLine(to: CGPoint(x: end, y: y))
        ctx.setLineWidth(width - 0.4)
        ctx.setLineCap(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        gradient([(fillColor.mixed(0.5, .black), 0), (fillColor.mixed(0.2, .white), 0.24), (fillColor, 0.6), (fillColor.mixed(0.55, .black), 1)],
                 in: CGRect(x: left - 2, y: y - 2.2, width: right - left + 4, height: 4.4), vertical: true)
        ctx.restoreGState()
        stroke(from: left, to: end, drop: -1.1, width: 0.7, UIColor(white: 1, alpha: 0.38))
    }

    // MARK: Gradients

    /// A path filled with a gradient running across it (or down it), as `NSGradient.draw(in:angle:)` does on the Mac.
    private func fill(_ path: UIBezierPath, _ stops: [(UIColor, CGFloat)], vertical: Bool = false, alpha: CGFloat = 1) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        path.addClip()
        gradient(stops, in: path.bounds, vertical: vertical)
        ctx.restoreGState()
    }

    private func gradient(_ stops: [(UIColor, CGFloat)], in rect: CGRect, vertical: Bool = false, clipToRect: Bool = false) {
        guard let ctx = UIGraphicsGetCurrentContext(),
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map(\.0.cgColor) as CFArray,
                                        locations: stops.map(\.1)) else { return }
        ctx.saveGState()
        if clipToRect { ctx.clip(to: rect) }
        let start = vertical ? CGPoint(x: rect.midX, y: rect.minY) : CGPoint(x: rect.minX, y: rect.midY)
        let end = vertical ? CGPoint(x: rect.midX, y: rect.maxY) : CGPoint(x: rect.maxX, y: rect.midY)
        ctx.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
}

extension UIColor {
    /// This colour `fraction` of the way to `other`, as `NSColor.blended(withFraction:of:)` does.
    func mixed(_ fraction: CGFloat, _ other: UIColor) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * fraction, green: g1 + (g2 - g1) * fraction, blue: b1 + (b2 - b1) * fraction, alpha: a1)
    }

    /// A colour written "#RRGGBB"; nil for anything else.
    convenience init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
