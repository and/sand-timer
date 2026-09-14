import Foundation

private let t0 = Date(timeIntervalSinceReferenceDate: 0)
private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

func clockTests() {
    suite("Clock") {
        test("a new timer waits with all its sand at the bottom") {
            let clock = SandClock(duration: 100)
            expect(clock.progress(at: t0) == 1)
            expect(!clock.isRunning(at: t0) && !clock.isPaused(at: t0))
        }
        test("flipping starts it and sand falls steadily") {
            var clock = SandClock(duration: 100)
            clock.flip(at: t0)
            expect(clock.progress(at: t0) == 0)
            expect(near(clock.progress(at: at(25)), 0.25))
            expect(near(clock.remaining(at: at(25)), 75))
            expect(clock.isRunning(at: at(25)))
        }
        test("flipping mid-run swaps what's left with what has fallen") {
            var clock = SandClock(duration: 100)
            clock.flip(at: t0)
            clock.flip(at: at(30))
            expect(near(clock.progress(at: at(30)), 0.7))
            expect(near(clock.progress(at: at(60)), 1))
            expect(!clock.isRunning(at: at(60)))
            expect(clock.progress(at: at(500)) == 1, "progress stops at 1")
        }
        test("flipping a full top empties it at once") {
            var clock = SandClock(duration: 100)
            clock.restart(at: t0)
            clock.flip(at: t0)
            expect(clock.progress(at: t0) == 1 && !clock.isRunning(at: t0))
        }
        test("pause freezes the sand and resume carries on") {
            var clock = SandClock(duration: 100)
            clock.restart(at: t0)
            clock.pause(at: at(40))
            expect(clock.isPaused(at: at(90)))
            expect(near(clock.progress(at: at(90)), 0.4))
            clock.resume(at: at(90))
            clock.resume(at: at(95))  // no effect while running
            expect(near(clock.progress(at: at(100)), 0.5))
        }
        test("changing the duration keeps the sand where it is") {
            var clock = SandClock(duration: 100)
            clock.restart(at: t0)
            clock.setDuration(200, at: at(50))
            expect(near(clock.progress(at: at(50)), 0.5))
            expect(near(clock.progress(at: at(150)), 1))
        }
        test("finish time follows flips, pauses and restarts") {
            var clock = SandClock(duration: 100)
            clock.restart(at: t0)
            expect(clock.finishTime == at(100))
            clock.pause(at: at(30))
            clock.resume(at: at(40))
            expect(clock.finishTime == at(110), "shifted by the pause")
            clock.flip(at: at(60))
            expect(clock.finishTime == at(110))
            clock.pause(at: at(70))
            expect(clock.finishTime == nil)
        }
    }

    suite("Base display label") {
        test("counts down in minutes and seconds") {
            let thirty = SandClock(duration: 1800)
            expect(thirty.remainingLabel(progress: 0) == "30:00")
            expect(thirty.remainingLabel(progress: 0.5) == "15:00")
            expect(thirty.remainingLabel(progress: 61.0 / 1800) == "28:59")
            expect(SandClock(duration: 3600).remainingLabel(progress: 0) == "60:00")
        }
        test("shows the full duration once the sand has run out") {
            let thirty = SandClock(duration: 1800)
            expect(thirty.remainingLabel(progress: 0.9999) == "0:01")
            expect(thirty.remainingLabel(progress: 1) == "30:00")
        }
        test("a short timer flipped mid-run shows the right time") {
            var two = SandClock(duration: 120)
            two.restart(at: t0)
            expect(two.remainingLabel(progress: two.progress(at: at(50))) == "1:10")
            two.flip(at: at(50))
            expect(two.remainingLabel(progress: two.progress(at: at(50))) == "0:50")
            expect(two.remainingLabel(progress: two.progress(at: at(99.5))) == "0:01")
            expect(two.remainingLabel(progress: two.progress(at: at(100))) == "2:00")
        }
    }
}
