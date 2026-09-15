import AppKit

func themeTests() {
    suite("Colors") {
        let all = Theme.colors.indices.flatMap { color in Theme.Base.allCases.map { Theme(color: color, base: $0) } }

        test("every sand color comes on a black and a matching base, each with its own name") {
            expect(all.count == Theme.colors.count * 2)
            expect(Set(all.map(\.name)).count == all.count, "names key the cached glass layers, so they must differ")
            expect(Theme.colors.map(\.name).contains("White") && Theme.colors.map(\.name).contains("Black"))
        }
        test("the black base is black for every color") {
            for color in Theme.colors.indices {
                expect(Theme(color: color, base: .black).darkCap, Theme.colors[color].name)
            }
        }
        test("the time on the base is readable on every cap") {
            for theme in all {
                let ratio = contrast(theme.displayInk, theme.cap)
                expect(ratio >= 3, String(format: "%@: contrast %.1f", theme.name, ratio))
            }
        }
        test("a new timer is set up for a 25-minute Pomodoro") {
            expect(HourglassView.defaultMinutes == 25 && HourglassView.durations.contains(HourglassView.defaultMinutes))
            // A duration that isn't on the menu (like a corrupted saved setting) falls back to the default.
            let view = HourglassView(minutes: 7, themeIndex: 0, sizeIndex: 1)
            view.setPreview(progress: 0, running: true)
            expect(view.menuBarTime == "25:00", "got \(view.menuBarTime ?? "nil")")
        }
        test("durations include 6 and 12 minutes for 0.1- and 0.2-hour billing blocks, in order") {
            expect(HourglassView.durations.contains(6) && HourglassView.durations.contains(12))
            expect(HourglassView.durations == HourglassView.durations.sorted() && Set(HourglassView.durations).count == HourglassView.durations.count)
            let view = HourglassView(minutes: 12, themeIndex: 0, sizeIndex: 1)
            view.setPreview(progress: 0, running: true)
            expect(view.menuBarTime == "12:00", "a saved 12-minute setting is kept, got \(view.menuBarTime ?? "nil")")
        }
        test("an out-of-range color falls back to the first one") {
            expect(Theme(color: 99, base: .black).name == Theme(color: 0, base: .black).name)
        }
    }
}

/// WCAG contrast ratio between two colors (1 = identical, 21 = black on white).
private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
    func luminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB) ?? color
        func channel(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }
    let (la, lb) = (luminance(a), luminance(b))
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}
