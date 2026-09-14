import Foundation

/// A tiny test runner shared by the unit and integration suites (run with `./build.sh test`).
/// Pass a word as the first argument to run only the tests whose suite or name contains it.
enum TestKit {
    static var passed = 0
    static var failed: [String] = []
    static var skippedByFilter = 0
    static var currentSuite = ""
    static var currentFailures: [String] = []
    static let filter = CommandLine.arguments.dropFirst().first.map { $0.lowercased() }.flatMap { $0.isEmpty ? nil : $0 }

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

func test(_ name: String, _ body: () throws -> Void) {
    if let filter = TestKit.filter, !"\(TestKit.currentSuite) \(name)".lowercased().contains(filter) {
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
