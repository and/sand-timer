import Foundation

/// What Sand Timer's MCP server answers, as plain request in, response out — no reading or writing, so the whole
/// conversation can be tested. A notification (a request with no id) gets nil: by the protocol, no reply at all.
///
/// Everything here only reads the record. Nothing the server offers can start, stop or alter the timer.
/// Why a command didn't get through, in words the person asking can act on.
struct Unreachable: Error {
    let reason: String
}

/// Everything the server needs from the world outside it, handed in so the whole conversation can be tested
/// without a timer, a record or a Mac to run them on.
struct SandTimerAccess {
    /// The record of what has already happened.
    var log: () -> SandLog
    /// What the timer is doing right now, as the app last published it.
    var state: () -> TimerState
    /// Whether the app is set to accept commands at all.
    var allowsControl: () -> Bool
    /// Sends a command to the app and waits for it to say what it did.
    var send: (_ command: String, _ minutes: Int?) -> Result<TimerState, Unreachable>
    /// The moment it is now. Asked for again after a command, which can take a second or two while the app starts
    /// up, so the time left is counted from when the answer came back rather than when the question arrived.
    var moment: () -> Date = { Date() }
}

enum SandTimerMCP {
    static let name = "sand-timer"
    static let version = "1.5.1"
    /// The version of the protocol spoken when the client doesn't name one.
    static let protocolVersion = "2025-06-18"
    /// The record is written in batches while the sand runs, so the last few seconds of a running timer are not in
    /// it yet. Said plainly in the tool descriptions, so an answer doesn't claim more precision than there is.
    static let freshness = "Time is written out every half minute or so, so a timer running right now may be short by up to that much."

    /// What to say when the timer is there but not listening.
    static let controlOff = """
        Sand Timer isn't accepting commands. Right-click the timer and turn on \
        "Control from Claude & Shortcuts", then try again.
        """

    static func respond(to request: [String: Any], access: SandTimerAccess, now: Date,
                        calendar: Calendar = .current) -> [String: Any]? {
        guard let id = request["id"], !(id is NSNull) else { return nil }
        switch request["method"] as? String ?? "" {
        case "initialize":
            let asked = ((request["params"] as? [String: Any])?["protocolVersion"] as? String) ?? protocolVersion
            return reply(id, ["protocolVersion": asked,
                              "capabilities": ["tools": [String: Any]()],
                              "serverInfo": ["name": name, "version": version],
                              "instructions": "Reads how long the Sand Timer on this Mac has run, day by day. \(freshness)"])
        case "ping":
            return reply(id, [String: Any]())
        case "tools/list":
            return reply(id, ["tools": tools])
        case "tools/call":
            let parameters = request["params"] as? [String: Any] ?? [:]
            let arguments = parameters["arguments"] as? [String: Any] ?? [:]
            guard let tool = parameters["name"] as? String else {
                return reply(id, text("No tool was named.", isError: true))
            }
            return reply(id, call(tool, arguments: arguments, access: access, now: now, calendar: calendar))
        default:
            return ["jsonrpc": "2.0", "id": id,
                    "error": ["code": -32601, "message": "No method called \(request["method"] as? String ?? "")"]]
        }
    }

    // MARK: What it offers

    static var tools: [[String: Any]] {
        func schema(_ properties: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": properties, "additionalProperties": false]
        }
        let period: [String: Any] = ["type": "string", "enum": ["daily", "weekly", "monthly", "yearly"],
                                     "description": "How to group the time. Daily if not given."]
        return [
            ["name": "sand_timer_stats",
             "description": """
                How long the sand ran and how many timers ran all the way out, grouped by day, week, month or year, \
                for every span since the first day recorded. Spans where the timer went unused are included, with \
                zeros. \(freshness)
                """,
             "inputSchema": schema(["period": period,
                                    "limit": ["type": "integer", "minimum": 1,
                                              "description": "Only the most recent spans, oldest first still. All of them if not given."]])],
            ["name": "sand_timer_today",
             "description": "How long the sand has run today, and how many timers finished. \(freshness)",
             "inputSchema": schema([:])],
            ["name": "sand_timer_days",
             "description": """
                The record day by day between two dates, written yyyy-MM-dd. Days the timer went unused are left out. \
                \(freshness)
                """,
             "inputSchema": schema(["from": ["type": "string", "description": "The first day, yyyy-MM-dd. The first day recorded if not given."],
                                    "to": ["type": "string", "description": "The last day, yyyy-MM-dd. Today if not given."]])],
            ["name": "sand_timer_csv",
             "description": "The whole record as CSV, the same file the timer's Export button writes: Start, End, seconds, minutes, timers finished.",
             "inputSchema": schema(["period": period])],
            ["name": "sand_timer_status",
             "description": """
                What the timer is doing at this moment: running, paused or waiting to be flipped, how long it is set \
                for, how much sand is left, when this run began and when it will finish. Times are given as they are, \
                so there is no need to work them out from how long is left.
                """,
             "inputSchema": schema([:])],
            ["name": "sand_timer_start",
             "description": """
                Turns the timer over and starts it running, from a full head of sand. Give a length in minutes to \
                change how long it runs for, or leave that out to use the length it is set to already.
                """,
             "inputSchema": schema(["minutes": ["type": "integer", "minimum": 1, "maximum": 60,
                                                "description": "How long to run for, 1 to 60 minutes."]])],
            ["name": "sand_timer_pause",
             "description": "Pauses a running timer: it tips onto its side and the sand stops.",
             "inputSchema": schema([:])],
            ["name": "sand_timer_resume",
             "description": "Stands a paused timer back up and lets the sand run on from where it stopped.",
             "inputSchema": schema([:])],
        ]
    }

    // MARK: Answering

    private static func call(_ tool: String, arguments: [String: Any], access: SandTimerAccess, now: Date,
                             calendar: Calendar) -> [String: Any] {
        switch tool {
        case "sand_timer_status":
            return text(json(describe(access.state(), at: now)))
        case "sand_timer_start", "sand_timer_pause", "sand_timer_resume":
            guard access.allowsControl() else { return text(controlOff, isError: true) }
            let command = String(tool.dropFirst("sand_timer_".count))
            switch access.send(command, command == "start" ? arguments["minutes"] as? Int : nil) {
            case .success(let state): return text(json(describe(state, at: access.moment())))
            case .failure(let why): return text(why.reason, isError: true)
            }
        default:
            break
        }
        let log = access.log()
        let period = SandLog.Period.named(arguments["period"] as? String) ?? .daily
        switch tool {
        case "sand_timer_stats":
            var spans = log.allBuckets(period, at: now, calendar: calendar).map {
                span($0, period: period, now: now, calendar: calendar)
            }
            if let limit = arguments["limit"] as? Int, limit > 0, spans.count > limit { spans = Array(spans.suffix(limit)) }
            let all = log.allTime
            return text(json(["period": period.name.lowercased(), "spans": spans,
                              "total": ["seconds": seconds(all.seconds), "minutes": minutes(all.seconds),
                                        "label": SandLog.durationLabel(all.seconds), "timers": all.finished],
                              "since": log.firstDay(calendar: calendar).map { SandLog.dayKey($0, calendar: calendar) } ?? ""]))
        case "sand_timer_today":
            let today = log.days[SandLog.dayKey(now, calendar: calendar)] ?? SandLog.Day()
            return text(json(["date": SandLog.dayKey(now, calendar: calendar), "seconds": seconds(today.seconds),
                              "minutes": minutes(today.seconds), "label": SandLog.durationLabel(today.seconds),
                              "timers": today.finished]))
        case "sand_timer_days":
            let from = arguments["from"] as? String ?? ""
            let to = arguments["to"] as? String ?? SandLog.dayKey(now, calendar: calendar)
            let days = log.days.filter { $0.key >= from && $0.key <= to }.sorted { $0.key < $1.key }.map {
                ["date": $0.key, "seconds": seconds($0.value.seconds), "minutes": minutes($0.value.seconds),
                 "label": SandLog.durationLabel($0.value.seconds), "timers": $0.value.finished] as [String: Any]
            }
            return text(json(["from": from.isEmpty ? (days.first?["date"] as? String ?? to) : from, "to": to, "days": days]))
        case "sand_timer_csv":
            return text(log.csv(period, at: now, calendar: calendar))
        default:
            return text("Sand Timer has no tool called \(tool).", isError: true)
        }
    }

    /// What the timer is doing, as the MCP client sees it. The times are spelled out rather than left to be worked
    /// out from how long is left: a run that was paused and resumed began earlier than the last thing written down.
    private static func describe(_ state: TimerState, at now: Date) -> [String: Any] {
        let left = state.remaining(at: now)
        func moment(_ date: Date?) -> String {
            guard let date, date != .distantPast else { return "" }
            return ISO8601DateFormatter().string(from: date)
        }
        var described: [String: Any] = ["state": state.describe(at: now), "minutes": state.minutes,
                                        "remaining_seconds": seconds(left), "remaining": SandLog.durationLabel(left),
                                        "as_of": moment(state.updated)]
        if let started = state.started, state.isRunning(at: now) || state.isPaused(at: now) {
            described["started_at"] = moment(started)
            described["running_for_seconds"] = seconds(now.timeIntervalSince(started))
        }
        if state.isRunning(at: now) { described["finishes_at"] = moment(state.runningUntil) }
        return described
    }

    private static func span(_ bucket: SandLog.Bucket, period: SandLog.Period, now: Date,
                             calendar: Calendar) -> [String: Any] {
        ["start": SandLog.dayKey(bucket.start, calendar: calendar),
         "end": SandLog.dayKey(SandLog.lastDay(of: bucket.start, period: period, at: now, calendar: calendar), calendar: calendar),
         "seconds": seconds(bucket.seconds), "minutes": minutes(bucket.seconds),
         "label": SandLog.durationLabel(bucket.seconds), "timers": bucket.finished]
    }

    private static func seconds(_ value: TimeInterval) -> Int { Int(value.rounded()) }
    /// Minutes to one decimal place, as a decimal rather than a Double, so the JSON reads 56.6 and not
    /// 56.600000000000001.
    private static func minutes(_ value: TimeInterval) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.1f", value / 60))
    }

    private static func json(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    private static func text(_ body: String, isError: Bool = false) -> [String: Any] {
        var result: [String: Any] = ["content": [["type": "text", "text": body]]]
        if isError { result["isError"] = true }
        return result
    }

    private static func reply(_ id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }
}

extension SandLog.Period {
    /// The period a tool call asked for, by the name the tools advertise.
    static func named(_ name: String?) -> SandLog.Period? {
        guard let name = name?.lowercased() else { return nil }
        return allCases.first { $0.name.lowercased() == name }
    }
}
