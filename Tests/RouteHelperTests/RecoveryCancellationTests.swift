import XCTest
import Darwin
@testable import RouteHelper

final class RecoveryCancellationTests: XCTestCase {
    func testCancellationIsIdempotentAndSharedAcrossThreads() {
        let token = RecoveryCancellation()
        XCTAssertFalse(token.isCancelled)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in token.cancel() }
        XCTAssertTrue(token.isCancelled)
        XCTAssertThrowsError(try token.throwIfCancelled()) { XCTAssertTrue($0 is RecoveryCancelled) }
    }

    func testCancelledCommandNeverLaunches() {
        let token = RecoveryCancellation(); token.cancel()
        XCTAssertThrowsError(try runRecoveryCommand(executable: "/does/not/exist", arguments: [], cancellation: token)) {
            XCTAssertTrue($0 is RecoveryCancelled)
        }
    }

    func testCommandReturnsOutputAndRejectsFailure() throws {
        let data = try runRecoveryCommand(executable: "/usr/bin/printf", arguments: ["valid output"])
        XCTAssertEqual(String(data: data, encoding: .utf8), "valid output")
        XCTAssertThrowsError(try runRecoveryCommand(executable: "/bin/sh", arguments: ["-c", "exit 7"]))
    }

    func testOutputLimitStopsAnEndlessWriter() {
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try runRecoveryCommand(executable: "/usr/bin/yes", arguments: [], timeout: 2, maximumOutputBytes: 64))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    }

    func testCommandDoesNotInheritUnmarkedHelperDescriptors() throws {
        let original = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(original, 0)
        defer { close(original) }
        let descriptor = fcntl(original, F_DUPFD, 200)
        XCTAssertGreaterThanOrEqual(descriptor, 200)
        defer { close(descriptor) }
        XCTAssertEqual(fcntl(descriptor, F_GETFD) & FD_CLOEXEC, 0)
        _ = try runRecoveryCommand(executable: "/bin/sh", arguments: ["-c", "test ! -e \"/dev/fd/$1\"", "fixture", String(descriptor)])
    }

    func testDeadlineTerminatesAProcessWithClosedStdout() {
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try runRecoveryCommand(executable: "/bin/sh", arguments: ["-c", "exec 1>&-; exec /bin/sleep 30"], timeout: 0.08))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    }

    func testCancellationTerminatesTheCLIAndItsChildGroup() throws {
        let token = RecoveryCancellation(), done = expectation(description: "cancelled worker")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("child.pid")
        DispatchQueue.global().async {
            defer { done.fulfill() }
            do {
                _ = try runRecoveryCommand(executable: "/bin/sh",
                    arguments: ["-c", "/bin/sleep 30 & child=$!; printf '%s' \"$child\" > \"$1\"; wait", "fixture", pidFile.path], cancellation: token)
                XCTFail("A cancelled CLI must not report success")
            } catch { XCTAssertTrue(error is RecoveryCancelled) }
        }
        var child: pid_t?
        for _ in 0..<200 {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text) { child = pid; break }
            usleep(5_000)
        }
        let start = ProcessInfo.processInfo.systemUptime
        token.cancel()
        wait(for: [done], timeout: 2)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        let pid = try XCTUnwrap(child)
        // A killed descendant may briefly be a zombie until launchd reaps it.
        var absent = false
        for _ in 0..<200 {
            if kill(pid, 0) < 0 && errno == ESRCH { absent = true; break }
            usleep(5_000)
        }
        XCTAssertTrue(absent, "Cancelling the wrapper must also terminate its child CLI")
    }
}
