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
        test("how the timer looks is gathered under Appearance, with the duration left to hand") {
            let items = TimerHarness(minutes: 25).view.makeMenu().items
            let titles = items.map(\.title)
            expect(titles.contains("Duration"), "the duration stays in the menu itself: \(titles)")
            expect(!titles.contains("Color") && !titles.contains("Base") && !titles.contains("Size"), "the rest moves: \(titles)")
            let looks = try require(items.first { $0.title == "Appearance" }?.submenu?.items, "the Appearance submenu")
            expect(looks.map(\.title) == ["Color", "Base", "Size"], "got \(looks.map(\.title))")
            expect(looks.allSatisfy { $0.submenu?.items.isEmpty == false }, "each opens onto its own choices")
            let hide = try require(titles.firstIndex(of: "Hide to Menu Bar"), "Hide to Menu Bar")
            let duration = try require(titles.firstIndex(of: "Duration"), "Duration")
            expect(hide < duration, "hiding it is something to do with the timer, so it sits with Flip and Restart")
        }
        test("picking a sand volume changes how loud the sand is, and it can be turned off", serial: true) {
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
        test("sand set to be heard is heard while the timer is hidden, because the menu says it is on", serial: true) {
            let timer = TimerHarness(minutes: 25)
            let wasVolume = timer.view.grainVolume
            defer { timer.menu("grainVolumePicked", tag: HourglassView.grainVolumes.firstIndex { $0.volume == wasVolume } ?? 0) }
            timer.menu("grainVolumePicked", tag: 2)  // Normal
            timer.click(); timer.settle(); timer.run(0.8)
            expect(Sounds.pourOnGlass?.isPlaying == true || Sounds.pourOnSand?.isPlaying == true, "pouring while on screen")
            timer.panel.orderOut(nil)  // away to the menu bar
            timer.run(0.8)
            expect(Sounds.pourOnGlass?.isPlaying == true || Sounds.pourOnSand?.isPlaying == true, "and still pouring, hidden")
            timer.menu("grainVolumePicked", tag: 0)  // Off
            timer.run(0.5)
            expect(Sounds.pourOnGlass?.isPlaying != true && Sounds.pourOnSand?.isPlaying != true, "silenced only by the setting")
        }
        test("the sound settings can be changed from the menu bar's menu too") {
            let timer = TimerHarness()
            let wasOn = timer.view.minuteChimesOn
            defer { if timer.view.minuteChimesOn != wasOn { timer.menu("minuteChimesToggled") } }
            timer.panel.orderOut(nil)  // tucked away in the menu bar, with no window to right-click
            let items = timer.view.soundMenuItems()
            expect(items.map(\.title) == ["Flip, Fall & Finish Sounds", "Sand Sounds", "Minute Chimes"], "got \(items.map(\.title))")
            expect(items[1].submenu?.items.map(\.title) == ["Off", "Quiet", "Normal", "Loud"])
            let chimes = items[2]
            expect(chimes.state == (wasOn ? .on : .off), "shows how they are set")
            _ = chimes.target?.perform(chimes.action, with: chimes)  // as if picked from the menu bar
            expect(timer.view.minuteChimesOn != wasOn, "and picking one changes it")
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
        // Serial, and run against a project of its own: once any time is counted against a project the bars are drawn in
        // project colours, and earlier project tests leave such time in this test program's record.
        test("the statistics window opens, draws today's bar in the sand's color, and closes", serial: true) {
            let timer = TimerHarness(color: 1)  // teal, so the bars can't be mistaken for anything else on screen
            let before = timer.view.projects, active = timer.view.activeProjectID
            defer { timer.view.updateProjects(before); timer.view.switchProject(to: active) }
            timer.view.updateProjects(ProjectList(all: before.all + [Project(id: "t-stats", name: "Teal", color: Theme(color: 1, base: .black).sand.hexString)]))
            timer.view.switchProject(to: "t-stats")
            // Narrowed to that project, today's bar is all its own, whatever else today holds.
            UserDefaults.standard.set("t-stats", forKey: "statsProject")
            defer { UserDefaults.standard.removeObject(forKey: "statsProject") }
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

    suite("Settings and the daily target") {
        test("the menu opens the settings, and no longer carries the switches that live there") {
            let titles = TimerHarness().view.makeMenu().items.map(\.title)
            expect(titles.contains("Settings…"), "got \(titles)")
            for moved in ["Start at Login", "Float Anywhere", "Control from Claude & Shortcuts", "Check for Updates"] {
                expect(!titles.contains(moved), "\(moved) belongs in the settings: \(titles)")
            }
        }
        test("the settings window shows what is set, and its switches work the timer", serial: true) {
            let timer = TimerHarness()
            let wasFloating = timer.view.floats
            defer { if timer.view.floats != wasFloating { timer.menu("floatToggled") } }
            SettingsPanel.show(for: timer.view)
            defer { SettingsPanel.open?.close() }
            let settings = try require(SettingsPanel.open?.settings, "the window")
            expect(Set(settings.switches.keys) == ["Start at Login", "Float Anywhere", "Control from Claude & Shortcuts", "Check for Updates",
                                                   "One Thing at a Time"],
                   "got \(settings.switches.keys.sorted())")
            let float = try require(settings.switches["Float Anywhere"], "the switch")
            expect((float.state == .on) == timer.view.floats, "it starts out showing what the timer does")
            float.performClick(nil)
            expect(timer.view.floats != wasFloating, "and clicking it changes the timer")
        }
        test("a daily target puts today's progress on the base, and none takes it away") {
            let timer = TimerHarness()
            let before = timer.view.dailyTargetMinutes
            defer { timer.view.setDailyTarget(minutes: before) }
            timer.view.setDailyTarget(minutes: 0)
            expect(timer.view.dailyGoalLabel == nil, "no label without a target")
            timer.view.setDailyTarget(minutes: 60)
            let label = try require(timer.view.dailyGoalLabel, "a label with one")
            expect(label.hasSuffix("/60:00"), "the target is on the right: \(label)")
            let seconds = timer.view.statistics.log.seconds(on: Date())
            expect(label == SandLog.goalLabel(seconds: seconds, target: 3600), "and today's sand on the left: \(label)")
            timer.view.setDailyTarget(minutes: 90_000)
            expect(timer.view.dailyTargetMinutes == HourglassView.longestDailyTarget, "a target can't be longer than a day")
            timer.view.setDailyTarget(minutes: -5)
            expect(timer.view.dailyGoalLabel == nil, "and a negative one means none")
        }
        test("the line is drawn along the base once there is a target") {
            let timer = TimerHarness()
            let before = timer.view.dailyTargetMinutes
            defer { timer.view.setDailyTarget(minutes: before) }
            func plate() throws -> [UInt8] {
                let rep = try require(timer.view.bitmapImageRepForCachingDisplay(in: timer.view.bounds), "a bitmap")
                timer.view.cacheDisplay(in: timer.view.bounds, to: rep)
                let data = try require(rep.bitmapData, "pixels")
                let perUnit = CGFloat(rep.pixelsHigh) / timer.view.bounds.height
                let top = Int((timer.view.bounds.midY + 178 * timer.scale) * perUnit), bottom = Int((timer.view.bounds.midY + 198 * timer.scale) * perUnit)
                return Array(UnsafeBufferPointer(start: data + top * rep.bytesPerRow, count: (bottom - top) * rep.bytesPerRow))
            }
            timer.view.setDailyTarget(minutes: 0)
            let bare = try plate()
            timer.view.setDailyTarget(minutes: 60)
            let ruled = try plate()
            expect(bare != ruled, "the line is drawn along the base")
        }
        test("resting the pointer on the base prints the day's figure over the line, and leaving takes it away") {
            let timer = TimerHarness()
            let before = timer.view.dailyTargetMinutes
            defer { timer.view.setDailyTarget(minutes: before) }
            timer.view.setDailyTarget(minutes: 180)
            expect(!timer.view.showsGoalFigure, "nothing until the pointer comes")
            timer.view.hoverBasePlate(true)
            timer.run(0.1)
            expect(!timer.view.showsGoalFigure, "not the instant it passes over")
            timer.run(0.6)
            expect(timer.view.showsGoalFigure, "but once it rests there")
            expect(timer.view.dailyGoalLabel?.hasSuffix("/3:00:00") == true, "reading against three hours: \(timer.view.dailyGoalLabel ?? "")")
            timer.view.hoverBasePlate(false)
            timer.run(0.5)
            expect(!timer.view.showsGoalFigure, "gone once it leaves")
            timer.view.setDailyTarget(minutes: 0)
            timer.view.hoverBasePlate(true)
            timer.run(0.7)
            expect(!timer.view.showsGoalFigure, "and never without a target")
        }
        test("running the timer moves today's progress") {
            let timer = TimerHarness()
            let before = timer.view.dailyTargetMinutes
            defer { timer.view.setDailyTarget(minutes: before) }
            timer.view.setDailyTarget(minutes: 60)
            let start = timer.view.statistics.log.seconds(on: Date())
            timer.click(); timer.run(2.2)
            timer.menu("pauseClicked"); timer.run(0.4)
            let run = timer.view.statistics.log.seconds(on: Date()) - start
            expect(run > 1.5 && run < 3.5, "about two seconds went on the day, got \(run)")
            expect(timer.view.dailyGoalLabel == SandLog.goalLabel(seconds: start + run, target: 3600), "and the label follows")
        }
        test("the target is set from the window, in minutes or in hours") {
            let timer = TimerHarness()
            let before = timer.view.dailyTargetMinutes
            defer { timer.view.setDailyTarget(minutes: before) }
            timer.view.setDailyTarget(minutes: 0)
            SettingsPanel.show(for: timer.view)
            defer { SettingsPanel.open?.close() }
            let settings = try require(SettingsPanel.open?.settings, "the window")
            expect(settings.targetCheck.state == .off && !settings.targetField.isEnabled, "off, and the number waits")
            settings.targetCheck.performClick(nil)
            expect(timer.view.dailyTargetMinutes == 60, "switching it on starts from an hour: \(timer.view.dailyTargetMinutes)")
            settings.targetField.doubleValue = 2.5
            settings.unitPicker.selectItem(at: 1)
            _ = settings.targetField.target?.perform(settings.targetField.action, with: settings.targetField)
            expect(timer.view.dailyTargetMinutes == 150, "two and a half hours: \(timer.view.dailyTargetMinutes)")
            settings.targetField.doubleValue = 45
            settings.unitPicker.selectItem(at: 0)
            _ = settings.targetField.target?.perform(settings.targetField.action, with: settings.targetField)
            expect(timer.view.dailyTargetMinutes == 45, "forty-five minutes: \(timer.view.dailyTargetMinutes)")
            settings.targetField.doubleValue = 30
            settings.unitPicker.selectItem(at: 0)
            settings.saveButton.performClick(nil)
            expect(timer.view.dailyTargetMinutes == 30, "Save takes a number that Return was never pressed on: \(timer.view.dailyTargetMinutes)")
            expect(SettingsPanel.open == nil, "and closes the window")
            SettingsPanel.show(for: timer.view)
            settings.targetCheck.performClick(nil)
            expect(timer.view.dailyTargetMinutes == 0 && !settings.targetField.isEnabled, "switched off again")
        }
    }

    suite("Picking up where it left off") {
        test("a run that was going carries on with the sand it had left", serial: true) {
            let timer = TimerHarness(minutes: 5)
            let note = TimerState(minutes: 5, started: Date().addingTimeInterval(-90), runningUntil: Date().addingTimeInterval(120),
                                  pausedWith: nil, updated: Date()).stored
            timer.view.restoreSession(from: note)
            expect(timer.isRunning, "running again")
            let left = timer.view.secondsLeft
            expect(abs(left - 120) < 2, "with about two minutes to go, got \(left)")
        }
        test("a paused run is laid down again with what it had left", serial: true) {
            let timer = TimerHarness(minutes: 5)
            let note = TimerState(minutes: 5, started: Date().addingTimeInterval(-200), runningUntil: nil,
                                  pausedWith: 100, updated: Date()).stored
            timer.view.restoreSession(from: note)
            timer.settle()
            expect(timer.isPaused, "paused")
            let left = timer.view.secondsLeft
            expect(abs(left - 100) < 2, "with 100 seconds left, got \(left)")
        }
        test("a run that finished while the app was away stays finished", serial: true) {
            let timer = TimerHarness(minutes: 5)
            let note = TimerState(minutes: 5, started: Date().addingTimeInterval(-400), runningUntil: Date().addingTimeInterval(-30),
                                  pausedWith: nil, updated: Date()).stored
            timer.view.restoreSession(from: note)
            expect(!timer.isRunning && !timer.isPaused, "nothing to pick up")
            timer.view.restoreSession(from: nil)
            expect(!timer.isRunning && !timer.isPaused, "and nothing written down means nothing to pick up")
        }
        test("a note written for a different length is left alone", serial: true) {
            let timer = TimerHarness(minutes: 5)
            let note = TimerState(minutes: 25, started: Date(), runningUntil: Date().addingTimeInterval(600), pausedWith: nil, updated: Date()).stored
            timer.view.restoreSession(from: note)
            expect(!timer.isRunning, "it isn't this timer's run")
        }
        test("the size chosen last time is the size it starts at") {
            let defaults = try require(UserDefaults(suiteName: "sand-timer-tests"), "a scratch settings domain")
            defaults.removeObject(forKey: "size")
            expect(HourglassView.savedSizeIndex(defaults) == HourglassView.mediumSizeIndex, "Medium to begin with")
            defaults.set(2, forKey: "size")
            expect(HourglassView.savedSizeIndex(defaults) == 2, "Large, once chosen")
            defaults.set(9, forKey: "size")
            expect(HourglassView.savedSizeIndex(defaults) == HourglassView.mediumSizeIndex, "a size that doesn't exist falls back to Medium")
            defaults.removeObject(forKey: "size")
        }
    }

    // Projects are one list per Mac, like the settings, so these run on their own.
    suite("Projects") {
        func withProjects(_ timer: TimerHarness, _ body: () throws -> Void) rethrows {
            let before = timer.view.projects, active = timer.view.activeProjectID
            defer { timer.view.updateProjects(before); timer.view.switchProject(to: active) }
            timer.view.updateProjects(ProjectList(all: [Project(id: "t-a", name: "Client A", color: "#2876E2"),
                                                        Project(id: "t-b", name: "Writing", color: "#E8833A"),
                                                        Project(id: "t-c", name: "Reading", color: "#34BEA6", shakes: false)]))
            timer.view.switchProject(to: nil)
            try body()
        }

        test("the sand takes the colour of the project that's on", serial: true) {
            let timer = TimerHarness()
            try withProjects(timer) {
                let plain = timer.view.theme.sand.hexString
                timer.view.switchProject(to: "t-b")
                expect(timer.view.theme.sand.hexString == "#E8833A", "got \(timer.view.theme.sand.hexString)")
                timer.view.switchProject(to: nil)
                expect(timer.view.theme.sand.hexString == plain, "and back to the Appearance colour with none")
            }
        }
        test("switching mid-run splits the run where it happened", serial: true) {
            let timer = TimerHarness()
            try withProjects(timer) {
                let log = { timer.view.statistics.log.days[SandLog.dayKey(Date())]?.byProject ?? [:] }
                if timer.view.oneThingAtATime { timer.view.oneThingToggled() }
                defer { if !timer.view.oneThingAtATime { timer.view.oneThingToggled() } }
                let a0 = log()["t-a"]?.seconds ?? 0, b0 = log()["t-b"]?.seconds ?? 0
                timer.view.switchProject(to: "t-a")
                timer.click(); timer.run(1.5)
                timer.view.switchProject(to: "t-b")
                timer.run(1.0)
                timer.menu("pauseClicked"); timer.run(0.4)
                let a = (log()["t-a"]?.seconds ?? 0) - a0, b = (log()["t-b"]?.seconds ?? 0) - b0
                expect(a > 1.0 && a < 2.2, "about a second and a half on Client A, got \(a)")
                expect(b > 0.6 && b < 1.6, "about a second on Writing, got \(b)")
            }
        }
        test("the menu lists the projects in use and ticks the one that's on", serial: true) {
            let timer = TimerHarness()
            try withProjects(timer) {
                var list = timer.view.projects
                list.all[2].archived = true
                timer.view.updateProjects(list)
                timer.view.switchProject(to: "t-b")
                let item = try require(timer.view.makeMenu().items.first { $0.title.hasPrefix("Project") }, "the Project menu")
                expect(item.title == "Project: Writing", "got \(item.title)")
                let titles = item.submenu?.items.map(\.title) ?? []
                expect(titles.prefix(2) == ["Client A", "Writing"] && !titles.contains("Reading"), "got \(titles)")
                expect(titles.contains("No project") && titles.contains("Manage Projects…"), "got \(titles)")
                expect(item.submenu?.items.first { $0.title == "Writing" }?.state == .on)
                let clientA = try require(item.submenu?.items.first { $0.title == "Client A" }, "Client A")
                _ = (clientA.target as? NSObject)?.perform(clientA.action, with: clientA)
                expect(timer.view.activeProjectID == "t-a", "picking one switches to it")
            }
        }
        test("shaking the timer moves to the next project ticked for it, and names it on the top cap", serial: true) {
            let timer = TimerHarness()
            try withProjects(timer) {
                timer.view.switchProject(to: "t-a")
                timer.grabBody()
                timer.shakeSideways(strokes: 5)
                timer.releaseTopCap()
                expect(timer.view.activeProjectID == "t-b", "on to Writing, got \(timer.view.activeProjectID ?? "none")")
                expect(timer.view.shownProjectName == "Writing", "its name is on the top cap")
                timer.settle()
                timer.grabBody()
                timer.shakeSideways(strokes: 5)
                timer.releaseTopCap()
                expect(timer.view.activeProjectID == "t-a", "and round again, skipping Reading")
            }
        }
        test("with One Thing at a Time, the project stays put for the whole session", serial: true) {
            let timer = TimerHarness(minutes: 5)
            try withProjects(timer) {
                if !timer.view.oneThingAtATime { timer.view.oneThingToggled() }
                timer.view.switchProject(to: "t-a")
                timer.click(); timer.run(1.0)
                expect(!timer.view.canSwitchProject, "not while the sand runs")
                timer.view.switchProject(to: "t-b")
                expect(timer.view.activeProjectID == "t-a", "a switch mid-session is declined")
                let item = try require(timer.view.makeMenu().items.first { $0.title.hasPrefix("Project") }?.submenu, "the Project menu")
                expect(item.items.first?.title == "End the session to switch", "got \(item.items.first?.title ?? "")")
                expect(item.items.first { $0.title == "Writing" }?.isEnabled == false, "the projects wait")
                expect(item.items.first { $0.title == "No project" }?.isEnabled == false)
                let end = try require(item.items.first { $0.title == "End Session" }, "End Session, right there")
                expect(end.isEnabled)
                timer.menu("pauseClicked"); timer.settle()
                expect(!timer.view.canSwitchProject, "nor while it's paused: the session isn't over")
                timer.grabBody(); timer.shakeSideways(strokes: 5); timer.releaseTopCap(); timer.settle()
                expect(timer.view.activeProjectID == "t-a", "and a shake mid-session changes nothing")
                // Ending the session on purpose opens the projects again.
                _ = (end.target as? NSObject)?.perform(end.action, with: end)
                timer.settle()
                expect(!timer.isRunning && !timer.isPaused, "the session is over")
                let after = try require(timer.view.makeMenu().items.first { $0.title.hasPrefix("Project") }?.submenu, "the Project menu")
                expect(!after.items.contains { $0.title == "End Session" }, "nothing to end now")
                let writing = try require(after.items.first { $0.title == "Writing" }, "Writing")
                expect(writing.isEnabled)
                _ = (writing.target as? NSObject)?.perform(writing.action, with: writing)
                expect(timer.view.activeProjectID == "t-b", "and the switch goes through")
                timer.click(); timer.settle()
                timer.menu("restartClicked"); timer.settle()
                timer.view.oneThingToggled()
                expect(timer.view.canSwitchProject, "turned off, it can change at any time")
                timer.view.oneThingToggled()
                var list = timer.view.projects
                list.all[1].archived = true  // Writing, the one that's on
                timer.view.updateProjects(list)
                expect(timer.view.activeProjectID == nil, "removing the project that's on still takes it away")
            }
        }
        test("the project's name comes forward while the pointer rests on the timer", serial: true) {
            let timer = TimerHarness()
            try withProjects(timer) {
                timer.view.switchProject(to: "t-a")
                expect(!timer.view.projectNameEmphasised, "faint to begin with")
                timer.view.hoverTimer(true); timer.run(0.4)
                expect(timer.view.projectNameEmphasised, "readable once the pointer is on the timer")
                timer.view.hoverTimer(false); timer.run(0.4)
                expect(!timer.view.projectNameEmphasised, "and faint again once it leaves")
            }
        }
        test("carrying the timer about doesn't switch project", serial: true) {
            let timer = TimerHarness()
            try withProjects(timer) {
                timer.view.switchProject(to: "t-a")
                timer.grabBody()
                timer.moveTopCap(by: CGVector(dx: 200, dy: 60), steps: 20)
                timer.moveTopCap(by: CGVector(dx: -150, dy: 0), steps: 20)
                timer.releaseTopCap()
                expect(timer.view.activeProjectID == "t-a")
            }
        }
        test("Settings adds, renames, recolours and removes projects, and the time stays with its id", serial: true) {
            let timer = TimerHarness()
            try withProjects(timer) {
                SettingsPanel.show(for: timer.view)
                defer { SettingsPanel.open?.close() }
                let settings = try require(SettingsPanel.open?.settings, "the window")
                expect(Set(settings.projectRows.keys) == ["t-a", "t-b", "t-c"], "a row each: \(settings.projectRows.keys)")
                settings.addProjectButton.performClick(nil)
                expect(timer.view.projects.visible.count == 4 && settings.projectRows.count == 4, "a fourth")
                let row = try require(settings.projectRows["t-a"], "Client A's row")
                row.name.stringValue = "Client Alpha"
                settings.projectRenamed(row.name)
                row.color.color = NSColor(hex: "#FF0000")!
                settings.projectColorChanged(row.color)
                expect(timer.view.projects.project("t-a")?.name == "Client Alpha" && timer.view.projects.project("t-a")?.color == "#FF0000")
                timer.view.switchProject(to: "t-b")
                settings.projectRemoved(try require(settings.projectRows["t-b"], "Writing's row").remove)
                expect(timer.view.projects.project("t-b")?.archived == true, "kept, but removed")
                expect(timer.view.activeProjectID == nil, "removing the project that's on switches to none")
                expect(settings.projectRows["t-b"] == nil, "and its row goes")

                // A name still being typed when Add Project is clicked is kept, not thrown back to what it was.
                let reading = try require(settings.projectRows["t-c"], "Reading's row")
                SettingsPanel.open?.makeFirstResponder(reading.name)
                reading.name.currentEditor()?.string = "Deep reading"
                settings.addProjectButton.performClick(nil)
                expect(timer.view.projects.project("t-c")?.name == "Deep reading", "got \(timer.view.projects.project("t-c")?.name ?? "")")
                expect(settings.projectRows["t-c"]?.name.stringValue == "Deep reading", "and the field still says so")
            }
        }
    }

    suite("Update checks") {
        test("Check for Updates is a setting, and it can be turned off and on again") {
            let timer = TimerHarness()
            let wasOn = UpdateChecker.shared.isEnabled
            defer { UpdateChecker.shared.setEnabled(wasOn) }
            UpdateChecker.shared.setEnabled(true)
            SettingsPanel.show(for: timer.view)
            defer { SettingsPanel.open?.close() }
            let box = try require(SettingsPanel.open?.settings.switches["Check for Updates"], "the setting")
            expect(box.state == .on, "ticked while the app looks for updates")
            box.performClick(nil)
            expect(!UpdateChecker.shared.isEnabled, "turned off")
            expect(box.state == .off, "and the tick goes with it")
            expect(UpdateChecker.shared.available == nil, "nothing is offered while the check is off")
            timer.menu("updateChecksToggled")
            expect(UpdateChecker.shared.isEnabled, "and back on")
        }
    }

    // What the timer publishes about itself, and whether it takes commands, are one setting per Mac — so these
    // run on their own rather than beside the other test processes, which share them.
    suite("Ending a session") {
        test("End Session keeps the time run but doesn't count a finished timer, and the timer waits", serial: true) {
            let timer = TimerHarness(minutes: 5)
            let today = { timer.view.statistics.log.days[SandLog.dayKey(Date())] ?? SandLog.Day() }
            let before = today()
            expect(!timer.view.makeMenu().items.contains { $0.title == "End Session" }, "nothing to end before it starts")
            timer.click(); timer.run(1.5)
            expect(timer.view.makeMenu().items.contains { $0.title == "End Session" }, "offered while the sand runs")
            timer.menu("endClicked"); timer.run(0.9)
            expect(!timer.isRunning && !timer.isPaused, "ended: neither running nor paused")
            let after = today()
            expect(after.seconds - before.seconds > 1.0, "the time run is kept: \(after.seconds - before.seconds)")
            expect(after.finished == before.finished, "but it isn't a finished timer")
            timer.run(0.5)
            expect(today().finished == before.finished, "not even a moment later")
            expect(timer.view.menuBarTime == nil, "nothing left to count down")
            timer.click(); timer.run(0.8)
            expect(timer.isRunning, "a click starts the next one")
            timer.menu("endClicked"); timer.settle()
        }
        test("a paused session is stood up and ended, and then the project can change", serial: true) {
            let timer = TimerHarness(minutes: 5)
            let before = timer.view.projects, active = timer.view.activeProjectID
            defer { timer.view.updateProjects(before); timer.view.switchProject(to: active) }
            timer.view.updateProjects(ProjectList(all: [Project(id: "e-a", name: "A", color: "#2876E2"), Project(id: "e-b", name: "B", color: "#E8833A")]))
            timer.view.switchProject(to: "e-a")
            if !timer.view.oneThingAtATime { timer.view.oneThingToggled() }
            timer.click(); timer.run(1.0)
            timer.menu("pauseClicked"); timer.settle()
            expect(!timer.view.canSwitchProject, "held while paused")
            timer.menu("endClicked"); timer.settle()
            expect(!timer.isRunning && !timer.isPaused, "ended")
            expect(timer.view.canSwitchProject, "and free to change project")
            timer.view.switchProject(to: "e-b")
            expect(timer.view.activeProjectID == "e-b")
        }
    }

    suite("Control from outside") {
        test("a command starts a session of the length it asked for, and says so where others can read it", serial: true) {
            let timer = TimerHarness(minutes: 25)
            timer.view.startSession(minutes: 7)
            timer.settle(); timer.run(0.5)
            expect(timer.isRunning, "a command starts it running")
            func published() -> TimerState { TimerState.load(stored: UserDefaults.standard.dictionary(forKey: TimerState.key)) }
            let running = published()
            expect(running.minutes == 7, "the length it was asked for: \(running.minutes)")
            expect(running.isRunning(at: Date()), "written down as running")
            let left = running.remaining(at: Date())
            expect(left > 400 && left <= 420, "with the time left, about seven minutes: \(left)")

            let began = try require(running.started, "when the run began")
            expect(abs(began.timeIntervalSinceNow) < 5, "which was just now: \(began)")

            timer.view.pauseSession(); timer.settle()
            let paused = published()
            expect(paused.isPaused(at: Date()) && !paused.isRunning(at: Date()), "written down as paused: \(paused)")
            expect(paused.started == began, "a pause doesn't restart the run: \(String(describing: paused.started))")
            timer.view.resumeSession(); timer.settle(); timer.run(0.3)
            let resumed = published()
            expect(resumed.isRunning(at: Date()), "and running again")
            expect(resumed.started == began, "nor does standing it back up: \(String(describing: resumed.started))")
        }
        test("a command sent while the glass is still turning waits, rather than being lost", serial: true) {
            let timer = TimerHarness(minutes: 25)
            timer.view.startSession(minutes: nil)
            timer.view.pauseSession()          // straight away, while the flip is still turning
            timer.view.resumeSession()         // and again, while it is tipping over to pause
            timer.settle(minimum: 1.5); timer.run(1.0)
            expect(timer.isRunning, "the last word wins, once the glass has settled")
            let state = TimerState.load(stored: UserDefaults.standard.dictionary(forKey: TimerState.key))
            expect(state.isRunning(at: Date()), "and it is written down as running: \(state)")
        }
        test("an end command ends the session, and says so", serial: true) {
            let timer = TimerHarness(minutes: 25)
            timer.view.startSession(minutes: 5)
            timer.settle(); timer.run(0.5)
            timer.view.endSession()
            timer.run(0.9)
            expect(!timer.isRunning && !timer.isPaused, "ended")
            let state = TimerState.load(stored: UserDefaults.standard.dictionary(forKey: TimerState.key))
            expect(!state.isRunning(at: Date()) && !state.isPaused(at: Date()) && state.started == nil, "written down as waiting: \(state)")
        }
        test("commands are refused until the menu allows them", serial: true) {
            let timer = TimerHarness()
            let wasAllowed = timer.view.allowsControl
            defer { if timer.view.allowsControl != wasAllowed { timer.menu("controlToggled") } }
            if timer.view.allowsControl { timer.menu("controlToggled") }
            expect(!timer.view.allowsControl, "off to begin with")
            SettingsPanel.show(for: timer.view)
            defer { SettingsPanel.open?.close() }
            let box = try require(SettingsPanel.open?.settings.switches["Control from Claude & Shortcuts"], "the setting")
            expect(box.state == .off, "and the settings say so")
            box.performClick(nil)
            expect(timer.view.allowsControl && UserDefaults.standard.bool(forKey: TimerState.controlKey), "turned on and remembered")
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
        test("a running timer at the largest size stays light on the CPU", serial: true) {
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
