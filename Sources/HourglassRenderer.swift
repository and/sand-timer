import AppKit

struct Theme {
    let name: String
    let sand: NSColor
    let cap: NSColor
    let darkPrint: Bool

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    static let all: [Theme] = [
        Theme(name: "Purple", sand: rgb(108, 46, 214), cap: rgb(22, 22, 24), darkPrint: true),
        Theme(name: "Teal", sand: rgb(52, 190, 166), cap: rgb(98, 206, 186), darkPrint: false),
        Theme(name: "Pink", sand: rgb(236, 98, 160), cap: rgb(244, 150, 192), darkPrint: false),
        Theme(name: "Blue", sand: rgb(40, 118, 226), cap: rgb(22, 22, 24), darkPrint: true),
    ]
}

/// Draws the timer in a 200 x 400 unit space (y grows downward, neck at y = 200).
/// The caller sets up the transform; everything here is resolution independent.
final class HourglassRenderer {
    private typealias G = HourglassGeometry
    private let geo = HourglassGeometry()
    private let cx: CGFloat = 100
    private let neckY: CGFloat = 200
    private var bottomY: CGFloat { neckY + CGFloat(G.halfLength) }
    private lazy var outerPath = glassPath(inner: false)
    private lazy var innerPath = glassPath(inner: true)
    private let speckles: [(rect: CGRect, light: Bool)]

    init() {
        var seed: UInt64 = 7
        func random() -> CGFloat {
            seed &+= 0x9E37_79B9_7F4A_7C15
            var z = seed
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return CGFloat((z ^ (z >> 31)) >> 11) / CGFloat(1 << 53)
        }
        speckles = (0..<1100).map { _ in
            (CGRect(x: 44 + random() * 112, y: 44 + random() * 312, width: 1.3, height: 1.3), random() < 0.5)
        }
    }

    func draw(progress: Double, flowing: Bool, time: CFTimeInterval, theme: Theme, topLabel: String, bottomLabel: String, shadow: Bool) {
        if shadow { drawShadow() }
        drawGlassBody()

        NSGraphicsContext.saveGraphicsState()
        innerPath.addClip()
        let crater = drawTopSand(progress: progress, flowing: flowing, theme: theme)
        let pile = drawBottomSand(progress: progress, flowing: flowing, theme: theme)
        if flowing { drawFlow(crater: crater, pile: pile, theme: theme, time: time) }
        drawHighlights()
        NSGraphicsContext.restoreGraphicsState()

        drawPrint(topLabel, centerY: 86, theme: theme)
        drawPrint(bottomLabel, centerY: 2 * neckY - 86, theme: theme)
        strokeGlass()
        drawCap(top: true, theme: theme)
        drawCap(top: false, theme: theme)
    }

    // MARK: Glass

    private func glassPath(inner: Bool) -> NSBezierPath {
        var right: [CGPoint] = []
        for i in 0...360 {
            let y = 20 + CGFloat(i)
            let d = min(Double(abs(y - neckY)), G.halfLength)
            let r = inner ? G.innerRadius(d) : G.outerRadius(d)
            right.append(CGPoint(x: cx + CGFloat(r), y: y))
        }
        let path = NSBezierPath()
        path.move(to: right[0])
        right.dropFirst().forEach { path.line(to: $0) }
        right.reversed().forEach { path.line(to: CGPoint(x: 2 * cx - $0.x, y: $0.y)) }
        path.close()
        return path
    }

    private func drawShadow() {
        let oval = NSBezierPath(ovalIn: CGRect(x: 0, y: 390, width: 200, height: 20))
        NSGradient(starting: NSColor(white: 0, alpha: 0.32), ending: NSColor(white: 0, alpha: 0))?
            .draw(in: oval, relativeCenterPosition: .zero)
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

    private func fillSand(_ path: NSBezierPath, theme: Theme) {
        let base = theme.sand
        let edge = base.blended(withFraction: 0.35, of: .black) ?? base
        let lit = base.blended(withFraction: 0.14, of: .white) ?? base
        NSGradient(colorsAndLocations: (edge, 0), (base, 0.25), (lit, 0.45), (base, 0.75), (edge, 1))?
            .draw(in: path, angle: 0)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let bounds = path.bounds
        let visible = speckles.filter { bounds.intersects($0.rect) }
        ctx.setFillColor((base.blended(withFraction: 0.4, of: .white) ?? base).withAlphaComponent(0.55).cgColor)
        ctx.fill(visible.filter(\.light).map(\.rect))
        ctx.setFillColor((base.blended(withFraction: 0.45, of: .black) ?? base).withAlphaComponent(0.5).cgColor)
        ctx.fill(visible.filter { !$0.light }.map(\.rect))
        NSGraphicsContext.restoreGraphicsState()
    }

    private struct SandSurface {
        let y: CGFloat        // surface height at the edges
        let lift: CGFloat     // how far the center sits below (crater, positive) or above (pile, negative) the edges
        let radius: CGFloat

        /// Surface height at a horizontal offset from the center.
        func height(at offset: CGFloat, falloff: (CGFloat) -> CGFloat) -> CGFloat {
            y + lift * falloff(min(1, abs(offset) / radius))
        }
    }

    private static func craterFalloff(_ u: CGFloat) -> CGFloat { 0.5 + 0.5 * cos(.pi * u) }
    private static func pileFalloff(_ u: CGFloat) -> CGFloat {
        let t = 1 - u
        return 0.7 * t + 0.3 * t * t * (3 - 2 * t)
    }

    private func drawTopSand(progress: Double, flowing: Bool, theme: Theme) -> SandSurface? {
        let h = CGFloat(geo.topSandHeight(progress: progress))
        guard h > 0.3 else { return nil }
        let r = CGFloat(G.innerRadius(Double(h))) + 1
        let crater = SandSurface(y: neckY - h, lift: flowing ? min(4, h * 0.3) : min(1.5, h * 0.2), radius: r * 0.8)
        let left = cx - r - 2, right = cx + r + 2

        let path = NSBezierPath()
        path.move(to: CGPoint(x: left, y: neckY + 4))
        for i in 0...48 {
            let x = left + (right - left) * CGFloat(i) / 48
            path.line(to: CGPoint(x: x, y: crater.height(at: x - cx, falloff: Self.craterFalloff)))
        }
        path.line(to: CGPoint(x: right, y: neckY + 4))
        path.close()
        fillSand(path, theme: theme)
        return crater
    }

    private func drawBottomSand(progress: Double, flowing: Bool, theme: Theme) -> SandSurface? {
        let volume = geo.sandVolume * progress
        guard volume > 1 else { return nil }
        let d = CGFloat(geo.bottomSurfaceDistance(progress: progress))
        let layer = bottomY - (neckY + d)
        let r = CGFloat(G.innerRadius(Double(d))) + 1
        let grow = CGFloat(min(1, volume / 40_000))
        let mound = min(flowing ? 20 : 15, 4 + layer * 1.6) * grow
        let pile = SandSurface(y: min(bottomY, neckY + d + mound * 0.4), lift: -mound, radius: r)
        let left = cx - r - 2, right = cx + r + 2

        let path = NSBezierPath()
        path.move(to: CGPoint(x: left, y: bottomY + 8))
        for i in 0...48 {
            let x = left + (right - left) * CGFloat(i) / 48
            path.line(to: CGPoint(x: x, y: min(bottomY + 1, pile.height(at: x - cx, falloff: Self.pileFalloff))))
        }
        path.line(to: CGPoint(x: right, y: bottomY + 8))
        path.close()
        fillSand(path, theme: theme)
        return pile
    }

    /// Stable pseudo-random value in 0..<1 for grain `i` and channel `k`.
    private static func hash(_ i: Int, _ k: Int) -> Double {
        let v = sin(Double(i) * 12.9898 + Double(k) * 78.233) * 43758.5453
        return v - v.rounded(.down)
    }

    /// Everything that moves while sand is flowing: grains sliding into the crater,
    /// a glittering stream through the neck, and grains tumbling down the pile.
    /// Positions are pure functions of time, so there is no particle state to keep.
    private func drawFlow(crater: SandSurface?, pile: SandSurface?, theme: Theme, time: CFTimeInterval) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let light = (theme.sand.blended(withFraction: 0.45, of: .white) ?? theme.sand).cgColor
        let dark = (theme.sand.blended(withFraction: 0.3, of: .black) ?? theme.sand).cgColor
        let peakY = pile.map { $0.y + $0.lift } ?? bottomY
        var lightGrains: [CGRect] = [], darkGrains: [CGRect] = []
        func grain(_ i: Int, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat) {
            let rect = CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size)
            if i % 3 == 0 { lightGrains.append(rect) } else { darkGrains.append(rect) }
        }

        // Grains creeping down the crater walls toward the neck.
        if let crater {
            for i in 0..<16 {
                let period = 1.4 + Self.hash(i, 1) * 1.6
                let u = CGFloat(((time + Self.hash(i, 2) * period) / period).truncatingRemainder(dividingBy: 1))
                let side: CGFloat = Self.hash(i, 3) < 0.5 ? -1 : 1
                let offset = side * crater.radius * CGFloat(0.25 + 0.75 * Self.hash(i, 4)) * (1 - u * u)
                grain(i, cx + offset, crater.height(at: offset, falloff: Self.craterFalloff) - 0.6, 1.6)
            }
        }

        // The stream: a slightly wavering core with grains racing down it.
        let top = neckY - 3
        let length = peakY - top
        if crater != nil, length > 2 {
            let wobble = CGFloat(sin(time * 23) * 0.25)
            ctx.setFillColor(theme.sand.withAlphaComponent(0.9).cgColor)
            ctx.fill(CGRect(x: cx - 1.1 + wobble, y: top, width: 2.2, height: length + 1))
            let count = Int(length / 5)
            for i in 0..<count {
                let speed = 170 + Self.hash(i, 5) * 60
                let y = (time * speed + Self.hash(i, 6) * Double(length)).truncatingRemainder(dividingBy: Double(length))
                let x = cx + CGFloat(sin(time * 11 + Double(i)) * 0.8) + wobble
                grain(i, x, top + CGFloat(y), 1.9)
            }
        }

        // Grains landing on the pile and rolling down its slopes, speeding up as they go.
        if let pile, crater != nil {
            for i in 0..<18 {
                let period = 0.9 + Self.hash(i, 7) * 1.1
                let u = CGFloat(((time + Self.hash(i, 8) * period) / period).truncatingRemainder(dividingBy: 1))
                let side: CGFloat = Self.hash(i, 9) < 0.5 ? -1 : 1
                let reach = pile.radius * CGFloat(0.35 + 0.6 * Self.hash(i, 10))
                let offset = side * reach * u * u
                let bounce = sin(u * .pi * 3) * (1 - u) * 1.8
                grain(i, cx + offset, pile.height(at: offset, falloff: Self.pileFalloff) - 0.8 - abs(bounce), 1.7)
            }
        }

        ctx.setFillColor(dark)
        ctx.fill(darkGrains)
        ctx.setFillColor(light)
        ctx.fill(lightGrains)
    }

    // MARK: Print and caps

    private func drawPrint(_ text: String, centerY: CGFloat, theme: Theme) {
        let color = theme.darkPrint ? NSColor(white: 0.07, alpha: 0.92) : NSColor(white: 1, alpha: 0.96)
        let shadow = NSShadow()
        // A soft halo keeps the number readable when sand piles up behind it.
        shadow.shadowColor = theme.darkPrint ? NSColor(white: 1, alpha: 0.7) : NSColor(white: 0, alpha: 0.35)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero

        let big = NSAttributedString(string: text, attributes: [
            // Monospaced digits so the label doesn't jitter as seconds tick.
            .font: NSFont.monospacedDigitSystemFont(ofSize: text.count > 3 ? 36 : 44, weight: .regular),
            .foregroundColor: color, .kern: -1.5, .shadow: shadow,
        ])
        let size = big.size()
        big.draw(at: CGPoint(x: cx - size.width / 2, y: centerY - size.height / 2))
    }

    private func drawCap(top: Bool, theme: Theme) {
        let base = theme.cap
        let dark = base.blended(withFraction: 0.35, of: .black) ?? base
        let lit = base.blended(withFraction: 0.22, of: .white) ?? base
        let band = CGRect(x: 19, y: top ? 18 : 354, width: 162, height: 28)
        let disc = CGRect(x: 7, y: top ? 0 : 377, width: 186, height: 23)

        let bandPath = NSBezierPath(roundedRect: band, xRadius: 3, yRadius: 3)
        NSGradient(colorsAndLocations: (dark, 0), (lit, 0.22), (base, 0.6), (dark, 1))?.draw(in: bandPath, angle: 0)
        let seam = CGRect(x: band.minX + 2, y: top ? band.maxY - 1.5 : band.minY + 0.5, width: band.width - 4, height: 1)
        NSColor(white: 1, alpha: 0.12).setFill()
        NSBezierPath(rect: seam).fill()

        let discPath = NSBezierPath(roundedRect: disc, xRadius: 6, yRadius: 6)
        NSGradient(colorsAndLocations: (dark, 0), (lit, 0.2), (base, 0.55), (dark, 1))?.draw(in: discPath, angle: 0)
        NSGradient(starting: NSColor(white: 1, alpha: 0.16), ending: NSColor(white: 1, alpha: 0))?
            .draw(in: NSBezierPath(roundedRect: disc.insetBy(dx: 3, dy: 1), xRadius: 5, yRadius: 5), angle: 90)
        NSColor(white: 0, alpha: 0.35).setFill()
        NSBezierPath(rect: CGRect(x: band.minX, y: top ? disc.maxY : disc.minY - 1, width: band.width, height: 1)).fill()
    }
}
