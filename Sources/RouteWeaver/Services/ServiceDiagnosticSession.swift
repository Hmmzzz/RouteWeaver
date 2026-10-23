import Foundation
import Darwin
import RouteIPC

/// A signed diagnostic client keeps the same kernel peer identity throughout a
/// live test. Each input line is a base64 ServiceRequest; each output line is a
/// JSON ServiceResponse. No AppStore, authorization UI, or installation is used.
struct ServiceDiagnosticSession {
    static let maximumLineSize = 1_400_000
    let send: (ServiceRequest) throws -> ServiceResponse

    init(send: @escaping (ServiceRequest) throws -> ServiceResponse = {
        try RouteIPCClient.send($0, timeout: 120)
    }) {
        self.send = send
    }

    func run(readLine: () throws -> Data?, writeResponse: (ServiceResponse) throws -> Void) throws {
        var attemptedAttach = false
        defer {
            // Also covers a lost attach reply. Scoped cleanup cannot revoke a
            // different GUI's ownership; process-exit monitoring is the fallback.
            if attemptedAttach { _ = try? send(ServiceRequest(command: .stopOwned)) }
        }
        while let line = try readLine() {
            let response: ServiceResponse
            do {
                guard !line.isEmpty, line.count <= Self.maximumLineSize,
                      let data = Data(base64Encoded: line), data.count <= IPCWire.maximumFrame else {
                    throw IPCError("无效或过大的会话请求")
                }
                let request = try JSONDecoder().decode(ServiceRequest.self, from: data)
                try request.validate()
                if request.command == .attach { attemptedAttach = true }
                response = try send(request)
            } catch {
                var failure = ServiceResponse()
                failure.failed = 1
                failure.message = String(describing: error)
                response = failure
            }
            try writeResponse(response)
        }
    }

    static func runStandardIO() throws {
        // A controller that closes stdout must still allow scoped cleanup.
        signal(SIGPIPE, SIG_IGN)
        let input = FileHandle.standardInput, output = FileHandle.standardOutput
        try Self().run(inputDescriptor: input.fileDescriptor, writeResponse: { response in
            var data = try JSONEncoder().encode(response)
            data.append(10)
            try output.write(contentsOf: data)
        })
    }

    func run(inputDescriptor: Int32, writeResponse: (ServiceResponse) throws -> Void) throws {
        let reader = DiagnosticLineReader {
            // Foundation's read(upToCount:) can wait to fill an entire pipe
            // buffer. One POSIX read returns an available short request while
            // the controller keeps stdin open awaiting its response.
            var bytes = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = Darwin.read(inputDescriptor, &bytes, bytes.count)
                if count >= 0 { return Data(bytes.prefix(count)) }
                if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
        }
        try run(readLine: { try reader.next() }, writeResponse: writeResponse)
    }
}

/// Bounds memory before decoding, including a controller that never sends LF.
final class DiagnosticLineReader {
    private var buffer = Data()
    private let readChunk: () throws -> Data
    init(readChunk: @escaping () throws -> Data) { self.readChunk = readChunk }

    func next() throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                var line = Data(buffer[..<newline])
                guard line.count <= ServiceDiagnosticSession.maximumLineSize else {
                    throw IPCError("会话请求超出限制")
                }
                buffer = Data(buffer[buffer.index(after: newline)...])
                if line.last == 13 { line.removeLast() }
                return line
            }
            guard buffer.count <= ServiceDiagnosticSession.maximumLineSize else {
                throw IPCError("会话请求超出限制")
            }
            let chunk = try readChunk()
            if chunk.isEmpty {
                guard buffer.isEmpty else { throw IPCError("会话请求不完整") }
                return nil
            }
            buffer.append(chunk)
        }
    }
}
