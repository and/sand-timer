import AppKit

func timerViewTests() {
    suite("Clicking") {
        test("a click starts the timer, the next pauses it, the next resumes it") {
            let timer = TimerHarness()
            expect(!timer.isRunning && !timer.isPaused, "a new timer waits to be flipped")
            timer.click(); timer.run(1.2)
            expect(timer.isRunning, "first click flips it to start")
            timer.click(); timer.run(1.0)
            expect(timer.isPaused, "second click pauses")
            let pausedTime = timer.view.menuBarTime
            timer.run(1.5)
            expect(timer.view.menuBarTime == pausedTime, "time stands still while paused")
            timer.click(); timer.run(1.5)
            expect(timer.isRunning, "third click resumes")
        }
    }

    suite("Pausing") {
        test("paused, it lies on its side flush on the ground, and resuming puts it back where it was") {
            let timer = TimerHarness()
            timer.click(); timer.settle()
            let standing = timer.center
            expect(abs(timer.gapBelowTimer()) < 0.6, "standing on the ground: gap \(timer.gapBelowTimer())")
            timer.menu("pauseClicked"); timer.settle()
            expect(abs(timer.gapBelowTimer()) < 0.6, "lying on the ground: gap \(timer.gapBelowTimer())")
            expect(abs((timer.center.y - timer.screen.minY) - 93 * timer.scale) < 1, "rests on its base discs")
            timer.click(); timer.settle()
            expect(abs(timer.center.x - standing.x) < 1 && abs(timer.center.y - standing.y) < 1,
                   "back at \(standing), got \(timer.center)")
            expect(timer.isRunning)
        }
        test("after resuming, new sand builds on the leveled layer instead of reshaping it") {
            let timer = TimerHarness(minutes: 1, color: 0)
            timer.click(); timer.run(9.0)
            timer.menu("pauseClicked"); timer.run(1.0)
            timer.click(); timer.run(0.8)  // stood back up: the bottom sand is a flat layer
            // Measured beside the stream (which would read as sand in the center column) and right by the wall.
            let wallAfterStandingUp = try require(timer.bottomSandHeight(atOffset: 50), "sand by the wall after standing up")
            let innerAfterStandingUp = try require(timer.bottomSandHeight(atOffset: 12), "sand near the middle after standing up")
            expect(abs(innerAfterStandingUp - wallAfterStandingUp) < 3, "the layer starts level: \(innerAfterStandingUp) vs \(wallAfterStandingUp)")
            timer.run(3.0)  // new sand lands on it
            let wall = try require(timer.bottomSandHeight(atOffset: 50), "sand by the wall later")
            let inner = try require(timer.bottomSandHeight(atOffset: 12), "sand near the middle later")
            expect(wall >= wallAfterStandingUp - 1, "the layer by the wall doesn't sink: \(wallAfterStandingUp) → \(wall)")
            expect(inner > wall + 3, "a cone grows on top: \(inner) near the middle vs \(wall) by the wall")
        }
        test("knocked over, it falls toward the side with more room") {
            let right = TimerHarness(x: NSScreen.main!.visibleFrame.maxX - 300)
            right.click(); right.settle()
            let before = right.center.x
            right.menu("pauseClicked"); right.settle()
            expect(right.center.x < before - 100, "near the right wall it falls left")

            let left = TimerHarness(x: NSScreen.main!.visibleFrame.minX + 40)
            left.click(); left.settle()
            let start = left.center.x
            left.menu("pauseClicked"); left.settle()
            expect(left.center.x > start + 100, "near the left wall it falls right")
        }
    }

    suite("Gravity") {
        test("dropped, the stream lets go of the neck while it falls, then pours again after landing") {
            let timer = TimerHarness(minutes: 25, color: 0)
            timer.click(); timer.settle(); timer.run(1.0)
            func sandJustBelowNeck() -> Bool {
                let rep = timer.render()
                let pixelsPerUnit = CGFloat(rep.pixelsHigh) / timer.view.bounds.height * timer.scale
                let column = rep.pixelsWide / 2
                let neckRow = Int(timer.view.bounds.midY / timer.view.bounds.height * CGFloat(rep.pixelsHigh))
                return (neckRow + Int(12 * pixelsPerUnit)..<neckRow + Int(30 * pixelsPerUnit)).contains { row in
                    guard let c = rep.colorAt(x: column, y: row)?.usingColorSpace(.sRGB), c.alphaComponent > 0.3 else { return false }
                    return c.blueComponent > c.redComponent * 1.3 && c.blueComponent > c.greenComponent * 1.8
                }
            }
            expect(sandJustBelowNeck(), "sand is pouring before the drop")
            let before = timer.view.menuBarTime
            // Lift it to the top of the screen and let go.
            timer.panel.setFrameOrigin(CGPoint(x: timer.panel.frame.minX, y: timer.screen.maxY - timer.panel.frame.height))
            timer.view.perform(NSSelectorFromString("letGo"))
            timer.run(0.35)
            expect(!sandJustBelowNeck(), "mid-fall, no stream leaves the neck")
            timer.settle(minimum: 0.5)
            timer.run(0.8)
            expect(sandJustBelowNeck(), "after landing it pours again")
            expect(timer.isRunning && timer.view.menuBarTime != nil && before != nil)
        }
    }

    suite("Tilting by hand") {
        test("pushing the top cap leans it; let go, it rocks back upright where it was") {
            let timer = TimerHarness(minutes: 25)
            timer.click(); timer.settle()
            let standing = timer.center
            timer.pressTopCap()
            timer.pushTopCap(by: 70)
            let leaning = timer.view.handTilt
            expect(leaning > 0.05 && leaning < SandPhysics.tippingAngle, "leans to the right without toppling: \(leaning)")
            expect(timer.isRunning, "still running while tilted")
            timer.releaseTopCap()
            timer.settle(minimum: 1.2)
            expect(timer.view.handTilt == 0, "back upright")
            expect(abs(timer.center.x - standing.x) < 1 && abs(timer.center.y - standing.y) < 1, "in the same place: \(timer.center) vs \(standing)")
            expect(timer.isRunning)
        }
        test("leaned one way, it can be swung back through upright and leaned the other way in the same press") {
            let timer = TimerHarness(minutes: 25)
            timer.click(); timer.settle()
            let standing = timer.center
            timer.pressTopCap()
            timer.pushTopCap(by: -70)
            expect(timer.view.handTilt < -0.05, "leans left: \(timer.view.handTilt)")
            timer.pushTopCap(by: 70)
            expect(abs(timer.view.handTilt) < 0.01, "back upright: \(timer.view.handTilt)")
            timer.pushTopCap(by: 70)
            expect(timer.view.handTilt > 0.05, "now leans right without letting go: \(timer.view.handTilt)")
            timer.releaseTopCap()
            timer.settle(minimum: 1.2)
            expect(timer.view.handTilt == 0 && abs(timer.center.x - standing.x) < 1 && abs(timer.center.y - standing.y) < 1,
                   "and still rocks back to where it stood: \(timer.center) vs \(standing)")
        }
        test("pushed past its tipping point, it topples onto its side and pauses") {
            let timer = TimerHarness(minutes: 25)
            timer.click(); timer.settle()
            timer.pressTopCap()
            timer.pushTopCap(by: -220, steps: 20)
            timer.settle(minimum: 0.8)
            expect(timer.isPaused, "knocked over means paused")
            expect(abs(timer.center.y - timer.screen.minY - 93 * timer.scale) < 1.5, "lying on its side on the ground")
            timer.releaseTopCap()
            timer.click(); timer.settle()
            expect(timer.isRunning && timer.view.handTilt == 0, "a click stands it back up and resumes")
        }
        test("a toppled timer lifted back past its balance point settles upright and resumes") {
            let timer = TimerHarness(minutes: 25)
            timer.click(); timer.settle()
            let standing = timer.center
            timer.pressTopCap(); timer.pushTopCap(by: -220, steps: 20); timer.releaseTopCap()
            timer.settle(minimum: 0.8)
            expect(timer.isPaused, "toppled and paused")
            let pivot = try require(timer.view.lyingPivot, "the corner it lies on")
            timer.pressTopCap()
            timer.liftTopCap(toLean: -0.15, from: -.pi / 2, pivot: pivot)
            timer.releaseTopCap()
            timer.settle(minimum: 1.5)
            expect(timer.isRunning, "standing again, it carries on")
            expect(abs(timer.center.x - standing.x) < 1.5 && abs(timer.center.y - standing.y) < 1.5,
                   "back where it stood: \(timer.center) vs \(standing)")
        }
        test("lifted only part way, it falls back onto its side and stays paused") {
            let timer = TimerHarness(minutes: 25)
            timer.click(); timer.settle()
            timer.pressTopCap(); timer.pushTopCap(by: 220, steps: 20); timer.releaseTopCap()
            timer.settle(minimum: 0.8)
            let pivot = try require(timer.view.lyingPivot, "the corner it lies on")
            timer.pressTopCap()
            timer.liftTopCap(toLean: 1.0, from: .pi / 2, pivot: pivot)
            timer.releaseTopCap()
            timer.settle(minimum: 1.0)
            expect(timer.isPaused, "still paused")
            expect(abs(timer.center.y - timer.screen.minY - 93 * timer.scale) < 1.5, "lying on its side again")
        }
        test("pulled up by the top cap, it is picked up without tilting, and let go it drops back to the ground") {
            let timer = TimerHarness(minutes: 25)
            timer.click(); timer.settle()
            let standing = timer.center
            timer.pressTopCap()
            timer.moveTopCap(by: CGVector(dx: 8, dy: 150))
            expect(timer.view.handTilt == 0, "carried, not tilted: \(timer.view.handTilt)")
            expect(timer.center.y - standing.y > 140 && abs(timer.center.x - standing.x - 8) < 1, "follows the hand up: \(timer.center) vs \(standing)")
            timer.moveTopCap(by: CGVector(dx: 60, dy: 0))
            expect(timer.view.handTilt == 0 && abs(timer.center.x - standing.x - 68) < 1, "and sideways once picked up, still upright")
            timer.releaseTopCap()
            timer.settle(minimum: 0.8)
            expect(abs(timer.center.y - standing.y) < 1, "dropped back to the ground: \(timer.center.y) vs \(standing.y)")
            expect(timer.isRunning, "a pick-up isn't a click")
        }
        test("pushed down on the top cap, nothing happens") {
            let timer = TimerHarness(minutes: 25)
            timer.click(); timer.settle()
            let standing = timer.center
            timer.pressTopCap()
            timer.moveTopCap(by: CGVector(dx: 5, dy: -40))
            timer.moveTopCap(by: CGVector(dx: 80, dy: 0))
            timer.releaseTopCap()
            timer.settle()
            expect(timer.view.handTilt == 0 && timer.center == standing, "didn't tilt or move: \(timer.center) vs \(standing)")
            expect(timer.isRunning, "and wasn't a click either")
        }
        test("a press on the top cap without pushing is still an ordinary click") {
            let timer = TimerHarness(minutes: 25)
            timer.pressTopCap(); timer.releaseTopCap(); timer.settle()
            expect(timer.isRunning, "starts it")
        }
        test("tilting makes the pile slump toward the low side, and it stays slumped") {
            let timer = TimerHarness(minutes: 1, color: 0)
            timer.click(); timer.settle(); timer.run(9)
            let left = try require(timer.bottomSandHeight(atOffset: -45), "left edge of the pile")
            let right = try require(timer.bottomSandHeight(atOffset: 45), "right edge of the pile")
            timer.pressTopCap()
            timer.pushTopCap(by: 120)
            timer.run(1.0)
            timer.releaseTopCap()
            timer.settle(minimum: 1.2)
            let leftAfter = try require(timer.bottomSandHeight(atOffset: -45), "left edge after")
            let rightAfter = try require(timer.bottomSandHeight(atOffset: 45), "right edge after")
            // Measured near the walls: the middle of a slope barely changes height as it flattens.
            expect((rightAfter - leftAfter) - (right - left) > 3,
                   "sand moved toward the side it was tipped to: before \(left)/\(right), after \(leftAfter)/\(rightAfter)")
        }
    }

    suite("Floating") {
        test("with Float Anywhere on it stays where it's let go; turning it off drops it to the ground") {
            UserDefaults.standard.set(false, forKey: "float")
            let timer = TimerHarness()
            timer.menu("floatToggled")
            expect(timer.view.floats, "the option turns on")
            let midAir = timer.screen.midY
            timer.panel.setFrameOrigin(CGPoint(x: timer.panel.frame.minX, y: midAir - timer.panel.frame.height / 2))
            timer.view.perform(NSSelectorFromString("letGo"))
            timer.settle(minimum: 0.6)
            expect(abs(timer.center.y - midAir) < 1, "stays in mid-air: \(timer.center.y) vs \(midAir)")
            // Nothing below it to cast a shadow on: the soft grey pool under the base is gone.
            func shadowPixels() -> Int {
                let rep = timer.render()
                let ppu = CGFloat(rep.pixelsHigh) / timer.view.bounds.height * timer.scale
                let groundRow = Int(timer.view.bounds.midY / timer.view.bounds.height * CGFloat(rep.pixelsHigh) + 203 * ppu)
                return (groundRow..<min(rep.pixelsHigh, groundRow + Int(8 * ppu))).reduce(0) { total, row in
                    total + stride(from: 0, to: rep.pixelsWide, by: 2).filter { x in
                        guard let c = rep.colorAt(x: x, y: row) else { return false }
                        return c.alphaComponent > 0.03 && c.alphaComponent < 0.9
                    }.count
                }
            }
            expect(shadowPixels() == 0, "a floating timer casts no shadow (\(shadowPixels()) shadow pixels)")
            timer.click(); timer.settle()
            expect(abs(timer.center.y - midAir) < 1 && timer.isRunning, "flipping in mid-air doesn't make it fall")
            timer.menu("floatToggled")
            timer.settle(minimum: 0.6)
            expect(!timer.view.floats && abs(timer.center.y - timer.screen.minY - 200 * timer.scale) < 1, "falls to the ground when turned off")
            expect(shadowPixels() > 50, "back on the ground, it casts a shadow again")
            UserDefaults.standard.set(false, forKey: "float")
        }
    }

    suite("Flipping") {
        test("flipping mid-run swaps what's left, and the window returns to its size afterwards") {
            let timer = TimerHarness()
            let size = timer.panel.frame.size
            timer.click(); timer.run(4.0)
            timer.menu("flipClicked"); timer.run(0.2)
            expect(timer.panel.frame.width > size.width, "the window grows so the turning glass isn't clipped")
            timer.run(1.0)
            expect(timer.panel.frame.size == size, "and shrinks back after landing")
            let left = try require(timer.view.menuBarTime, "time left after flipping")
            expect(["0:04", "0:03", "0:02"].contains(left), "about 4 seconds of sand is back on top, got \(left)")
        }
        test("a flipped timer with little sand runs out, then waits to be flipped again") {
            let timer = TimerHarness()
            timer.click(); timer.run(1.5)
            timer.menu("flipClicked"); timer.run(3.0)
            expect(!timer.isRunning && !timer.isPaused, "finished")
            expect(timer.view.menuBarTime == nil)
        }
    }

    suite("Screen box") {
        test("shoved past the edge, it's kept inside the screen and on the ground") {
            let timer = TimerHarness(x: NSScreen.main!.visibleFrame.maxX + 50)
            let halfWidth = 93 * timer.scale
            expect(timer.center.x + halfWidth <= timer.screen.maxX + 1, "inside the right edge")
            expect(abs(timer.center.y - timer.screen.minY - 200 * timer.scale) < 1, "standing on the ground")
            timer.click(); timer.run(1.5)
            expect(timer.center.x + halfWidth <= timer.screen.maxX + 1, "still inside after flipping by the wall")
            expect(abs(timer.center.y - timer.screen.minY - 200 * timer.scale) < 1, "back on the ground after the flip")
        }
    }

    suite("Menu commands") {
        test("the sound settings sit together in their own section, between separators") {
            let items = TimerHarness(minutes: 25).view.makeMenu().items
            let start = try require(items.firstIndex { $0.title == "Flip, Fall & Finish Sounds" }, "the first sound setting")
            let end = try require(items[start...].firstIndex { $0.isSeparatorItem }, "the section ends")
            expect(items[start - 1].isSeparatorItem, "a separator above it")
            let section = items[start..<end].map(\.title)
            expect(section == ["Flip, Fall & Finish Sounds", "Sand Sounds", "Minute Chimes"], "got \(section)")
            let volumes = try require(items[start..<end].first { $0.title == "Sand Sounds" }?.submenu?.items, "sand volumes")
            expect(volumes.map(\.title) == ["Off", "Quiet", "Normal", "Loud"], "got \(volumes.map(\.title))")
            expect(volumes.filter { $0.state == .on }.count == 1, "exactly one is ticked")
        }
        test("picking a sand volume changes how loud the sand is, and it can be turned off") {
            let timer = TimerHarness(minutes: 25)
            let wasVolume = timer.view.grainVolume
            defer { timer.menu("grainVolumePicked", tag: HourglassView.grainVolumes.firstIndex { $0.volume == wasVolume } ?? 2) }
            timer.menu("grainVolumePicked", tag: 1)
            let quiet = timer.view.grainVolume
            timer.menu("grainVolumePicked", tag: 3)
            expect(quiet > 0 && timer.view.grainVolume > quiet, "Loud is louder than Quiet: \(quiet) then \(timer.view.grainVolume)")
            timer.menu("grainVolumePicked", tag: 0)
            expect(timer.view.grainVolume == 0, "Off silences it")
            timer.click(); timer.settle(); timer.run(0.5)
            expect(Sounds.pourOnGlass?.isPlaying != true && Sounds.pourOnSand?.isPlaying != true, "no pouring sound while off")
        }
        test("with Minute Chimes on, a chime plays as each minute passes, and none when it's off") {
            let timer = TimerHarness(minutes: 25)
            let wasOn = timer.view.minuteChimesOn
            defer { if timer.view.minuteChimesOn != wasOn { timer.menu("minuteChimesToggled") } }
            if wasOn { timer.menu("minuteChimesToggled") }
            timer.view.setPreview(progress: 59.4 / 1500, running: true)
            timer.run(1.2)
            expect(timer.view.minuteChimesPlayed == 0, "silent while off")
            timer.menu("minuteChimesToggled")
            timer.view.setPreview(progress: 119.4 / 1500, running: true)
            timer.run(1.2)
            expect(timer.view.minuteChimesPlayed == 1, "one chime at 2 minutes: \(timer.view.minuteChimesPlayed)")
            timer.run(1.0)
            expect(timer.view.minuteChimesPlayed == 1, "and no more until the next minute")
        }
        test("changing size keeps the timer on the ground") {
            let timer = TimerHarness()
            for size in HourglassView.sizes.indices {
                timer.menu("sizePicked", tag: size)
                timer.sizeIndex = size
                timer.run(0.1)
                expect(abs(timer.center.y - timer.screen.minY - 200 * timer.scale) < 1, "\(HourglassView.sizes[size].name)")
                expect(timer.panel.frame.size == HourglassView.contentSize(sizeIndex: size))
            }
        }
        test("pause and resume work while the timer is hidden in the menu bar") {
            let timer = TimerHarness()
            timer.click(); timer.run(1.2)
            timer.panel.orderOut(nil)
            timer.view.togglePause(); timer.run(1.0)
            expect(timer.isPaused && timer.view.menuBarTime?.hasSuffix("⏸") == true)
            timer.view.togglePause(); timer.run(1.2)
            expect(timer.isRunning)
        }
    }

    suite("Statistics") {
        test("the menu offers the statistics window") {
            let items = TimerHarness().view.makeMenu().items.map(\.title)
            expect(items.contains("Statistics…"), "got \(items)")
        }
        test("running the timer adds to today's record, and it is written out when the sand stops") {
            let timer = TimerHarness()
            let before = timer.view.statistics.log.buckets(.daily, at: Date()).last?.seconds ?? 0
            timer.click(); timer.run(2.2)
            timer.menu("pauseClicked"); timer.run(0.4)
            let today = try require(timer.view.statistics.log.buckets(.daily, at: Date()).last, "today's bar")
            expect(today.title == "Today")
            let ran = today.seconds - before
            expect(ran > 1.5 && ran < 3.5, "about two seconds of sand ran, got \(ran)")
            expect(SandLog.load().allTime.seconds >= today.seconds - 0.01, "saved once it stopped: \(SandLog.load().allTime.seconds)")
            timer.run(1.0)
            expect(timer.view.statistics.log.buckets(.daily, at: Date()).last?.seconds == today.seconds, "paused sand adds nothing")
        }
        test("the statistics window opens, draws today's bar in the sand's color, and closes") {
            let timer = TimerHarness(color: 1)  // teal, so the bars can't be mistaken for anything else on screen
            timer.click(); timer.run(1.5)
            timer.menu("statsClicked"); timer.run(0.4)
            let window = try require(StatsPanel.open, "the statistics window")
            defer { window.close() }
            let view = try require(window.contentView, "its content")
            let rep = try require(view.bitmapImageRepForCachingDisplay(in: view.bounds), "a bitmap to draw into")
            view.cacheDisplay(in: view.bounds, to: rep)
            let sand = try require(Theme(color: 1, base: .black).sand.usingColorSpace(.sRGB), "the sand color")
            // Only the chart half, below the headline: the picker's selected segment is colored too.
            var bars = 0
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                for y in stride(from: rep.pixelsHigh * 2 / 5, to: rep.pixelsHigh, by: 3) {
                    guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), pixel.saturationComponent > 0.2 else { continue }
                    if abs(pixel.hueComponent - sand.hueComponent) < 0.06 { bars += 1 }
                }
            }
            expect(bars > 200, "today's bar is drawn in the sand's color: \(bars) pixels")
            let button = try require(view.subviews.compactMap({ $0 as? NSButton }).first { $0.title == "Export…" }, "the Export button")
            expect(button.isEnabled, "there is a record to save, so it can be exported")
            window.close(); timer.run(0.2)
            expect(StatsPanel.open == nil, "closing it puts it away")
        }
    }

    suite("Update checks") {
        test("the menu offers Check for Updates, and it can be turned off and on again") {
            let timer = TimerHarness()
            let wasOn = UpdateChecker.shared.isEnabled
            defer { UpdateChecker.shared.setEnabled(wasOn) }
            UpdateChecker.shared.setEnabled(true)
            let on = try require(timer.view.makeMenu().items.first { $0.title == "Check for Updates" }, "the menu item")
            expect(on.state == .on, "ticked while the app looks for updates")
            timer.menu("updateChecksToggled")
            expect(!UpdateChecker.shared.isEnabled, "turned off")
            let off = try require(timer.view.makeMenu().items.first { $0.title == "Check for Updates" }, "the menu item")
            expect(off.state == .off, "and the tick goes with it")
            expect(UpdateChecker.shared.available == nil, "nothing is offered while the check is off")
            timer.menu("updateChecksToggled")
            expect(UpdateChecker.shared.isEnabled, "and back on")
        }
    }

    suite("Rendering") {
        test("every color on both bases draws its sand, glass and caps") {
            for color in Theme.colors.indices {
                for base in Theme.Base.allCases {
                    let view = HourglassView(minutes: 25, themeIndex: color, baseIndex: base.rawValue, sizeIndex: 1)
                    view.setPreview(progress: 0.4, running: true)
                    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let sand = Theme(color: color, base: base).sand.usingColorSpace(.sRGB)!
                    var solid = 0, sandLike = 0
                    for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                        for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { continue }
                            solid += 1
                            if abs(c.redComponent - sand.redComponent) + abs(c.greenComponent - sand.greenComponent)
                                + abs(c.blueComponent - sand.blueComponent) < 0.25 { sandLike += 1 }
                        }
                    }
                    let name = Theme(color: color, base: base).name
                    expect(solid > 1_000, "\(name): drew \(solid) solid pixels")
                    expect(sandLike > 150, "\(name): \(sandLike) sand-colored pixels")
                }
            }
        }
        test("the stream is thicker for short timers and finer for long ones") {
            // The stream flickers with time, so all three are rendered back to back (sharing the same flicker) before the
            // slow pixel measuring, at several moments, and the widths are averaged.
            func render(minutes: Int) -> (HourglassView, NSBitmapImageRep) {
                let view = HourglassView(minutes: minutes, themeIndex: 0, sizeIndex: 2)
                view.setPreview(progress: 0.3, running: true)
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: rep)
                return (view, rep)
            }
            func streamWidth(_ view: HourglassView, _ rep: NSBitmapImageRep) -> Double {
                // Rows through the upper part of the lower bulb, where only the stream crosses. Coverage is summed from each
                // pixel's opacity so differences smaller than a pixel still count, and grains racing down the stream widen
                // single rows, so take the typical (median) row.
                let widths = stride(from: 20, through: 70, by: 5).map { units -> Double in
                    let row = Int((view.bounds.midY + CGFloat(units)) / view.bounds.height * CGFloat(rep.pixelsHigh))
                    return (0..<rep.pixelsWide).reduce(0.0) { total, x in
                        guard let c = rep.colorAt(x: x, y: row)?.usingColorSpace(.sRGB),
                              c.blueComponent > c.redComponent * 1.3 && c.blueComponent > c.greenComponent * 1.8 else { return total }
                        return total + Double(c.alphaComponent)
                    }
                }.sorted()
                return widths[widths.count / 2]
            }
            var totals = [0.0, 0.0, 0.0]
            for _ in 0..<5 {
                let renders = [1, 25, 60].map(render)
                for (i, (view, rep)) in renders.enumerated() { totals[i] += streamWidth(view, rep) / 5 }
                RunLoop.main.run(until: Date().addingTimeInterval(0.13))
            }
            let (one, pomodoro, hour) = (totals[0], totals[1], totals[2])
            expect(one > pomodoro && pomodoro > hour, "stream widths in pixels: 1 min \(one), 25 min \(pomodoro), 60 min \(hour)")
        }
        test("sand pours through a wide neck without a seam where it meets the stream") {
            let view = HourglassView(minutes: 1, themeIndex: 0, sizeIndex: 2)
            view.setPreview(progress: 0.4, running: true)
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            let pixelsPerUnit = CGFloat(rep.pixelsHigh) / view.bounds.height
            // Width of sand in each pixel row from just above the neck to well into the stream.
            let neckRow = Int(view.bounds.midY * pixelsPerUnit)
            let widths = (neckRow - 2...neckRow + Int(14 * pixelsPerUnit)).map { row in
                (0..<rep.pixelsWide).filter { x in
                    guard let c = rep.colorAt(x: x, y: row)?.usingColorSpace(.sRGB), c.alphaComponent > 0.3 else { return false }
                    return c.blueComponent > c.redComponent * 1.3 && c.blueComponent > c.greenComponent * 1.8
                }.count
            }
            let steps = zip(widths, widths.dropFirst()).map { $0 - $1 }
            expect(widths.first! > widths.last! + 8, "the sand narrows from the neck into the stream: \(widths)")
            expect(steps.allSatisfy { $0 <= 6 }, "no sudden step anywhere: \(widths)")
        }
        test("turning, lying and shaken poses draw without problems") {
            for (angle, shake) in [(1.2, 0.0), (.pi / 2, 1.0), (-.pi / 2, 0.5), (0.2, 1.0)] {
                let view = HourglassView(minutes: 5, themeIndex: 1, sizeIndex: 1)
                view.setPreview(progress: 0.6, running: true)
                view.previewAngle = angle
                view.previewAgitation = shake
                let side = hypot(view.frame.width, view.frame.height).rounded(.up)
                view.frame.size = NSSize(width: side, height: side)
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: rep)
                expect(rep.pixelsWide > 0, "angle \(angle)")
            }
        }
    }

    suite("Performance") {
        test("a running timer at the largest size stays light on the CPU") {
            let timer = TimerHarness(size: 2)
            timer.click(); timer.run(1.0)
            func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
            // The better of two windows, so a busy moment elsewhere on the machine doesn't fail the test.
            let share = (0..<2).map { _ -> Double in
                var before = rusage(), after = rusage()
                getrusage(RUSAGE_SELF, &before)
                let start = Date()
                timer.run(2.5)
                getrusage(RUSAGE_SELF, &after)
                let cpu = (seconds(after.ru_utime) + seconds(after.ru_stime)) - (seconds(before.ru_utime) + seconds(before.ru_stime))
                return cpu / Date().timeIntervalSince(start)
            }.min()!
            print(String(format: "      CPU: %.0f%% of one core", share * 100))
            // Typically about 20% on an idle Apple Silicon Mac; the budget leaves room for a machine that's busy with other work.
            expect(share < 0.45, String(format: "used %.0f%% of a core", share * 100))
        }
    }
}
