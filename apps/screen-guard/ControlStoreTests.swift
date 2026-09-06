#if CONTROL_STORE_TESTS
import Foundation
import Darwin

@main
enum ControlStoreTests {
    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
    }

    private enum DeliberateFailure: Error { case sideEffect }

    static func main() {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--writer" {
            do {
                try runWriter(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
            } catch {
                print("WRITER FAIL: \(error)")
                exit(1)
            }
            return
        }

        let tests: [(String, () throws -> Void)] = [
            ("writes replace tokens and are visible to another store", testWriteAndRead),
            ("a mismatched token cannot execute the action", testMismatchedToken),
            ("a thrown action releases the lock for another process", testThrowReleasesLock),
            ("turn-on waits for an in-flight sleep action across processes", testCrossProcessOrdering)
        ]
        var failures = 0
        for (name, test) in tests {
            do {
                try test()
                print("PASS: \(name)")
            } catch {
                failures += 1
                print("FAIL: \(name): \(error)")
            }
        }
        print("\(tests.count - failures)/\(tests.count) ControlStore tests passed")
        if failures > 0 { exit(1) }
    }

    private static func testWriteAndRead() throws {
        try withDirectory { directory in
            let store = ScreenControlStore(directory: directory)
            let secondStore = ScreenControlStore(directory: directory)
            try require(!store.matches("session-A"), "missing state unexpectedly matches")
            try store.write("session-A")
            try require(secondStore.matches("session-A"), "another instance cannot read the written token")
            try store.write("session-B")
            try require(!secondStore.matches("session-A"), "replacement left the old token active")
            try require(secondStore.matches("session-B"), "replacement token is not visible")

            var actionCount = 0
            let performed = try secondStore.performIfMatches("session-B") { actionCount += 1 }
            try require(performed && actionCount == 1, "matching token must execute exactly once")
        }
    }

    private static func testMismatchedToken() throws {
        try withDirectory { directory in
            let store = ScreenControlStore(directory: directory)
            try store.write("current-session")
            var actionCount = 0
            let performed = try store.performIfMatches("stale-session") { actionCount += 1 }
            try require(!performed, "mismatched token was reported as performed")
            try require(actionCount == 0, "stale session executed a side effect")
            try require(store.matches("current-session"), "mismatch altered the active token")
        }
    }

    private static func testThrowReleasesLock() throws {
        try withDirectory { directory in
            let store = ScreenControlStore(directory: directory)
            try store.write("active-session")
            var didThrow = false
            do {
                _ = try store.performIfMatches("active-session") {
                    throw DeliberateFailure.sideEffect
                }
            } catch DeliberateFailure.sideEffect {
                didThrow = true
            }
            try require(didThrow, "the side effect error was swallowed")

            let writer = try launchWriter(directory: directory)
            defer { stopIfRunning(writer) }
            try waitForExit(writer)
            try require(store.matches("off"), "writer could not update state after the action threw")
            let events = try readEvents(directory)
            try require(events == ["write off completed", "on action"], "writer did not complete normally: \(events)")
        }
    }

    private static func testCrossProcessOrdering() throws {
        try withDirectory { directory in
            let store = ScreenControlStore(directory: directory)
            try store.write("active-session")
            var writer: Process?
            defer { if let writer { stopIfRunning(writer) } }

            let performed = try store.performIfMatches("active-session") {
                try appendEvent("sleep action started", directory: directory)
                writer = try launchWriter(directory: directory)
                try waitUntil("writer never reached its write attempt") {
                    FileManager.default.fileExists(atPath: directory.appendingPathComponent("writer-ready").path)
                }

                // The child has reached the write attempt. Keep the action active
                // long enough to expose an unlocked writer, then inspect evidence.
                Thread.sleep(forTimeInterval: 0.2)
                let events = try readEvents(directory)
                try require(events == ["sleep action started"], "writer passed an in-flight sleep action: \(events)")
                try require(writer?.isRunning == true, "writer finished before the sleep action")
                try appendEvent("sleep action completed", directory: directory)
            }

            try require(performed, "the matching sleep action was skipped")
            guard let writer else { throw TestFailure(description: "writer was not launched") }
            try waitForExit(writer)
            let events = try readEvents(directory)
            try require(events == [
                "sleep action started", "sleep action completed", "write off completed", "on action"
            ], "wrong cross-process action order: \(events)")
            try require(store.matches("off"), "turn-on did not leave the store disabled")

            var staleActionCount = 0
            let stalePerformed = try store.performIfMatches("active-session") { staleActionCount += 1 }
            try require(!stalePerformed && staleActionCount == 0, "old token slept the display after turn-on")
        }
    }

    /// Runs in a fresh process, using Process rather than fork with Foundation.
    private static func runWriter(directory: URL) throws {
        try Data().write(to: directory.appendingPathComponent("writer-ready"), options: .atomic)
        let store = ScreenControlStore(directory: directory)
        try store.write("off")
        try appendEvent("write off completed", directory: directory)
        // A harmless witness stands in for the caller's real display-on action.
        try appendEvent("on action", directory: directory)
    }

    private static func launchWriter(directory: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--writer", directory.path]
        try process.run()
        return process
    }

    private static func waitForExit(_ process: Process) throws {
        try waitUntil("writer timed out, possibly because the store leaked its lock") { !process.isRunning }
        process.waitUntilExit()
        try require(process.terminationStatus == 0, "writer exited with \(process.terminationStatus)")
    }

    private static func stopIfRunning(_ process: Process) {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    private static func waitUntil(_ message: String, condition: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw TestFailure(description: message)
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private static func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-guard-control-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private static func appendEvent(_ event: String, directory: URL) throws {
        // O_APPEND records each witness as one write even if an unlocked store
        // accidentally lets both processes reach the event log concurrently.
        let path = directory.appendingPathComponent("events.log").path
        let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw TestFailure(description: "cannot open event log") }
        defer { Darwin.close(descriptor) }
        let data = Data("\(event)\n".utf8)
        let count = data.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        }
        try require(count == data.count, "cannot append event witness")
    }

    private static func readEvents(_ directory: URL) throws -> [String] {
        let contents = try String(contentsOf: directory.appendingPathComponent("events.log"), encoding: .utf8)
        return contents.split(separator: "\n").map(String.init)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(description: message) }
    }
}
#endif
