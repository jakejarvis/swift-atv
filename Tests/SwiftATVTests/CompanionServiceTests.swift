#if canImport(Network)
    import Foundation
    import Network
    import XCTest
    #if canImport(CryptoKit)
        import CryptoKit
    #else
        import Crypto
    #endif

    @testable import SwiftATV

    final class CompanionServiceTests: XCTestCase {
        func testTouchStartTimeoutDoesNotFailSetup() async throws {
            let pairVerify = FakePairVerifyFixture()
            let server = try await FakeCompanionServer.start(
                ignoredRequests: ["_touchStart"],
                pairVerify: pairVerify.responder
            )
            defer { server.stop() }

            let service = CompanionService(
                host: "127.0.0.1",
                port: server.port,
                credentials: pairVerify.credentials,
                touchStartTimeout: 0.05
            )

            try await service.setup()

            XCTAssertEqual(service.capabilities?.capabilityInfo(.remote(.up)).state, .available)
            XCTAssertEqual(service.capabilities?.capabilityInfo(.touch(.swipe)).state, .unavailable)
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
            XCTAssertLessThan(
                try XCTUnwrap(requests.firstIndex(of: "_sessionStart")),
                try XCTUnwrap(requests.firstIndex(of: "_touchStart"))
            )
        }

        func testSessionStartTimeoutDoesNotFailBasicSetup() async throws {
            let pairVerify = FakePairVerifyFixture()
            let server = try await FakeCompanionServer.start(
                ignoredRequests: ["_sessionStart"],
                pairVerify: pairVerify.responder
            )
            defer { server.stop() }

            let service = CompanionService(
                host: "127.0.0.1",
                port: server.port,
                credentials: pairVerify.credentials,
                touchStartTimeout: 0.05
            )

            try await service.setup()

            XCTAssertEqual(service.capabilities?.capabilityInfo(.remote(.up)).state, .available)
            XCTAssertEqual(service.capabilities?.capabilityInfo(.touch(.swipe)).state, .unavailable)
            XCTAssertNil(service.touch)

            let remote = try XCTUnwrap(service.remoteControl)
            try await remote.up()

            await service.close()

            let requests = server.requests
            XCTAssertTrue(requests.contains("_systemInfo"))
            XCTAssertTrue(requests.contains("_sessionStart"))
            XCTAssertFalse(requests.contains("_touchStart"))
            XCTAssertTrue(requests.contains("_interest"))
            XCTAssertEqual(requests.filter { $0 == "_hidC" }.count, 2)
        }

        func testCompanionSendsNoOpKeepAliveAfterSetup() async throws {
            let pairVerify = FakePairVerifyFixture()
            let server = try await FakeCompanionServer.start(pairVerify: pairVerify.responder)
            defer { server.stop() }

            let service = CompanionService(
                host: "127.0.0.1",
                port: server.port,
                credentials: pairVerify.credentials,
                touchStartTimeout: 0.05,
                keepAliveInterval: 0.01
            )

            try await service.setup()

            let sentKeepAlive = await eventually(timeoutNanoseconds: 500_000_000) {
                server.noOpCount > 0
            }
            await service.close()

            XCTAssertTrue(sentKeepAlive)
        }

        func testSystemInfoUsesRapportIdentifier() async throws {
            let pairVerify = FakePairVerifyFixture()
            let server = try await FakeCompanionServer.start(pairVerify: pairVerify.responder)
            defer { server.stop() }

            let settings = ATVSettings(
                clientIdentity: ClientIdentitySettings(
                    name: "Clicker",
                    deviceID: "client-device-id",
                    pairingIdentifier: "pairing-id",
                    rapportIdentifier: "rapport-id"
                )
            )
            let service = CompanionService(
                host: "127.0.0.1",
                port: server.port,
                credentials: pairVerify.credentials,
                settings: settings,
                touchStartTimeout: 0.05
            )

            try await service.setup()
            await service.close()

            let content = try XCTUnwrap(server.requestContent(for: "_systemInfo"))
            XCTAssertEqual(content["_i"]?.stringValue, "rapport-id")
            XCTAssertNotEqual(content["_i"]?.stringValue, "pairing-id")
            XCTAssertEqual(content["_idsID"]?.stringValue, "fake-client")
            XCTAssertEqual(content["_pubID"]?.stringValue, "client-device-id")
        }
    }

    private final class FakeCompanionServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "SwiftATVTests.FakeCompanionServer")
        private let ignoredRequests: Set<String>
        private let pairVerify: FakePairVerifyResponder?
        private let lock = NSLock()
        private var connection: NWConnection?
        private var pendingCipher: ChaCha20Cipher?
        private var cipher: ChaCha20Cipher?
        private var _requests: [String] = []
        private var _requestContents: [String: OPACK.Value] = [:]
        private var _noOpCount = 0

        var port: Int {
            Int(listener.port!.rawValue)
        }

        var requests: [String] {
            lock.withLock { _requests }
        }

        var noOpCount: Int {
            lock.withLock { _noOpCount }
        }

        func requestContent(for identifier: String) -> OPACK.Value? {
            lock.withLock { _requestContents[identifier] }
        }

        static func start(
            ignoredRequests: Set<String> = [],
            pairVerify: FakePairVerifyResponder? = nil
        ) async throws -> FakeCompanionServer {
            let server = try FakeCompanionServer(ignoredRequests: ignoredRequests, pairVerify: pairVerify)
            try await server.start()
            return server
        }

        private init(ignoredRequests: Set<String>, pairVerify: FakePairVerifyResponder?) throws {
            self.ignoredRequests = ignoredRequests
            self.pairVerify = pairVerify
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
                        resume.resume(
                            throwing: ATVError.connectionFailed(
                                message: "Fake Companion server cancelled"
                            ))
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
                let headerData = Data(buffer.prefix(4))
                let header = Array(headerData)
                let frameType = CompanionFrameType(rawValue: header[0]) ?? .unknown
                let length =
                    (Int(header[1]) << 16)
                    | (Int(header[2]) << 8)
                    | Int(header[3])
                guard buffer.count >= 4 + length else {
                    return
                }

                let wirePayload = Data(buffer.dropFirst(4).prefix(length))
                buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: 4 + length))
                let payload: Data
                do {
                    if let cipher = lock.withLock({ self.cipher }), !wirePayload.isEmpty {
                        payload = try cipher.decrypt(wirePayload, aad: headerData)
                    } else {
                        payload = wirePayload
                    }
                } catch {
                    return
                }
                handleFrame(type: frameType, payload: payload, connection: connection)
            }
        }

        private func handleFrame(type: CompanionFrameType, payload: Data, connection: NWConnection) {
            switch type {
            case .pvStart:
                handlePairVerifyStart(payload, connection: connection)
            case .pvNext:
                handlePairVerifyNext(payload, connection: connection)
            case .eOPACK:
                handleOPACKPayload(payload, connection: connection)
            case .noOp:
                lock.withLock {
                    _noOpCount += 1
                }
            default:
                break
            }
        }

        private func handlePairVerifyStart(_ payload: Data, connection: NWConnection) {
            guard let pairVerify else { return }
            do {
                let result = try pairVerify.startResponse(for: payload)
                lock.withLock {
                    pendingCipher = result.cipher
                }
                sendFrame(type: .pvNext, payload: result.payload, connection: connection)
            } catch {
                return
            }
        }

        private func handlePairVerifyNext(_ payload: Data, connection: NWConnection) {
            guard let pairVerify else { return }
            do {
                let response = try pairVerify.finishResponse(for: payload)
                sendFrame(type: .pvNext, payload: response, connection: connection)
                lock.withLock {
                    cipher = pendingCipher
                    pendingCipher = nil
                }
            } catch {
                return
            }
        }

        private func handleOPACKPayload(_ payload: Data, connection: NWConnection) {
            guard
                let message = try? OPACK.decode(payload),
                let identifier = message["_i"]?.stringValue
            else {
                return
            }

            lock.withLock {
                _requests.append(identifier)
                if let content = message["_c"] {
                    _requestContents[identifier] = content
                }
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
            sendFrame(type: .eOPACK, payload: payload, connection: connection)
        }

        private func sendFrame(type: CompanionFrameType, payload: Data, connection: NWConnection) {
            let cipher = lock.withLock { self.cipher }
            let wireLength = payload.count + ((cipher != nil && !payload.isEmpty) ? 16 : 0)

            var header = Data()
            header.append(type.rawValue)
            header.append(UInt8((wireLength >> 16) & 0xFF))
            header.append(UInt8((wireLength >> 8) & 0xFF))
            header.append(UInt8(wireLength & 0xFF))

            let wirePayload: Data
            do {
                if let cipher, !payload.isEmpty {
                    wirePayload = try cipher.encrypt(payload, aad: header)
                } else {
                    wirePayload = payload
                }
            } catch {
                return
            }

            connection.send(content: header + wirePayload, completion: .contentProcessed { _ in })
        }
    }

    private func eventually(
        timeoutNanoseconds: UInt64,
        condition: () -> Bool
    ) async -> Bool {
        let interval: UInt64 = 10_000_000
        var elapsed: UInt64 = 0
        while elapsed < timeoutNanoseconds {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: interval)
            elapsed += interval
        }
        return condition()
    }

    private struct FakePairVerifyFixture {
        let credentials: HAPCredentials
        let responder: FakePairVerifyResponder

        init() {
            let serverSigningKey = Curve25519.Signing.PrivateKey()
            let clientSigningKey = Curve25519.Signing.PrivateKey()
            let atvIdentifier = Data("fake-atv".utf8)
            let clientIdentifier = Data("fake-client".utf8)

            self.credentials = HAPCredentials(
                ltpk: Data(serverSigningKey.publicKey.rawRepresentation),
                ltsk: Data(clientSigningKey.rawRepresentation),
                atvIdentifier: atvIdentifier,
                clientIdentifier: clientIdentifier
            )
            self.responder = FakePairVerifyResponder(
                identifier: atvIdentifier,
                signingKey: serverSigningKey
            )
        }
    }

    private final class FakePairVerifyResponder: @unchecked Sendable {
        private let identifier: Data
        private let signingKey: Curve25519.Signing.PrivateKey
        private let lock = NSLock()
        private var sessionKey: Data?

        init(identifier: Data, signingKey: Curve25519.Signing.PrivateKey) {
            self.identifier = identifier
            self.signingKey = signingKey
        }

        func startResponse(for payload: Data) throws(ATVError) -> (payload: Data, cipher: ChaCha20Cipher) {
            let innerTLV = try unwrapCompanionAuthEnvelope(payload)
            let request = try TLV8.decodeStrict(innerTLV)
            guard let clientPublicKey = request[TLVTag.publicKey.rawValue] else {
                throw ATVError.invalidResponse("Pair-verify start missing client public key")
            }

            let serverPrivateKey = Curve25519.KeyAgreement.PrivateKey()
            let serverPublicKey = Data(serverPrivateKey.publicKey.rawRepresentation)
            let sharedSecret: Data
            do {
                sharedSecret = try SRPAuthHandler.sharedSecret(
                    privateKey: serverPrivateKey,
                    peerPublicKey: clientPublicKey
                )
            } catch {
                throw ATVError.wrap(error)
            }
            let sessionKey = hkdfExpand(
                salt: "Pair-Verify-Encrypt-Salt",
                info: "Pair-Verify-Encrypt-Info",
                sharedSecret: sharedSecret
            )

            var deviceInfo = Data()
            deviceInfo.append(serverPublicKey)
            deviceInfo.append(identifier)
            deviceInfo.append(clientPublicKey)
            let signature: Data
            do {
                signature = Data(try signingKey.signature(for: deviceInfo))
            } catch {
                throw ATVError.wrap(error)
            }
            let proof = TLV8.encode([
                TLV8.Entry(tag: .identifier, data: identifier),
                TLV8.Entry(tag: .signature, data: signature),
            ])
            let encrypted = try hapEncrypt(proof, key: sessionKey, nonce: hapNonce("PV-Msg02"))
            let response = TLV8.encode([
                TLV8.Entry(tag: .state, value: 2),
                TLV8.Entry(tag: .publicKey, data: serverPublicKey),
                TLV8.Entry(tag: .encryptedData, data: encrypted),
            ])

            lock.withLock {
                self.sessionKey = sessionKey
            }

            let outputKey = hkdfExpand(salt: "", info: "ClientEncrypt-main", sharedSecret: sharedSecret)
            let inputKey = hkdfExpand(salt: "", info: "ServerEncrypt-main", sharedSecret: sharedSecret)
            let cipher = ChaCha20Cipher(encryptKey: inputKey, decryptKey: outputKey)
            return (wrapCompanionAuthEnvelope(innerTLV: response), cipher)
        }

        func finishResponse(for payload: Data) throws(ATVError) -> Data {
            let innerTLV = try unwrapCompanionAuthEnvelope(payload)
            let request = try TLV8.decodeStrict(innerTLV)
            guard
                let encryptedData = request[TLVTag.encryptedData.rawValue],
                let sessionKey = lock.withLock({ self.sessionKey })
            else {
                throw ATVError.invalidResponse("Pair-verify finish missing encrypted proof")
            }

            _ = try hapDecrypt(encryptedData, key: sessionKey, nonce: hapNonce("PV-Msg03"))
            let response = TLV8.encode([
                TLV8.Entry(tag: .state, value: 4)
            ])
            return wrapCompanionAuthEnvelope(innerTLV: response)
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
