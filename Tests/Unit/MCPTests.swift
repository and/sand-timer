import Foundation

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.firstWeekday = 2
    return calendar
}()

private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth, hour: 12))!
}

private let now = day(2026, 9, 21)

/// A record with a little in it: a day last week, and two days this one.
private let record: SandLog = {
    var log = SandLog()
    log.add(seconds: 1500, finished: 1, on: day(2026, 9, 11), calendar: calendar)
    log.add(seconds: 3600, finished: 2, on: day(2026, 9, 20), calendar: calendar)
    log.add(seconds: 396, on: now, calendar: calendar)
    return log
}()

/// A timer standing there running, and a note of every command it was sent.
private final class FakeTimer {
    var allowsControl = true
    var state = TimerState(minutes: 25, started: now.addingTimeInterval(-600), runningUntil: now.addingTimeInterval(900),
                           updated: now)
    var sent: [(command: String, minutes: Int?)] = []
    var reachable = true

    func send(_ command: String, minutes: Int?) -> Result<TimerState, Unreachable> {
        sent.append((command, minutes))
        guard reachable else { return .failure(Unreachable(reason: "Sand Timer didn't answer.")) }
        switch command {
        case "start":
            let length = minutes ?? state.minutes
            state = TimerState(minutes: length, started: now, runningUntil: now.addingTimeInterval(Double(length * 60)), updated: now)
        case "pause":
            state = TimerState(minutes: state.minutes, started: state.started, pausedWith: state.remaining(at: now), updated: now)
        case "resume":
            state = TimerState(minutes: state.minutes, started: state.started,
                               runningUntil: now.addingTimeInterval(state.remaining(at: now)), updated: now)
        default: break
        }
        return .success(state)
    }

    var access: SandTimerAccess {
        SandTimerAccess(log: { record }, state: { self.state }, allowsControl: { self.allowsControl }, send: send,
                        moment: { now })
    }
}

private var timer = FakeTimer()

private func ask(_ method: String, _ parameters: [String: Any]? = nil, id: Any? = 1) -> [String: Any]? {
    var request: [String: Any] = ["jsonrpc": "2.0", "method": method]
    if let id { request["id"] = id }
    if let parameters { request["params"] = parameters }
    return SandTimerMCP.respond(to: request, access: timer.access, now: now, calendar: calendar)
}

/// The text a tool call answered with, and whether it was an error.
private func answer(_ tool: String, _ arguments: [String: Any] = [:]) throws -> (text: String, failed: Bool) {
    let response = try require(ask("tools/call", ["name": tool, "arguments": arguments]), "a response")
    let result = try require(response["result"] as? [String: Any], "a result")
    let content = try require((result["content"] as? [[String: Any]])?.first?["text"] as? String, "the text")
    return (content, result["isError"] as? Bool == true)
}

private func fields(_ text: String) throws -> [String: Any] {
    try require(try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], "JSON in the answer")
}

func mcpTests() {
    suite("MCP server") {
        test("it introduces itself, speaking the version the client asked for") {
            let response = try require(ask("initialize", ["protocolVersion": "2024-11-05"]), "a response")
            let result = try require(response["result"] as? [String: Any], "a result")
            expect(result["protocolVersion"] as? String == "2024-11-05", "answers in the version it was addressed in")
            expect((result["capabilities"] as? [String: Any])?["tools"] != nil, "it offers tools")
            expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "sand-timer")
            expect(response["jsonrpc"] as? String == "2.0" && response["id"] as? Int == 1)
        }

        test("a notification gets no reply, and an unknown method gets an error") {
            expect(ask("notifications/initialized", id: nil) == nil, "notifications are not answered")
            let response = try require(ask("resources/list"), "a response")
            let failure = try require(response["error"] as? [String: Any], "an error")
            expect(failure["code"] as? Int == -32601, "the method isn't there: \(failure)")
            expect(response["result"] == nil, "an error instead of a result")
        }

        test("every tool it lists can be called and says what it needs") {
            let response = try require(ask("tools/list"), "a response")
            let tools = try require((response["result"] as? [String: Any])?["tools"] as? [[String: Any]], "the tools")
            let names = tools.compactMap { $0["name"] as? String }
            expect(names == ["sand_timer_stats", "sand_timer_today", "sand_timer_days", "sand_timer_csv",
                             "sand_timer_status", "sand_timer_start", "sand_timer_pause", "sand_timer_resume"],
                   "got \(names)")
            for tool in tools {
                let name = tool["name"] as? String ?? "?"
                expect((tool["description"] as? String)?.isEmpty == false, "\(name) says what it does")
                expect((tool["inputSchema"] as? [String: Any])?["type"] as? String == "object", "\(name) has a schema")
            }
            for name in names {
                let reply = try answer(name)
                expect(!reply.failed, "\(name) answers: \(reply.text.prefix(80))")
            }
        }

        test("the statistics come back grouped, with the span still running ending today") {
            let weekly = try fields(try answer("sand_timer_stats", ["period": "weekly"]).text)
            expect(weekly["period"] as? String == "weekly")
            expect(weekly["since"] as? String == "2026-09-11", "counted from the first day recorded")
            let spans = try require(weekly["spans"] as? [[String: Any]], "the spans")
            // Weeks run Monday to Sunday here: the 11th is a Friday, the 20th the Sunday after it, today a Monday.
            expect(spans.count == 3, "three weeks, the last of them a day old: \(spans.count)")
            expect(spans[0]["start"] as? String == "2026-09-07" && spans[0]["end"] as? String == "2026-09-13")
            expect(spans[0]["seconds"] as? Int == 1500 && spans[0]["timers"] as? Int == 1)
            expect(spans[1]["seconds"] as? Int == 3600 && spans[1]["label"] as? String == "1h", "got \(spans[1])")
            expect(spans[2]["start"] as? String == "2026-09-21" && spans[2]["end"] as? String == "2026-09-21",
                   "the week that has just started ends today, not on the Sunday ahead: \(spans[2])")
            expect(spans[2]["seconds"] as? Int == 396, "got \(spans[2])")
            let total = try require(weekly["total"] as? [String: Any], "the total")
            expect(total["seconds"] as? Int == 5496 && total["timers"] as? Int == 3, "got \(total)")
        }

        test("only the last few spans when that is all that was asked for") {
            let spans = try require(try fields(try answer("sand_timer_stats", ["limit": 3]).text)["spans"] as? [[String: Any]],
                                    "the spans")
            expect(spans.count == 3, "got \(spans.count)")
            expect(spans.last?["start"] as? String == "2026-09-21", "ending with today")
        }

        test("today, and the days between two dates") {
            let today = try fields(try answer("sand_timer_today").text)
            expect(today["date"] as? String == "2026-09-21" && today["seconds"] as? Int == 396)
            expect(today["label"] as? String == "6m", "whole minutes, as the timer counts them: \(today)")
            expect((today["minutes"] as? NSNumber)?.doubleValue == 6.6, "and a decimal for adding up: \(today)")

            let days = try require(try fields(try answer("sand_timer_days", ["from": "2026-09-12"]).text)["days"] as? [[String: Any]],
                                   "the days")
            expect(days.count == 2, "the 11th is before the range: \(days.map { $0["date"] ?? "" })")
            expect(days.first?["date"] as? String == "2026-09-20", "oldest first")
            let narrow = try require(try fields(try answer("sand_timer_days", ["from": "2026-09-01", "to": "2026-09-11"]).text)["days"] as? [[String: Any]],
                                     "the days")
            expect(narrow.count == 1 && narrow[0]["timers"] as? Int == 1, "got \(narrow)")
        }

        test("the CSV is the same one the Export button writes") {
            let csv = try answer("sand_timer_csv", ["period": "monthly"]).text
            expect(csv == record.csv(.monthly, at: now, calendar: calendar), "got \(csv)")
        }

        test("it says what the timer is doing at this moment") {
            timer = FakeTimer()
            let status = try fields(try answer("sand_timer_status").text)
            expect(status["state"] as? String == "running", "got \(status)")
            expect(status["minutes"] as? Int == 25 && status["remaining_seconds"] as? Int == 900, "got \(status)")
            expect(status["remaining"] as? String == "15m")
            // Spelled out, so nobody has to guess the start from when the note was last written.
            expect(status["started_at"] as? String == "2026-09-21T11:50:00Z", "got \(status["started_at"] ?? "nothing")")
            expect(status["finishes_at"] as? String == "2026-09-21T12:15:00Z", "got \(status["finishes_at"] ?? "nothing")")
            expect(status["running_for_seconds"] as? Int == 600, "ten minutes in: \(status["running_for_seconds"] ?? "nothing")")

            timer.state = TimerState(minutes: 25, pausedWith: 61, updated: now)
            let paused = try fields(try answer("sand_timer_status").text)
            expect(paused["state"] as? String == "paused", "got \(paused)")
            timer.state = TimerState(minutes: 25, updated: now)
            let idle = try fields(try answer("sand_timer_status").text)
            expect(idle["state"] as? String == "waiting to be flipped" && idle["remaining_seconds"] as? Int == 0, "got \(idle)")
            expect(idle["started_at"] == nil && idle["finishes_at"] == nil, "nothing is running, so no times: \(idle)")
        }

        test("it can start, pause and resume the timer, and says what happened") {
            timer = FakeTimer()
            let started = try fields(try answer("sand_timer_start", ["minutes": 7]).text)
            expect(timer.sent.map(\.command) == ["start"] && timer.sent.first?.minutes == 7, "sent \(timer.sent)")
            expect(started["state"] as? String == "running" && started["minutes"] as? Int == 7, "got \(started)")

            let paused = try fields(try answer("sand_timer_pause").text)
            expect(paused["state"] as? String == "paused", "got \(paused)")
            expect(paused["started_at"] as? String == started["started_at"] as? String,
                   "a pause doesn't restart the run: \(paused["started_at"] ?? "nothing")")
            expect(paused["finishes_at"] == nil, "and nothing finishes while it is paused")
            expect(timer.sent.last?.minutes == nil, "pause carries no length")
            let resumed = try fields(try answer("sand_timer_resume").text)
            expect(resumed["state"] as? String == "running", "got \(resumed)")
            expect(timer.sent.map(\.command) == ["start", "pause", "resume"], "sent \(timer.sent.map(\.command))")
        }

        test("with control turned off it asks for it, and does not touch the timer") {
            timer = FakeTimer()
            timer.allowsControl = false
            let refused = try answer("sand_timer_start")
            expect(refused.failed, "marked as an error")
            expect(refused.text.contains("Control from Claude & Shortcuts"), "says how to allow it: \(refused.text)")
            expect(timer.sent.isEmpty, "and nothing was sent")
            let status = try answer("sand_timer_status"), today = try answer("sand_timer_today")
            expect(!status.failed && !today.failed, "reading is still fine")
        }

        test("a timer that cannot be reached is reported, not pretended about") {
            timer = FakeTimer()
            timer.reachable = false
            let lost = try answer("sand_timer_pause")
            expect(lost.failed && lost.text.contains("didn't answer"), "got \(lost)")
        }

        test("a tool it doesn't have is an error the client can see, not a crash") {
            let reply = try answer("sand_timer_delete_everything")
            expect(reply.failed, "marked as an error")
            expect(reply.text.contains("no tool called"), "and says so: \(reply.text)")
        }
    }
}
