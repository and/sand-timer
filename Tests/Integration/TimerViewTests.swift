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
            timer.click(); timer.run(1.0)
            let standing = timer.center
            expect(abs(timer.gapBelowTimer()) < 0.6, "standing on the ground: gap \(timer.gapBelowTimer())")
            timer.menu("pauseClicked"); timer.run(1.0)
            expect(abs(timer.gapBelowTimer()) < 0.6, "lying on the ground: gap \(timer.gapBelowTimer())")
            expect(abs((timer.center.y - timer.screen.minY) - 93 * timer.scale) < 1, "rests on its base discs")
            timer.click(); timer.run(1.2)
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
            expect(abs(innerAfterStandingUp - wallAfterStandingUp) < 2, "the layer starts level: \(innerAfterStandingUp) vs \(wallAfterStandingUp)")
            timer.run(3.0)  // new sand lands on it
            let wall = try require(timer.bottomSandHeight(atOffset: 50), "sand by the wall later")
            let inner = try require(timer.bottomSandHeight(atOffset: 12), "sand near the middle later")
            expect(wall >= wallAfterStandingUp - 1, "the layer by the wall doesn't sink: \(wallAfterStandingUp) → \(wall)")
            expect(inner > wall + 3, "a cone grows on top: \(inner) near the middle vs \(wall) by the wall")
        }
        test("knocked over, it falls toward the side with more room") {
            let right = TimerHarness(x: NSScreen.main!.visibleFrame.maxX - 300)
            right.click(); right.run(1.0)
            let before = right.center.x
            right.menu("pauseClicked"); right.run(1.0)
            expect(right.center.x < before - 100, "near the right wall it falls left")

            let left = TimerHarness(x: NSScreen.main!.visibleFrame.minX + 40)
            left.click(); left.run(1.0)
            let start = left.center.x
            left.menu("pauseClicked"); left.run(1.0)
            expect(left.center.x > start + 100, "near the left wall it falls right")
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
            func streamWidth(minutes: Int) -> Int {
                let view = HourglassView(minutes: minutes, themeIndex: 0, sizeIndex: 2)
                view.setPreview(progress: 0.3, running: true)
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: rep)
                // Rows through the upper part of the lower bulb, where only the stream crosses. Grains racing down it
                // widen single rows, so take the typical (median) width.
                let widths = stride(from: 30, through: 80, by: 5).map { units -> Int in
                    let row = Int((view.bounds.midY + CGFloat(units)) / view.bounds.height * CGFloat(rep.pixelsHigh))
                    return (0..<rep.pixelsWide).filter { x in
                        guard let c = rep.colorAt(x: x, y: row)?.usingColorSpace(.sRGB), c.alphaComponent > 0.3 else { return false }
                        return c.blueComponent > c.redComponent * 1.3 && c.blueComponent > c.greenComponent * 1.8
                    }.count
                }.sorted()
                return widths[widths.count / 2]
            }
            let one = streamWidth(minutes: 1), pomodoro = streamWidth(minutes: 25), hour = streamWidth(minutes: 60)
            expect(one > pomodoro && pomodoro > hour, "stream widths in pixels: 1 min \(one), 25 min \(pomodoro), 60 min \(hour)")
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
