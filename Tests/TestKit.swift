import Foundation

/// A tiny test runner shared by the unit and integration suites (run with `./build.sh test`).
/// Pass a word as the first argument to run only the tests whose suite or name contains it.
/// `--shard i/n` runs every nth test starting at i, which is how the integration suite is spread over several
/// processes at once; tests marked `serial` sit those out and are run afterwards, on their own, by `--serial-only`.
enum TestKit {
    static var passed = 0
    static var failed: [String] = []
    static var skippedByFilter = 0
    static var currentSuite = ""
    static var currentFailures: [String] = []
    /// Tests this process has looked at and could have run, which is what decides whose shard each one falls in.
    static var considered = 0
    static let options = parseArguments()
    static var filter: String? { options.filter }
    static var shard: (index: Int, count: Int)? { options.shard }
    static var serialOnly: Bool { options.serialOnly }

    /// Whether this process is the one to run the next test: it has to match the word asked for, and then either be
    /// a test that wants the machine to itself (run on its own, afterwards) or fall in this process's share.
    static func claims(_ label: String, serial: Bool) -> Bool {
        if let filter, !label.lowercased().contains(filter) { return false }
        if serialOnly { return serial }
        guard let shard else { return true }
        guard !serial else { return false }
        defer { considered += 1 }
        return considered % shard.count == shard.index
    }

    private static func parseArguments() -> (filter: String?, shard: (index: Int, count: Int)?, serialOnly: Bool) {
        var filter: String?, shard: (index: Int, count: Int)?
        var serialOnly = false
        let arguments = Array(CommandLine.arguments.dropFirst())
        var i = 0
        while i < arguments.count {
            let argument = arguments[i]
            if argument == "--serial-only" {
                serialOnly = true
                i += 1
            } else if argument == "--shard", i + 1 < arguments.count {
                let parts = arguments[i + 1].split(separator: "/").compactMap { Int($0) }
                if parts.count == 2, parts[1] > 0, parts[0] >= 0, parts[0] < parts[1] { shard = (parts[0], parts[1]) }
                i += 2
            } else {
                if filter == nil, !argument.isEmpty { filter = argument.lowercased() }
                i += 1
            }
        }
        return (filter, shard, serialOnly)
    }

    static func finish() -> Never {
        print("\n\(passed) passed, \(failed.count) failed" + (skippedByFilter > 0 ? ", \(skippedByFilter) filtered out" : ""))
        for name in failed { print("  ✗ \(name)") }
        exit(failed.isEmpty ? 0 : 1)
    }
}

func suite(_ name: String, _ body: () -> Void) {
    TestKit.currentSuite = name
    print("\n\(name)")
    body()
}

/// `serial: true` for a test that needs the machine to itself — the sound device, or a clear run at the CPU.
func test(_ name: String, serial: Bool = false, _ body: () throws -> Void) {
    guard TestKit.claims("\(TestKit.currentSuite) \(name)", serial: serial) else {
        TestKit.skippedByFilter += 1
        return
    }
    TestKit.currentFailures = []
    let start = Date()
    do { try body() } catch { TestKit.currentFailures.append("threw \(error)") }
    let time = Date().timeIntervalSince(start) >= 0.5 ? String(format: " (%.1fs)", Date().timeIntervalSince(start)) : ""
    if TestKit.currentFailures.isEmpty {
        TestKit.passed += 1
        print("  ✓ \(name)\(time)")
    } else {
        TestKit.failed.append("\(TestKit.currentSuite): \(name)")
        print("  ✗ \(name)\(time)")
        TestKit.currentFailures.forEach { print("      \($0)") }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "",
            file: StaticString = #fileID, line: UInt = #line) {
    if !condition() { TestKit.currentFailures.append("\(file):\(line) \(message())") }
}

struct Unexpected: Error, CustomStringConvertible { let description: String }

/// Unwraps a value the test needs, failing the test (instead of crashing) when it's missing.
func require<T>(_ value: T?, _ message: String, file: StaticString = #fileID, line: UInt = #line) throws -> T {
    guard let value else { throw Unexpected(description: "\(file):\(line) missing \(message)") }
    return value
}

func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }
func relNear(_ a: Double, _ b: Double, _ tolerance: Double = 1e-3) -> Bool { abs(a - b) <= tolerance * max(1, abs(b)) }
