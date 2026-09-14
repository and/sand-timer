import AppKit

/// A sand color on a base (the caps): black like the purple product photo, or matching like the teal one.
struct Theme {
    enum Base: Int, CaseIterable {
        case black, matching
        var name: String { self == .black ? "Black" : "Matching" }
    }

    let name: String
    let sand: NSColor
    let cap: NSColor
    /// Black caps get light print; colored caps get dark print.
    let darkCap: Bool

    /// Color of the time shown on the base: light on dark caps, a deep shade of the cap on light ones.
    var displayInk: NSColor {
        darkCap ? NSColor(white: 0.84, alpha: 1) : (cap.blended(withFraction: 0.72, of: .black) ?? .black)
    }

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    static let colors: [(name: String, sand: NSColor, matchingCap: NSColor)] = [
        ("Purple", rgb(108, 46, 214), rgb(150, 108, 228)),
        ("Teal", rgb(52, 190, 166), rgb(98, 206, 186)),
        ("Pink", rgb(236, 98, 160), rgb(244, 150, 192)),
        ("Blue", rgb(40, 118, 226), rgb(108, 162, 238)),
        ("White", rgb(236, 233, 226), rgb(238, 238, 236)),
        ("Black", rgb(34, 33, 36), rgb(44, 44, 48)),
    ]

    init(color: Int, base: Base) {
        let color = Self.colors[Self.colors.indices.contains(color) ? color : 0]
        name = "\(color.name) on \(base.name)"
        sand = color.sand
        cap = base == .black ? Self.rgb(22, 22, 24) : color.matchingCap
        // Judge by the cap itself: a matching cap can be dark too (black sand).
        let brightness = (cap.usingColorSpace(.sRGB) ?? cap).brightnessComponent
        darkCap = brightness < 0.5
    }
}

/// What the sand is doing in one frame, in the glass's own frame of reference.
struct SandFrame {
    var progress: Double
    /// Progress when each bulb's sand last settled flat: the top's crater and the bottom's new pile grow from there.
    var topSettledProgress: Double = 0
    var bottomSettledProgress: Double = 0
    /// Sand that has actually landed in the lower bulb (less than `progress` while some is still falling).
    var landedProgress: Double?
    /// 0 = sand shaken flat (just after a flip), 1 = crater and pile fully formed.
    var shapeAmount: Double = 1
    /// How stirred up the sand is by shaking or a landing (0 = still, 1 = grains leaping).
    var agitation: Double = 0
    /// Lean of the falling stream from vertical (radians) while the timer is moved sharply.
    var streamTilt: Double = 0
    /// The falling stream as distances below the neck: its tail (where it has let go of the neck) and its front.
    var stream: (tail: Double, front: Double)?
    /// Sand outlines while the glass is turning over; replaces the resting shapes.
    var turning: SandPhysics.SettledSand?
}

/// The time display on the base ring. It faces the user, switches off while the timer is being flipped, and switches
/// on again at the base that ends up at the bottom.
struct BaseDisplay {
    var text: String
    /// 0 = switched off, 1 = fully lit.
    var brightness: Double = 1
    /// Turn of the text against the glass's rotation (radians), so it stays upright on screen while fading.
    var rotation: Double = 0
}

/// Draws the timer in a 200 x 400 unit space (y grows downward, neck at y = 200).
/// The caller sets up the transform; everything here is resolution independent.
final class HourglassRenderer {
    private typealias G = HourglassGeometry
    private typealias P = SandPhysics
    private let geo = SandPhysics.geometry
    private let cx = CGFloat(SandPhysics.centerX)
    private let neckY = CGFloat(SandPhysics.neckY)
    private var bottomY: CGFloat { neckY + CGFloat(G.halfLength) }
    private lazy var outerPath = glassPath(inner: false)
    private lazy var innerPath = glassPath(inner: true)
    /// Width of the neck relative to the reference timer; shorter timers have a wider neck and a thicker stream.
    var neckScale: CGFloat = 1 {
        didSet {
            guard neckScale != oldValue else { return }
            outerPath = glassPath(inner: false)
            innerPath = glassPath(inner: true)
        }
    }
    private let speckles: [(rect: CGRect, light: Bool)]
    /// The glass and caps never change, so they're rendered once per color and pixel scale and reused every frame.
    private var layerCache: [String: (back: CGImage, front: CGImage)] = [:]
    private let layerBounds = CGRect(x: -4, y: -4, width: 208, height: 408)

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
        let center = cx
        speckles = (0..<1100).map { _ in
            let u = max(-1, min(1, (random() * 112 - 56) / lens))
            let x = center + lens * sin(.pi / 2 * u)
            return (CGRect(x: x, y: 44 + random() * 312, width: 1.3, height: 1.3), random() < 0.5)
        }
    }

    /// Shadow on the desk, drawn upright even when the glass is tilted. Fades as the timer is lifted to flip.
    /// `groundOffset` is how far below the center the timer touches the ground, `footprint` how wide it sits on it.
    func drawShadow(opacity: CGFloat, groundOffset: CGFloat = 200, footprint: CGFloat = 200) {
        guard opacity > 0.01 else { return }
        let ground = neckY + groundOffset
        NSGradient(starting: NSColor(white: 0, alpha: 0.26 * opacity), ending: NSColor(white: 0, alpha: 0))?
            .draw(in: NSBezierPath(ovalIn: CGRect(x: cx - footprint / 2 - 4, y: ground - 12, width: footprint + 8, height: 24)),
                  relativeCenterPosition: .zero)
        NSGradient(starting: NSColor(white: 0, alpha: 0.5 * opacity), ending: NSColor(white: 0, alpha: 0))?
            .draw(in: NSBezierPath(ovalIn: CGRect(x: cx - footprint / 2 + 14, y: ground - 5, width: footprint - 28, height: 9)),
                  relativeCenterPosition: .zero)
    }

    func draw(_ frame: SandFrame, time: CFTimeInterval, theme: Theme, display: BaseDisplay) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let device = ctx.userSpaceToDeviceSpaceTransform
        let layers = cachedLayers(theme: theme, pixelScale: hypot(device.a, device.b))
        if let layers { drawLayer(layers.back) } else { drawGlassBody() }

        NSGraphicsContext.saveGraphicsState()
        innerPath.addClip()
        let stir = CGFloat(frame.agitation)
        // Shaken sand jostles in place.
        let jostle = CGSize(width: CGFloat(sin(time * 37)) * stir * 1.2, height: CGFloat(cos(time * 43)) * stir * 1.2)
        if let turning = frame.turning {
            for (index, outline) in [turning.upper, turning.lower].enumerated() where outline.count > 2 {
                let path = NSBezierPath()
                path.move(to: CGPoint(x: outline[0].x, y: outline[0].y))
                outline.dropFirst().forEach { path.line(to: CGPoint(x: $0.x, y: $0.y)) }
                path.close()
                fillSand(path, theme: theme, jostle: jostle)
                if stir > 0 { drawLeapingGrains(off: outline, gravity: turning.gravity, level: stir, seed: index * 100, theme: theme, time: time) }
            }
        } else {
            let top = topSurface(frame)
            let bottom = bottomSurface(frame)
            // Shaken sand ripples as well.
            if let top {
                // Stops at the neck; below it, the stream carries the sand on.
                fillSand(region(under: top, closingAt: neckY + 1, lowest: neckY + 1, ripple: stir, time: time), theme: theme, jostle: jostle)
            }
            if let bottom {
                fillSand(region(under: bottom, closingAt: bottomY + 8, lowest: bottomY + 1, ripple: stir, time: time), theme: theme, jostle: jostle)
            }
            drawFlow(frame, top: top, bottom: bottom, theme: theme, time: time)
            if stir > 0 {
                for (index, surface) in [top, bottom].enumerated() {
                    guard let surface, surface.halfWidth > 2 else { continue }
                    drawLeapingGrains(level: stir, seed: index * 100, theme: theme, time: time) { spread, drift, hop in
                        let offset = spread * surface.halfWidth + drift
                        return CGPoint(x: self.cx + offset, y: surface.y(offset) - hop - 0.8)
                    }
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        if let layers { drawLayer(layers.front) } else { drawGlassFront(theme: theme) }
        drawBaseDisplay(display, theme: theme)
    }

    // MARK: Cached layers

    private func cachedLayers(theme: Theme, pixelScale: CGFloat) -> (back: CGImage, front: CGImage)? {
        let scale = (pixelScale * 4).rounded(.up) / 4
        let key = "\(theme.name)@\(scale)/neck\(neckScale)"
        if let layers = layerCache[key] { return layers }
        guard let back = renderLayer(scale: scale, { drawGlassBody() }),
              let front = renderLayer(scale: scale, { drawGlassFront(theme: theme) }) else { return nil }
        if layerCache.count > 8 { layerCache.removeAll() }
        layerCache[key] = (back, front)
        return (back, front)
    }

    private func renderLayer(scale: CGFloat, _ drawing: () -> Void) -> CGImage? {
        let width = Int((layerBounds.width * scale).rounded(.up)), height = Int((layerBounds.height * scale).rounded(.up))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -layerBounds.minX, y: -layerBounds.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        drawing()
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private func drawLayer(_ image: CGImage) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: layerBounds.minX, y: layerBounds.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: layerBounds.size))
        ctx.restoreGState()
    }

    /// Everything in front of the sand: reflections inside the glass, its outline, and the caps.
    private func drawGlassFront(theme: Theme) {
        NSGraphicsContext.saveGraphicsState()
        innerPath.addClip()
        drawHighlights()
        NSGraphicsContext.restoreGraphicsState()
        strokeGlass()
        drawCap(top: true, theme: theme)
        drawCap(top: false, theme: theme)
    }

    // MARK: Glass

    private func glassPath(inner: Bool) -> NSBezierPath {
        var right: [CGPoint] = []
        for i in 0...180 {
            let y = 20 + CGFloat(i) * 2
            let d = min(Double(abs(y - neckY)), G.halfLength)
            let r = inner ? G.innerRadius(d, neckScale: Double(neckScale)) : G.outerRadius(d, neckScale: Double(neckScale))
            right.append(CGPoint(x: cx + CGFloat(r), y: y))
        }
        let path = NSBezierPath()
        path.move(to: right[0])
        right.dropFirst().forEach { path.line(to: $0) }
        right.reversed().forEach { path.line(to: CGPoint(x: 2 * cx - $0.x, y: $0.y)) }
        path.close()
        return path
    }

    private func drawGlassBody() {
        NSGradient(colorsAndLocations:
            (NSColor(white: 0.72, alpha: 0.42), 0),
            (NSColor(white: 1, alpha: 0.16), 0.2),
            (NSColor(white: 1, alpha: 0.10), 0.65),
            (NSColor(white: 0.72, alpha: 0.38), 1)
        )?.draw(in: outerPath, angle: 0)
    }

    private func strokeGlass() {
        // The thickness of the glass wall, slightly darker where you look through more glass.
        let wall = NSBezierPath()
        wall.append(outerPath)
        wall.append(innerPath)
        wall.windingRule = .evenOdd
        NSColor(white: 0.45, alpha: 0.16).setFill()
        wall.fill()

        // A bright rim just inside the silhouette, where the curved glass catches the light.
        NSGraphicsContext.saveGraphicsState()
        outerPath.addClip()
        NSColor(white: 1, alpha: 0.35).setStroke()
        outerPath.lineWidth = 3
        outerPath.stroke()
        NSGraphicsContext.restoreGraphicsState()

        NSColor(white: 0.2, alpha: 0.45).setStroke()
        outerPath.lineWidth = 1.2
        outerPath.stroke()
        NSColor(white: 1, alpha: 0.55).setStroke()
        innerPath.lineWidth = 0.8
        innerPath.stroke()
    }

    /// Soft reflections that follow the curve of each bulb.
    private func drawHighlights() {
        for sign in [-1.0, 1.0] {
            for (offset, width, alpha) in [(-0.74, 4.5, 0.55), (0.8, 2.2, 0.28)] {
                let segments = 40
                var previous: CGPoint?
                for i in 0...segments {
                    let s = Double(i) / Double(segments)
                    let d = 10 + s * (G.halfLength - 18)
                    let point = CGPoint(x: cx + CGFloat(G.innerRadius(d) * offset), y: neckY + CGFloat(sign * d))
                    if let previous {
                        let segment = NSBezierPath()
                        segment.move(to: previous)
                        segment.line(to: point)
                        segment.lineWidth = width
                        segment.lineCapStyle = .round
                        NSColor(white: 1, alpha: alpha * sin(.pi * s)).setStroke()
                        segment.stroke()
                    }
                    previous = point
                }
            }
        }
    }

    // MARK: Sand

    /// A sand surface: its height across the glass, and the span grains travel along it.
    private struct Surface {
        /// Surface y at a horizontal offset from the center line.
        let y: (CGFloat) -> CGFloat
        /// Offsets from the center where moving grains start and stop (crater: rim to funnel; pile: peak to foot).
        let slideFrom: CGFloat
        let slideTo: CGFloat
        /// How far the sand's surface reaches either side of the center line.
        let halfWidth: CGFloat
    }

    /// Upper bulb: a funnel crater, drawn into sand that was flat when it started flowing.
    private func topSurface(_ frame: SandFrame) -> Surface? {
        let flat = geo.topSandHeight(progress: frame.progress)
        guard flat > 0.3 else { return nil }
        let crater = P.topCrater(progress: frame.progress, settledProgress: frame.topSettledProgress)
        let amount = frame.shapeAmount, neckY = self.neckY
        return Surface(
            y: { offset in
                let height = crater.height(atRadius: Double(abs(offset)))
                return neckY - CGFloat(flat + (height - flat) * amount)
            },
            slideFrom: CGFloat(crater.rim), slideTo: CGFloat(max(0, -crater.tip / P.reposeSlope)), halfWidth: CGFloat(G.innerRadius(flat)))
    }

    /// Lower bulb: new sand piles up as a cone at the angle of repose on whatever flat layer was already there.
    private func bottomSurface(_ frame: SandFrame) -> Surface? {
        let landed = frame.landedProgress ?? frame.progress
        guard geo.sandVolume * landed > 1 else { return nil }
        let flat = G.halfLength - geo.bottomSurfaceDistance(progress: landed)
        let pile = P.bottomPile(progress: landed, settledProgress: frame.bottomSettledProgress)
        let amount = frame.shapeAmount, bottomY = self.bottomY
        let wall = G.innerRadius(G.halfLength - flat)
        return Surface(
            y: { offset in
                let height = pile.height(atRadius: Double(abs(offset)))
                return bottomY - CGFloat(flat + (height - flat) * amount)
            },
            slideFrom: 0, slideTo: CGFloat(pile.foot),
            halfWidth: CGFloat(pile.layer > 0 ? wall : min(wall, pile.foot)))
    }

    /// The area below a surface, closed off at `closingAt`; the glass clip trims it to the bulb.
    private func region(under surface: Surface, closingAt closingY: CGFloat, lowest: CGFloat,
                        ripple: CGFloat, time: CFTimeInterval) -> NSBezierPath {
        let t = CGFloat(time)
        let half: CGFloat = 60, samples = 120
        let path = NSBezierPath()
        path.move(to: CGPoint(x: cx - half, y: closingY))
        for i in 0...samples {
            let offset = -half + 2 * half * CGFloat(i) / CGFloat(samples)
            let wave = ripple == 0 ? 0 : ripple * 1.6 * sin(offset * 0.7 + t * 43) * sin(offset * 0.23 - t * 29)
            path.line(to: CGPoint(x: cx + offset, y: min(lowest, surface.y(offset) + wave)))
        }
        path.line(to: CGPoint(x: cx + half, y: closingY))
        path.close()
        return path
    }

    private func fillSand(_ path: NSBezierPath, theme: Theme, jostle: CGSize = .zero) {
        let base = theme.sand
        let edge = base.blended(withFraction: 0.45, of: .black) ?? base
        let lit = base.blended(withFraction: 0.14, of: .white) ?? base
        NSGradient(colorsAndLocations: (edge, 0), (base, 0.22), (lit, 0.45), (base, 0.78), (edge, 1))?
            .draw(in: path, angle: 0)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let bounds = path.bounds
        let visible = speckles.filter { bounds.intersects($0.rect) }
        ctx.translateBy(x: jostle.width, y: jostle.height)
        ctx.setFillColor((base.blended(withFraction: 0.4, of: .white) ?? base).withAlphaComponent(0.55).cgColor)
        ctx.fill(visible.filter(\.light).map(\.rect))
        ctx.setFillColor((base.blended(withFraction: 0.45, of: .black) ?? base).withAlphaComponent(0.5).cgColor)
        ctx.fill(visible.filter { !$0.light }.map(\.rect))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Stable pseudo-random value in 0..<1 for grain `i` and channel `k`.
    private static func hash(_ i: Int, _ k: Int) -> Double {
        let v = sin(Double(i) * 12.9898 + Double(k) * 78.233) * 43758.5453
        return v - v.rounded(.down)
    }

    /// Everything that moves while sand is falling: grains sliding into the crater, the stream through the neck,
    /// and grains tumbling down the pile. Positions are pure functions of time, so there is no particle state.
    private func drawFlow(_ frame: SandFrame, top: Surface?, bottom: Surface?, theme: Theme, time: CFTimeInterval) {
        guard let stream = frame.stream, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let lightColor = (theme.sand.blended(withFraction: 0.45, of: .white) ?? theme.sand).cgColor
        let darkColor = (theme.sand.blended(withFraction: 0.3, of: .black) ?? theme.sand).cgColor
        var light: [CGRect] = [], dark: [CGRect] = []
        func grain(_ i: Int, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat) {
            let rect = CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size)
            if i % 3 == 0 { light.append(rect) } else { dark.append(rect) }
        }
        func fillGrains() {
            ctx.setFillColor(darkColor); ctx.fill(dark)
            ctx.setFillColor(lightColor); ctx.fill(light)
            light.removeAll(); dark.removeAll()
        }

        // The stream bends from the neck when the timer is moved sharply, landing off-center on the pile.
        let lean = CGFloat(tan(frame.streamTilt))
        func landingY() -> CGFloat {
            guard let bottom else { return bottomY }
            let first = bottom.y(0)
            return bottom.y((first - neckY) * lean)
        }
        let landing = landingY()
        let landingOffset = (landing - neckY) * lean
        let streamTop = neckY - 3 + CGFloat(stream.tail)
        let streamEnd = min(landing, neckY + CGFloat(stream.front))
        let feeding = stream.tail < 1 && top != nil
        let hitsPile = streamEnd >= landing - 0.5 && streamEnd - streamTop > 1

        // Grains creeping down the crater walls toward the neck.
        if feeding, let top, top.slideFrom - top.slideTo > 2 {
            for i in 0..<16 {
                let period = 1.4 + Self.hash(i, 1) * 1.6
                let u = CGFloat(((time + Self.hash(i, 2) * period) / period).truncatingRemainder(dividingBy: 1))
                let side: CGFloat = Self.hash(i, 3) < 0.5 ? -1 : 1
                let start = top.slideTo + (top.slideFrom - top.slideTo) * CGFloat(0.3 + 0.7 * Self.hash(i, 4))
                let offset = side * (top.slideTo + (start - top.slideTo) * (1 - u * u))
                grain(i, cx + offset, top.y(offset) - 0.6, 1.6)
            }
            fillGrains()
        }

        // The stream: a wavering core with grains racing down it. It thins once the top has run dry.
        if streamEnd - streamTop > 1 {
            ctx.saveGState()
            ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: lean, d: 1, tx: -lean * neckY, ty: 0))
            let wobble = CGFloat(sin(time * 23) * 0.25 + sin(time * 31) * frame.agitation * 1.5)
            // As thick as the opening it pours through.
            let width: CGFloat = (stream.tail > 0 ? 1.3 : 2.2) * neckScale
            ctx.setFillColor(theme.sand.withAlphaComponent(0.9).cgColor)
            ctx.fill(CGRect(x: cx - width / 2 + wobble, y: streamTop, width: width, height: streamEnd - streamTop))
            let length = Double(landing - (neckY - 3))
            for i in 0..<max(1, Int(length / 5 * Double(neckScale))) {
                let speed = 170 + Self.hash(i, 5) * 60
                let y = neckY - 3 + CGFloat((time * speed + Self.hash(i, 6) * length).truncatingRemainder(dividingBy: length))
                guard y >= streamTop && y <= streamEnd else { continue }
                grain(i, cx + CGFloat(sin(time * 11 + Double(i)) * 0.8) * neckScale + wobble, y, 1.9)
            }
            fillGrains()
            ctx.restoreGState()
        }

        // Grains landing on the pile and rolling down its slopes, speeding up as they go.
        if hitsPile, let bottom {
            let reach = max(0, bottom.slideTo - abs(landingOffset))
            for i in 0..<18 {
                let period = 0.9 + Self.hash(i, 7) * 1.1
                let u = CGFloat(((time + Self.hash(i, 8) * period) / period).truncatingRemainder(dividingBy: 1))
                let side: CGFloat = Self.hash(i, 9) < 0.5 ? -1 : 1
                let offset = landingOffset + side * reach * CGFloat(0.35 + 0.6 * Self.hash(i, 10)) * u * u
                let bounce = sin(u * .pi * 3) * (1 - u) * 1.8
                grain(i, cx + offset, bottom.y(offset) - 0.8 - abs(bounce), 1.7)
            }
            fillGrains()
        }
    }

    /// Grains leaping off a sand surface that's tilted with the glass (on its side, or mid-turn): the surface is the
    /// outline's edge facing against gravity, and grains hop straight up against gravity from points along it.
    private func drawLeapingGrains(off outline: [SandPhysics.Point], gravity g: SandPhysics.Point, level: CGFloat,
                                   seed: Int, theme: Theme, time: CFTimeInterval) {
        let depth = outline.map { $0.x * g.x + $0.y * g.y }
        guard let top = depth.min() else { return }
        let surface = zip(outline, depth).filter { $0.1 - top < 0.5 }.map(\.0)
        let along = SandPhysics.Point(x: -g.y, y: g.x)
        let positions = surface.map { $0.x * along.x + $0.y * along.y }
        guard let low = positions.min(), let high = positions.max(), high - low > 4 else { return }
        let middle = (low + high) / 2, half = CGFloat(high - low) / 2
        let upX = CGFloat(-g.x), upY = CGFloat(-g.y)
        // A point on the surface line: `top` units along gravity, `middle` units along the surface.
        let center = CGPoint(x: CGFloat(g.x * top + along.x * middle), y: CGFloat(g.y * top + along.y * middle))
        drawLeapingGrains(level: level, seed: seed, theme: theme, time: time) { spread, drift, hop in
            let offset = spread * half * 0.9 + drift
            return CGPoint(x: center.x + CGFloat(along.x) * offset + upX * (hop + 0.8),
                           y: center.y + CGFloat(along.y) * offset + upY * (hop + 0.8))
        }
    }

    /// Grains thrown up off a heap by shaking or a landing: each hops on a little parabola and lands nearby.
    /// Stronger jolts throw more grains, higher. Hops are slowed down about 3x from real life so they're visible.
    /// `place` turns a grain's spread across the surface (-1...1), sideways drift and hop height into a position.
    private func drawLeapingGrains(level: CGFloat, seed: Int, theme: Theme, time: CFTimeInterval,
                                   place: (_ spread: CGFloat, _ drift: CGFloat, _ hop: CGFloat) -> CGPoint) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        var light: [CGRect] = [], dark: [CGRect] = []
        for i in 0..<40 where Self.hash(i + seed, 11) < Double(level) * 1.15 {
            let height = level * CGFloat(4 + 16 * Self.hash(i + seed, 12))
            let period = 0.16 + 0.012 * Double(height)
            let u = CGFloat(((time + Self.hash(i + seed, 13) * period) / period).truncatingRemainder(dividingBy: 1))
            let point = place(CGFloat(Self.hash(i + seed, 14)) * 2 - 1, CGFloat(Self.hash(i + seed, 15) - 0.5) * 8 * u,
                              height * 4 * u * (1 - u))
            let rect = CGRect(x: point.x - 0.9, y: point.y - 0.9, width: 1.8, height: 1.8)
            if i % 3 == 0 { light.append(rect) } else { dark.append(rect) }
        }
        ctx.setFillColor((theme.sand.blended(withFraction: 0.3, of: .black) ?? theme.sand).cgColor)
        ctx.fill(dark)
        ctx.setFillColor((theme.sand.blended(withFraction: 0.45, of: .white) ?? theme.sand).cgColor)
        ctx.fill(light)
    }

    // MARK: Print and caps

    /// Time left on the bottom cap's upper ring (where the glass sits in the base), made to read as part of the plastic:
    /// the letters wrap around the curved ring, take on its lighting and shine, and sit slightly into the surface.
    /// Like a real display, it never draws outside the ring, and it fades as it switches on or off.
    private func drawBaseDisplay(_ display: BaseDisplay, theme: Theme) {
        guard display.brightness > 0.01, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let ring = CGRect(x: 19, y: 354, width: 162, height: 28)
        let center = CGPoint(x: cx, y: 365.5)
        var glyphs = wrappedLabelPath(display.text, ringCenterY: center.y, ringRadius: ring.width / 2)
        if display.rotation != 0 {
            var turn = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: display.rotation).translatedBy(x: -center.x, y: -center.y)
            glyphs = glyphs.copy(using: &turn) ?? glyphs
        }
        ctx.saveGState()
        ctx.clip(to: CGRect(x: ring.minX, y: ring.minY, width: ring.width, height: 23))  // the ring's face above the base disc
        ctx.setAlpha(CGFloat(display.brightness))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        defer {
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        func fill(offsetY: CGFloat, _ color: NSColor) {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: offsetY)
            ctx.addPath(glyphs)
            ctx.setFillColor(color.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }

        // Pressed into the plastic: light catches the lower lip, the upper edge falls into shadow.
        fill(offsetY: 0.6, NSColor(white: 1, alpha: theme.darkCap ? 0.16 : 0.4))
        fill(offsetY: -0.5, NSColor(white: 0, alpha: theme.darkCap ? 0.5 : 0.25))

        // Ink shaded like the ring it's printed on: darker toward the edges, brightest where the ring catches the light.
        let ink = theme.displayInk
        ctx.saveGState()
        ctx.addPath(glyphs)
        ctx.clip()
        NSGradient(colorsAndLocations:
            (ink.blended(withFraction: 0.5, of: .black) ?? ink, 0),
            (ink.blended(withFraction: 0.2, of: .white) ?? ink, 0.24),
            (ink, 0.6),
            (ink.blended(withFraction: 0.55, of: .black) ?? ink, 1)
        )?.draw(in: ring, angle: 0)
        // The ring's shine runs straight across the letters.
        NSGraphicsContext.current?.cgContext.setAlpha(theme.darkCap ? 0.35 : 0.25)
        NSGradient(colors: [NSColor(white: 1, alpha: 0), NSColor(white: 1, alpha: 1), NSColor(white: 1, alpha: 0)])?
            .draw(in: NSBezierPath(rect: CGRect(x: ring.minX + 8, y: ring.minY + ring.height * 0.35, width: ring.width - 16, height: 3)), angle: 0)
        ctx.restoreGState()
    }

    /// Outlines of the label's glyphs, centered on the ring and wrapped around it: each character is pushed toward
    /// the middle and narrowed by how far round the cylinder it sits, as seen from the front.
    private func wrappedLabelPath(_ text: String, ringCenterY: CGFloat, ringRadius: CGFloat) -> CGPath {
        // Monospaced digits so the label doesn't jitter as seconds tick.
        let font = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
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
                // Glyph outlines are drawn up from the baseline; flip them into this y-down space.
                let transform = CGAffineTransform(translationX: cx + ringRadius * sin(around), y: baseline)
                    .scaledBy(x: cos(around), y: -1)
                    .translatedBy(x: -advance / 2, y: 0)
                path.addPath(outline, transform: transform)
            }
        }
        return path
    }

    private func drawCap(top: Bool, theme: Theme) {
        let base = theme.cap
        let dark = base.blended(withFraction: 0.35, of: .black) ?? base
        let lit = base.blended(withFraction: 0.22, of: .white) ?? base
        let band = CGRect(x: 19, y: top ? 18 : 354, width: 162, height: 28)
        let disc = CGRect(x: 7, y: top ? 0 : 377, width: 186, height: 23)
        let glint = NSGradient(colors: [NSColor(white: 1, alpha: 0), NSColor(white: 1, alpha: 1), NSColor(white: 1, alpha: 0)])

        let bandPath = NSBezierPath(roundedRect: band, xRadius: 3, yRadius: 3)
        NSGradient(colorsAndLocations: (dark, 0), (lit, 0.22), (base, 0.6), (dark, 1))?.draw(in: bandPath, angle: 0)
        let seam = CGRect(x: band.minX + 2, y: top ? band.maxY - 1.5 : band.minY + 0.5, width: band.width - 4, height: 1)
        NSColor(white: 1, alpha: 0.12).setFill()
        NSBezierPath(rect: seam).fill()

        let discPath = NSBezierPath(roundedRect: disc, xRadius: 6, yRadius: 6)
        NSGradient(colorsAndLocations: (dark, 0), (lit, 0.2), (base, 0.55), (dark, 1))?.draw(in: discPath, angle: 0)
        NSGradient(starting: NSColor(white: 1, alpha: 0.16), ending: NSColor(white: 1, alpha: 0))?
            .draw(in: NSBezierPath(roundedRect: disc.insetBy(dx: 3, dy: 1), xRadius: 5, yRadius: 5), angle: 90)

        // Glossy plastic: a horizontal reflection streak and a thin bevel catching light along the top edge.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(0.3)
        glint?.draw(in: NSBezierPath(roundedRect: CGRect(x: disc.minX + 10, y: disc.minY + disc.height * 0.3,
                                                          width: disc.width - 20, height: 3.5), xRadius: 1.75, yRadius: 1.75), angle: 0)
        NSGraphicsContext.current?.cgContext.setAlpha(0.14)
        glint?.draw(in: NSBezierPath(rect: CGRect(x: band.minX + 8, y: band.minY + band.height * 0.35, width: band.width - 16, height: 3)), angle: 0)
        NSGraphicsContext.current?.cgContext.setAlpha(0.3)
        glint?.draw(in: NSBezierPath(rect: CGRect(x: disc.minX + 5, y: disc.minY + 0.6, width: disc.width - 10, height: 0.9)), angle: 0)
        NSGraphicsContext.restoreGraphicsState()

        NSColor(white: 0, alpha: 0.35).setFill()
        NSBezierPath(rect: CGRect(x: band.minX, y: top ? disc.maxY : disc.minY - 1, width: band.width, height: 1)).fill()
    }
}
