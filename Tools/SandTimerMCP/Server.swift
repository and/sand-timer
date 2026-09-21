import Foundation

/// What Sand Timer's MCP server answers, as plain request in, response out — no reading or writing, so the whole
/// conversation can be tested. A notification (a request with no id) gets nil: by the protocol, no reply at all.
///
/// Everything here only reads the record. Nothing the server offers can start, stop or alter the timer.
enum SandTimerMCP {
    static let name = "sand-timer"
    static let version = "1.5.1"
    /// The version of the protocol spoken when the client doesn't name one.
    static let protocolVersion = "2025-06-18"
    /// The record is written in batches while the sand runs, so the last few seconds of a running timer are not in
    /// it yet. Said plainly in the tool descriptions, so an answer doesn't claim more precision than there is.
    static let freshness = "Time is written out every half minute or so, so a timer running right now may be short by up to that much."

    static func respond(to request: [String: Any], log: () -> SandLog, now: Date,
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
            return reply(id, call(tool, arguments: arguments, log: log, now: now, calendar: calendar))
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
        ]
    }

    // MARK: Answering

    private static func call(_ tool: String, arguments: [String: Any], log: () -> SandLog, now: Date,
                             calendar: Calendar) -> [String: Any] {
        let log = log()
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
