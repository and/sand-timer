import Foundation

func updateTests() {
    suite("Update checks") {
        test("a release is newer only when its version really is") {
            expect(Updates.isNewer("v1.5.0", than: "1.4.1"), "a later minor version")
            expect(Updates.isNewer("1.4.2", than: "1.4.1") && Updates.isNewer("2.0", than: "1.9.9"))
            expect(Updates.isNewer("1.10.0", than: "1.9.0"), "ten comes after nine, not before it")
            expect(Updates.isNewer("1.4.1", than: "1.4"), "a patch on top of a plain version")
            expect(!Updates.isNewer("1.4.1", than: "v1.4.1"), "the same version, tagged with a v")
            expect(!Updates.isNewer("1.4.0", than: "1.4.1") && !Updates.isNewer("1.4", than: "1.4.0"))
            expect(!Updates.isNewer("", than: "1.4.1") && !Updates.isNewer("nightly", than: "1.4.1"), "nothing to compare")
        }

        test("the version is shown the way people write it") {
            expect(Updates.label("v1.4.1") == "1.4.1" && Updates.label("1.4.1") == "1.4.1")
        }

        test("GitHub's reply is read for the tag and the page, and nonsense is ignored") {
            let reply = """
                {"tag_name": "v1.5.0", "name": "Sand Timer 1.5.0",
                 "html_url": "https://github.com/and/sand-timer/releases/tag/v1.5.0"}
                """
            let found = try require(Updates.release(from: Data(reply.utf8)), "the release")
            expect(found.version == "v1.5.0", "got \(found.version)")
            expect(found.page.absoluteString == "https://github.com/and/sand-timer/releases/tag/v1.5.0")

            let noPage = try require(Updates.release(from: Data(#"{"tag_name": "v1.5.0"}"#.utf8)), "a release with no page")
            expect(noPage.page == Updates.releasesPage, "falls back to the releases page")
            expect(Updates.release(from: Data(#"{"message": "Not Found"}"#.utf8)) == nil, "no tag, no release")
            expect(Updates.release(from: Data(#"{"tag_name": "nightly"}"#.utf8)) == nil, "a tag with no version in it")
            expect(Updates.release(from: Data("<html>whoops</html>".utf8)) == nil, "not even JSON")
        }

        test("it looks once a day, and again if the clock is set back") {
            let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
            expect(Updates.isDue(lastChecked: nil, at: now), "never looked before")
            expect(!Updates.isDue(lastChecked: now.addingTimeInterval(-3600), at: now), "an hour ago is too soon")
            expect(Updates.isDue(lastChecked: now.addingTimeInterval(-Updates.interval), at: now), "a day later")
            expect(Updates.isDue(lastChecked: now.addingTimeInterval(60), at: now), "a check dated in the future")
        }
    }
}
