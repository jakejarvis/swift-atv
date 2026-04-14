#if canImport(Network)
    import Foundation
    import Network
    import XCTest

    @testable import SwiftATV

    final class CompanionServiceTests: XCTestCase {
        func testTouchStartTimeoutDoesNotFailSetup() async throws {
            let server = try await FakeCompanionServer.start(ignoredRequests: ["_touchStart"])
            defer { server.stop() }

            let service = CompanionService(
                host: "127.0.0.1",
                port: server.port,
                touchStartTimeout: 0.05
            )

            try await service.setup()

            XCTAssertEqual(service.features?.featureInfo(.up).state, .available)
            XCTAssertEqual(service.features?.featureInfo(.swipe).state, .unavailable)
            XCTAssertNil(service.touch)

            let remote = try XCTUnwrap(service.remoteControl)
            try await remote.up()

            await service.close()

            let requests = server.requests
            XCTAssertTrue(requests.contains("_systemInfo"))
            XCTAssertTrue(requests.contains("_touchStart"))
            XCTAssertTrue(requests.contains("_sessionStart"))
            XCTAssertTrue(requests.contains("_interest"))
            XCTAssertEqual(requests.filter { $0 == "_hidC" }.count, 2)
        }
    }

    private final class FakeCompanionServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "SwiftATVTests.FakeCompanionServer")
        private let ignoredRequests: Set<String>
        private let lock = NSLock()
        private var connection: NWConnection?
        private var _requests: [String] = []

        var port: Int {
            Int(listener.port!.rawValue)
        }

        var requests: [String] {
            lock.withLock { _requests }
        }

        static func start(ignoredRequests: Set<String> = []) async throws -> FakeCompanionServer {
            let server = try FakeCompanionServer(ignoredRequests: ignoredRequests)
            try await server.start()
            return server
        }

        private init(ignoredRequests: Set<String>) throws {
            self.ignoredRequests = ignoredRequests
            self.listener = try NWListener(using: .tcp, on: .any)
        }

        private func start() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resume = SingleResume(continuation)

                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        resume.resume()
                    case .failed(let error):
                        resume.resume(throwing: error)
                    case .cancelled:
                        resume.resume(throwing: ATVError.connectionFailed("Fake Companion server cancelled"))
                    default:
                        break
                    }
                }

                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { return }
                    self.lock.withLock {
                        self.connection = connection
                    }
                    connection.start(queue: self.queue)
                    self.receive(on: connection)
                }

                listener.start(queue: queue)
            }
        }

        func stop() {
            listener.cancel()
            lock.withLock { connection }?.cancel()
        }

        private func receive(on connection: NWConnection, buffer: Data = Data()) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
                [weak self] data, _, isComplete, error in
                guard let self else { return }

                var nextBuffer = buffer
                if let data, !data.isEmpty {
                    nextBuffer.append(data)
                    self.processFrames(in: &nextBuffer, connection: connection)
                }

                guard !isComplete, error == nil else {
                    return
                }
                self.receive(on: connection, buffer: nextBuffer)
            }
        }

        private func processFrames(in buffer: inout Data, connection: NWConnection) {
            while buffer.count >= 4 {
                let header = Array(buffer.prefix(4))
                let length =
                    (Int(header[1]) << 16)
                    | (Int(header[2]) << 8)
                    | Int(header[3])
                guard buffer.count >= 4 + length else {
                    return
                }

                let payload = Data(buffer.dropFirst(4).prefix(length))
                buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: 4 + length))
                handlePayload(payload, connection: connection)
            }
        }

        private func handlePayload(_ payload: Data, connection: NWConnection) {
            guard
                let message = try? OPACK.decode(payload),
                let identifier = message["_i"]?.stringValue
            else {
                return
            }

            lock.withLock {
                _requests.append(identifier)
            }

            guard
                message["_t"]?.intValue == Int64(CompanionMessageType.request.rawValue),
                !ignoredRequests.contains(identifier),
                let xid = message["_x"]?.intValue,
                xid >= 0
            else {
                return
            }

            let content: OPACK.Value =
                if identifier == "_sessionStart" {
                    .dictionary([("_sid", .uint(1))])
                } else {
                    .dict([])
                }
            sendResponse(identifier: identifier, xid: UInt64(xid), content: content, connection: connection)
        }

        private func sendResponse(
            identifier: String,
            xid: UInt64,
            content: OPACK.Value,
            connection: NWConnection
        ) {
            let response = OPACK.Value.dictionary([
                ("_i", .string(identifier)),
                ("_t", .uint(UInt64(CompanionMessageType.response.rawValue))),
                ("_x", .uint(xid)),
                ("_c", content),
            ])
            let payload = OPACK.encode(response)

            var frame = Data()
            frame.append(CompanionFrameType.eOPACK.rawValue)
            frame.append(UInt8((payload.count >> 16) & 0xFF))
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
            frame.append(payload)

            connection.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    private final class SingleResume: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?

        init(_ continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }

        func resume() {
            take()?.resume()
        }

        func resume(throwing error: Error) {
            take()?.resume(throwing: error)
        }

        private func take() -> CheckedContinuation<Void, Error>? {
            lock.withLock {
                defer { continuation = nil }
                return continuation
            }
        }
    }
#endif
