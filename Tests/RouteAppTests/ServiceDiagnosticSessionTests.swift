import Foundation
import XCTest
import RouteIPC
@testable import RouteWeaver

final class ServiceDiagnosticSessionTests: XCTestCase {
    private func line(_ command: ServiceCommand, routes: [String]? = nil) throws -> Data {
        try JSONEncoder().encode(ServiceRequest(command: command, routes: routes)).base64EncodedData()
    }

    func testOneSessionOwnsApplyAndCleansUpAtEOF() throws {
        var requests: [ServiceCommand] = [], attached = false
        var lines = try [line(.status), line(.attach), line(.apply, routes: ["223.5.5.0/24"]), line(.status)]
        var responses: [ServiceResponse] = []
        let session = ServiceDiagnosticSession { request in
            requests.append(request.command)
            if request.command == .attach { attached = true }
            if request.command == .apply { XCTAssertTrue(attached) }
            if request.command == .stopOwned { attached = false }
            var response = ServiceResponse(); response.sessionAttached = attached
            return response
        }
        try session.run(readLine: { lines.isEmpty ? nil : lines.removeFirst() }, writeResponse: { responses.append($0) })
        XCTAssertEqual(requests, [.status, .attach, .apply, .status, .stopOwned])
        XCTAssertEqual(responses.count, 4)
        XCTAssertFalse(attached)
    }

    func testReadOnlySessionDoesNotStopAnyOwner() throws {
        var requests: [ServiceCommand] = []
        var lines = try [line(.status)]
        try ServiceDiagnosticSession { request in
            requests.append(request.command); return ServiceResponse()
        }.run(readLine: { lines.isEmpty ? nil : lines.removeFirst() }, writeResponse: { _ in })
        XCTAssertEqual(requests, [.status])
    }

    func testShortRequestRepliesWhileTheRealInputPipeRemainsOpen() throws {
        let pipe = Pipe()
        let replied = expectation(description: "short request replied before controller closes stdin")
        let cleaned = expectation(description: "owner cleaned on EOF")
        let finished = expectation(description: "session finished")
        let input = pipe.fileHandleForReading, output = pipe.fileHandleForWriting
        defer { try? input.close(); try? output.close() }
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                try ServiceDiagnosticSession { request in
                    if request.command == .stopOwned { cleaned.fulfill() }
                    return ServiceResponse()
                }.run(inputDescriptor: input.fileDescriptor, writeResponse: { _ in replied.fulfill() })
            } catch { XCTFail("Pipe session failed: \(error)") }
        }
        var request = try line(.attach)
        request.append(10)
        try output.write(contentsOf: request)
        wait(for: [replied], timeout: 2)
        try output.close()
        wait(for: [cleaned, finished], timeout: 2)
    }

    func testInvalidRequestIsRejectedLocallyAndNextRequestCanProceed() throws {
        var lines = try [Data("!!!".utf8), line(.apply, routes: []), line(.status)]
        var requests: [ServiceCommand] = [], failures: [Int] = []
        try ServiceDiagnosticSession { request in
            requests.append(request.command); return ServiceResponse()
        }.run(readLine: { lines.isEmpty ? nil : lines.removeFirst() }, writeResponse: { failures.append($0.failed) })
        XCTAssertEqual(failures, [1, 1, 0])
        XCTAssertEqual(requests, [.status])
    }

    func testLostAttachReplyStillAttemptsOnlyScopedCleanup() throws {
        var requests: [ServiceCommand] = []
        var lines = try [line(.attach)]
        try ServiceDiagnosticSession { request in
            requests.append(request.command)
            throw IPCError("lost reply")
        }.run(readLine: { lines.isEmpty ? nil : lines.removeFirst() }, writeResponse: { XCTAssertEqual($0.failed, 1) })
        XCTAssertEqual(requests, [.attach, .stopOwned])
    }

    func testOutputFailureAfterAttachCleansUp() throws {
        var requests: [ServiceCommand] = []
        let encoded = try line(.attach)
        XCTAssertThrowsError(try ServiceDiagnosticSession { request in
            requests.append(request.command); return ServiceResponse()
        }.run(readLine: { encoded }, writeResponse: { _ in throw IPCError("closed pipe") }))
        XCTAssertEqual(requests, [.attach, .stopOwned])
    }

    func testReadFailureAfterAttachCleansUp() throws {
        var requests: [ServiceCommand] = []
        var next: Data? = try line(.attach)
        XCTAssertThrowsError(try ServiceDiagnosticSession { request in
            requests.append(request.command); return ServiceResponse()
        }.run(readLine: {
            if let value = next { next = nil; return value }
            throw IPCError("incomplete input")
        }, writeResponse: { _ in }))
        XCTAssertEqual(requests, [.attach, .stopOwned])
    }

    func testHelperRestartRequiresExplicitReattachAndReapply() throws {
        var attached = false, enabled = false, calls = 0
        var lines = try [line(.attach), line(.apply, routes: ["223.5.5.0/24"]), line(.status),
                         line(.attach), line(.apply, routes: ["223.5.5.0/24"])]
        var results: [ServiceResponse] = []
        try ServiceDiagnosticSession { request in
            calls += 1
            if calls == 3 { attached = false; enabled = false }
            if request.command == .attach { attached = true }
            if request.command == .apply { XCTAssertTrue(attached); enabled = true }
            var response = ServiceResponse(); response.sessionAttached = attached; response.enabled = enabled
            return response
        }.run(readLine: { lines.isEmpty ? nil : lines.removeFirst() }, writeResponse: { results.append($0) })
        XCTAssertFalse(results[2].enabled)
        XCTAssertEqual(results[2].sessionAttached, false)
        XCTAssertTrue(results[4].enabled)
    }

    func testLineReaderHandlesFragmentsMultipleFramesAndCRLF() throws {
        var chunks = [Data("fi".utf8), Data("rst\r\nsecond\n".utf8), Data()]
        let reader = DiagnosticLineReader { chunks.removeFirst() }
        XCTAssertEqual(try reader.next(), Data("first".utf8))
        XCTAssertEqual(try reader.next(), Data("second".utf8))
        XCTAssertNil(try reader.next())
    }

    func testLineReaderRejectsTruncationAndOversizeWithoutUnboundedRead() {
        var chunks = [Data("partial".utf8), Data()]
        XCTAssertThrowsError(try DiagnosticLineReader { chunks.removeFirst() }.next())
        var reads = 0
        XCTAssertThrowsError(try DiagnosticLineReader {
            reads += 1
            return Data(repeating: 65, count: 8192)
        }.next())
        XCTAssertLessThanOrEqual(reads, ServiceDiagnosticSession.maximumLineSize / 8192 + 1)
    }
}
