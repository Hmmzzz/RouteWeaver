import XCTest
@testable import RouteDNS

final class DNSHTTPSUpstreamTests: XCTestCase {
    override func tearDown() {
        DNSHTTPProtocol.configure { _ in }
        super.tearDown()
    }

    func testValidAnswersIncludingNoDataAndNegativeResponsesAreHealthy() throws {
        let question = try XCTUnwrap(DNSWire.question(makeQuery("v.qq.com")))
        for response in [
            DNSWire.response(to: question, addresses: [0x65060f82], ttl: 30),
            DNSWire.response(to: question, addresses: [0x01010101], ttl: 30),
            DNSWire.response(to: question),
            DNSWire.response(to: question, rcode: 3),
            DNSWire.response(to: question, rcode: 2)
        ] {
            DNSHTTPProtocol.configure { $0.respond(response) }
            let upstream = makeUpstream()
            let result = resolve(upstream, question)
            guard case .response(let answer) = result else { XCTFail("Valid DNS response counted as transport failure"); upstream.stop(); continue }
            XCTAssertEqual(answer, DNSWire.aAnswer(response, for: question))
            upstream.stop()
        }
    }

    func testAAAAEligibilityProbeMatchesTheAQuestionActuallySent() throws {
        let original = try XCTUnwrap(DNSWire.question(makeQuery("v.qq.com", type: 28)))
        let probe = try XCTUnwrap(DNSWire.question(original.query(type: 1)))
        let response = DNSWire.response(to: probe, addresses: [0x65060f82], ttl: 30)
        DNSHTTPProtocol.configure { $0.respond(response) }
        let upstream = makeUpstream(); defer { upstream.stop() }
        guard case .response(let answer) = resolve(upstream, original) else { return XCTFail("A probe was matched against original AAAA type") }
        XCTAssertEqual(answer?.addresses, [0x65060f82])
    }

    func testHTTPNetworkAndMalformedDNSFailuresAreUnhealthy() throws {
        let question = try XCTUnwrap(DNSWire.question(makeQuery("v.qq.com")))
        let valid = DNSWire.response(to: question, addresses: [0x65060f82], ttl: 30)
        var mismatched = valid; mismatched[0] ^= 1
        let actions: [(DNSHTTPProtocol) -> Void] = [
            { $0.respond(valid, status: 503) },
            { $0.respond(valid, mime: "text/plain") },
            { $0.respond(Data(valid.dropLast())) },
            { $0.respond(mismatched) },
            { $0.respond(Data(repeating: 0, count: 70_000)) },
            { $0.client?.urlProtocol($0, didFailWithError: URLError(.notConnectedToInternet)) }
        ]
        for action in actions {
            DNSHTTPProtocol.configure(action)
            let upstream = makeUpstream()
            guard case .failure = resolve(upstream, question) else { XCTFail("Upstream failure was not classified"); upstream.stop(); continue }
            upstream.stop()
        }
    }

    func testDeadlineCancelsSilentDoHAndCompletesOnce() throws {
        let question = try XCTUnwrap(DNSWire.question(makeQuery("v.qq.com")))
        let started = expectation(description: "HTTP started")
        DNSHTTPProtocol.configure { request in
            XCTAssertLessThanOrEqual(request.request.timeoutInterval, 0.05)
            started.fulfill()
        }
        let upstream = makeUpstream(); defer { upstream.stop() }
        let done = expectation(description: "deadline completed"); done.assertForOverFulfill = true
        let beginning = ProcessInfo.processInfo.systemUptime
        let cancellation = upstream.lookup(question, timeout: 0.05) { result in
            guard case .failure = result else { XCTFail("A real timeout must affect upstream health"); done.fulfill(); return }
            done.fulfill()
        }
        wait(for: [started, done], timeout: 1)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - beginning, 0.8)
        cancellation.cancel(); upstream.stop()
    }

    func testExplicitCancellationAndStopAreUnavailableAndReleaseCapacity() throws {
        let question = try XCTUnwrap(DNSWire.question(makeQuery("v.qq.com")))
        DNSHTTPProtocol.configure { _ in }
        let upstream = makeUpstream(); defer { upstream.stop() }
        let cancelled = expectation(description: "cancelled requests")
        cancelled.expectedFulfillmentCount = 64; cancelled.assertForOverFulfill = true
        let handles = (0..<64).map { _ in
            upstream.lookup(question) { result in
                guard case .unavailable = result else { XCTFail("Cancellation must not mark DoH unhealthy"); cancelled.fulfill(); return }
                cancelled.fulfill()
            }
        }
        guard case .unavailable = resolve(upstream, question) else { return XCTFail("Capacity rejection must be unavailable") }
        DispatchQueue.concurrentPerform(iterations: handles.count) { handles[$0].cancel(); handles[$0].cancel() }
        wait(for: [cancelled], timeout: 1)
        let response = DNSWire.response(to: question, addresses: [0x65060f82], ttl: 30)
        DNSHTTPProtocol.configure { $0.respond(response) }
        guard case .response = resolve(upstream, question) else { return XCTFail("Cancelled work kept its admission slots") }
        upstream.stop(); upstream.stop()
        guard case .unavailable = resolve(upstream, question) else { return XCTFail("Stopped service must remain unavailable") }
    }

    func testStopAndCancelRaceCompletesEachRequestOnce() throws {
        let question = try XCTUnwrap(DNSWire.question(makeQuery("v.qq.com")))
        DNSHTTPProtocol.configure { _ in }
        let upstream = makeUpstream()
        let done = expectation(description: "each stopped request")
        done.expectedFulfillmentCount = 16; done.assertForOverFulfill = true
        let handles = (0..<16).map { _ in upstream.lookup(question) { result in
            guard case .unavailable = result else { XCTFail("Stop must not count as network failure"); done.fulfill(); return }
            done.fulfill()
        } }
        DispatchQueue.concurrentPerform(iterations: handles.count + 1) { index in
            if index == handles.count { upstream.stop() }
            else { handles[index].cancel() }
        }
        wait(for: [done], timeout: 1)
        upstream.stop()
    }

    func testExhaustedBudgetDoesNotStartHTTPOrMarkFailure() throws {
        let question = try XCTUnwrap(DNSWire.question(makeQuery("v.qq.com")))
        DNSHTTPProtocol.configure { _ in XCTFail("Exhausted budget started HTTP") }
        let upstream = makeUpstream(); defer { upstream.stop() }
        for budget in [0, -1, Double.infinity, Double.nan] {
            guard case .unavailable = resolve(upstream, question, timeout: budget) else { XCTFail("Invalid local budget counted as upstream failure"); continue }
        }
    }

    private func makeUpstream() -> DNSHTTPSUpstream {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DNSHTTPProtocol.self]
        return DNSHTTPSUpstream(configuration: configuration)
    }
    private func resolve(_ upstream: DNSHTTPSUpstream, _ query: DNSQuestion, timeout: TimeInterval = 1) -> DNSDomesticResult {
        let done = expectation(description: "HTTP result"); done.assertForOverFulfill = true
        var result: DNSDomesticResult = .unavailable
        upstream.lookup(query, timeout: timeout) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 2)
        return result
    }
}

/// All HTTP is fulfilled in-process; these tests never open real connections.
private final class DNSHTTPProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: (DNSHTTPProtocol) -> Void = { _ in }
    static func configure(_ handler: @escaping (DNSHTTPProtocol) -> Void) {
        lock.lock(); self.handler = handler; lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
        handler(self)
    }
    override func stopLoading() {}
    func respond(_ data: Data, status: Int = 200, mime: String = "application/dns-message") {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
