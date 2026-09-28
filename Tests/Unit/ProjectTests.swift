import Foundation

func projectTests() {
    suite("Projects") {
        let a = Project(id: "a", name: "Client A", color: "#2876E2")
        let b = Project(id: "b", name: "Writing", color: "#E8833A")
        let c = Project(id: "c", name: "Reading", color: "#34BEA6", shakes: false)
        let gone = Project(id: "d", name: "Old", color: "#000000", archived: true)
        let list = ProjectList(all: [a, b, c, gone])

        test("shaking moves round the projects ticked for it, and only those") {
            expect(list.nextForShake(after: nil)?.id == "a", "from none, the first")
            expect(list.nextForShake(after: "a")?.id == "b")
            expect(list.nextForShake(after: "b")?.id == "a", "round again, past the one not ticked and the removed one")
            expect(list.nextForShake(after: "c")?.id == "a", "from one not ticked, the first that is")
            expect(ProjectList(all: [a]).nextForShake(after: "a") == nil, "nowhere else to go")
            expect(ProjectList(all: [c]).nextForShake(after: nil) == nil, "nothing ticked")
        }

        test("removed projects leave the menus but keep their names") {
            expect(list.visible.map(\.id) == ["a", "b", "c"])
            expect(list.name(of: "d") == "Old" && list.name(of: "") == "No project" && list.name(of: "zz") == "Unknown project")
        }

        test("the list survives a restart") {
            let defaults = try require(UserDefaults(suiteName: "sand-timer-tests"), "a scratch settings domain")
            defer { defaults.removeObject(forKey: ProjectList.key) }
            list.save(to: defaults)
            expect(ProjectList.load(from: defaults) == list)
            expect(ProjectList.load(stored: [["name": "no id"]]).all.isEmpty, "an entry without an id is skipped")
        }
    }

    suite("Shaking to switch") {
        func strokes(_ count: Int, speed: Double = 0.8, every: Double = 0.12) -> Int {
            var gesture = ShakeGesture(), fired = 0, t = 0.0
            for stroke in 0..<count {
                for _ in 0..<4 {
                    if gesture.feed(velocity: stroke % 2 == 0 ? speed : -speed, at: t) { fired += 1 }
                    t += every / 4
                }
            }
            return fired
        }
        test("three brisk reversals are a shake") { expect(strokes(4) == 1) }
        test("a long shake is one switch, not several") { expect(strokes(10) == 1) }
        test("slow waving isn't a shake") { expect(strokes(6, speed: 0.2) == 0) }
        test("reversals spread over seconds aren't a shake") { expect(strokes(6, every: 0.8) == 0) }
        test("a steady drag and a single jolt aren't either") {
            expect(strokes(1) == 0 && strokes(2) == 0)
        }
    }
}
