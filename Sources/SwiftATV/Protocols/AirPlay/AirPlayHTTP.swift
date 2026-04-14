import Foundation
import NIOCore

internal struct AirPlayHTTPResponse: Sendable {
    let protocolVersion: String
    let statusCode: Int
    let reason: String
    let headers: [String: String]
    let body: Data
}

internal enum AirPlayHTTPParser {
    static func parseResponse(from buffer: inout Data) throws(ATVError) -> AirPlayHTTPResponse? {
        guard let headerEnd = headerEnd(in: buffer) else {
            return nil
        }
        let headerData = Data(buffer[0..<headerEnd])
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw ATVError.invalidResponse("AirPlay response header is not UTF-8")
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let statusLine = lines.first, !statusLine.isEmpty else {
            throw ATVError.invalidResponse("AirPlay response missing status line")
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw ATVError.invalidResponse("AirPlay response has invalid status line: \(statusLine)")
        }
        let reason = statusParts.count >= 3 ? String(statusParts[2]) : ""

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            let key = String(line[..<separator]).lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let bodyStart = headerEnd + 4
        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        let totalLength = bodyStart + contentLength
        guard buffer.count >= totalLength else {
            return nil
        }

        let body = Data(buffer[bodyStart..<totalLength])
        buffer = Data(buffer[totalLength...])
        return AirPlayHTTPResponse(
            protocolVersion: String(statusParts[0]),
            statusCode: statusCode,
            reason: reason,
            headers: headers,
            body: body
        )
    }

    static func parseRequest(from buffer: inout Data) throws(ATVError) -> AirPlayHTTPRequest? {
        guard let headerEnd = headerEnd(in: buffer) else {
            return nil
        }
        let headerData = Data(buffer[0..<headerEnd])
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw ATVError.invalidResponse("AirPlay event request header is not UTF-8")
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            throw ATVError.invalidResponse("AirPlay event request missing request line")
        }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard requestParts.count >= 3 else {
            throw ATVError.invalidResponse("AirPlay event request has invalid request line")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            let key = String(line[..<separator]).lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let bodyStart = headerEnd + 4
        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        let totalLength = bodyStart + contentLength
        guard buffer.count >= totalLength else {
            return nil
        }

        let body = Data(buffer[bodyStart..<totalLength])
        buffer = Data(buffer[totalLength...])
        return AirPlayHTTPRequest(
            method: String(requestParts[0]),
            target: String(requestParts[1]),
            protocolVersion: String(requestParts[2]),
            headers: headers,
            body: body
        )
    }

    private static func headerEnd(in data: Data) -> Int? {
        guard data.count >= 4 else {
            return nil
        }
        for offset in 0...(data.count - 4) {
            if data[offset] == 0x0D,
                data[offset + 1] == 0x0A,
                data[offset + 2] == 0x0D,
                data[offset + 3] == 0x0A
            {
                return offset
            }
        }
        return nil
    }
}

internal struct AirPlayHTTPRequest: Sendable {
    let method: String
    let target: String
    let protocolVersion: String
    let headers: [String: String]
    let body: Data
}

internal final class AirPlayControlConnection: @unchecked Sendable {
    private let socket: AirPlayTCPConnection
    private let lock = NSLock()
    private var responseBuffer = Data()
    private var cSeq = 0

    let sessionID = UUID().uuidString.uppercased()

    init(host: String, port: Int, group: EventLoopGroup? = nil) {
        self.socket = AirPlayTCPConnection(host: host, port: port, group: group)
    }

    func connect() async throws(ATVError) {
        try await socket.connect()
    }

    func close() async {
        await socket.close()
    }

    func enableEncryption(outputKey: Data, inputKey: Data) {
        socket.enableEncryption(outputKey: outputKey, inputKey: inputKey)
    }

    func pairVerify(credentials: HAPCredentials) async throws(ATVError) -> HAPPairVerifyHandler {
        let verifier = HAPPairVerifyHandler(credentials: credentials)
        let headers = [
            "User-Agent": AirPlaySupport.userAgent,
            "Connection": "keep-alive",
            "X-Apple-HKP": "3",
            "Content-Type": "application/octet-stream",
        ]

        let first = try await sendHTTPRequest(
            method: "POST",
            path: "/pair-verify",
            body: try verifier.step1(),
            headers: headers
        )
        let secondPayload = try verifier.step2(first.body)
        let second = try await sendHTTPRequest(
            method: "POST",
            path: "/pair-verify",
            body: secondPayload,
            headers: headers
        )
        if !second.body.isEmpty {
            try MRPProtocolHandler.validatePairVerifyFinalResponse(second.body)
        }
        return verifier
    }

    func beginPairSetup(_ setup: HAPPairSetupHandler) async throws(ATVError) -> Data {
        let headers = airPlayAuthHeaders()
        _ = try await sendHTTPRequest(
            method: "POST",
            path: "/pair-pin-start",
            body: nil,
            headers: headers
        )
        let response = try await sendHTTPRequest(
            method: "POST",
            path: "/pair-setup",
            body: try setup.m1(),
            headers: headers
        )
        return response.body
    }

    func pairSetupExchange(_ data: Data) async throws(ATVError) -> Data {
        let response = try await sendHTTPRequest(
            method: "POST",
            path: "/pair-setup",
            body: data,
            headers: airPlayAuthHeaders()
        )
        return response.body
    }

    func setupEventChannel(settings: ATVSettings) async throws(ATVError) -> Int {
        var body = AirPlaySupport.clientInfo(settings: settings)
        body["sessionUUID"] = sessionID
        let response = try await sendRTSPRequest(
            method: "SETUP",
            path: "rtsp://localhost/\(sessionID)",
            body: try binaryPlist(body),
            headers: ["Content-Type": "application/x-apple-binary-plist"]
        )
        guard
            let plist = try? PropertyListSerialization.propertyList(from: response.body, format: nil)
                as? [String: Any],
            let port = plist["eventPort"] as? Int
        else {
            throw ATVError.invalidResponse("AirPlay event channel SETUP missing eventPort")
        }
        return port
    }

    func sendRecord() async throws(ATVError) {
        _ = try await sendRTSPRequest(
            method: "RECORD",
            path: "rtsp://localhost/\(sessionID)",
            body: nil,
            headers: [:]
        )
    }

    func setupDataStream(seed: UInt64) async throws(ATVError) -> Int {
        let stream: [String: Any] = [
            "type": 130,
            "controlType": 2,
            "seed": Int(seed),
            "channelID": UUID().uuidString.uppercased(),
            "clientUUID": UUID().uuidString.uppercased(),
            "wantsDedicatedSocket": true,
            "clientTypeUUID": AirPlaySupport.dataStreamClientTypeUUID,
        ]
        let response = try await sendRTSPRequest(
            method: "SETUP",
            path: "rtsp://localhost/\(sessionID)",
            body: try binaryPlist(["streams": [stream]]),
            headers: ["Content-Type": "application/x-apple-binary-plist"]
        )
        guard
            let plist = try? PropertyListSerialization.propertyList(from: response.body, format: nil)
                as? [String: Any],
            let streams = plist["streams"] as? [[String: Any]],
            let first = streams.first,
            let port = first["dataPort"] as? Int
        else {
            throw ATVError.invalidResponse("AirPlay data stream SETUP missing dataPort")
        }
        return port
    }

    func sendFeedback() async throws(ATVError) {
        _ = try await sendHTTPRequest(
            method: "POST",
            path: "/feedback",
            body: nil,
            headers: [
                "User-Agent": AirPlaySupport.userAgent,
                "X-Apple-Session-ID": sessionID,
            ]
        )
    }

    private func sendHTTPRequest(
        method: String,
        path: String,
        body: Data?,
        headers: [String: String]
    ) async throws(ATVError) -> AirPlayHTTPResponse {
        var request = "\(method) \(path) HTTP/1.1\r\n"
        request += requestHeaders(headers, body: body)
        try await socket.send(Data(request.utf8) + (body ?? Data()))
        return try await receiveResponse()
    }

    private func sendRTSPRequest(
        method: String,
        path: String,
        body: Data?,
        headers: [String: String]
    ) async throws(ATVError) -> AirPlayHTTPResponse {
        let sequence = lock.withLock {
            cSeq += 1
            return cSeq
        }
        var request = "\(method) \(path) RTSP/1.0\r\n"
        request += requestHeaders(
            headers.merging([
                "CSeq": "\(sequence)",
                "User-Agent": AirPlaySupport.userAgent,
                "X-Apple-Session-ID": sessionID,
                "DACP-ID": sessionID,
                "Active-Remote": "0",
            ]) { current, _ in current },
            body: body
        )
        try await socket.send(Data(request.utf8) + (body ?? Data()))
        return try await receiveResponse()
    }

    private func receiveResponse() async throws(ATVError) -> AirPlayHTTPResponse {
        while true {
            let parsedResult: Result<AirPlayHTTPResponse?, ATVError> = lock.withLock {
                do {
                    return .success(try AirPlayHTTPParser.parseResponse(from: &responseBuffer))
                } catch let err as ATVError {
                    return .failure(err)
                } catch {
                    return .failure(ATVError.wrap(error))
                }
            }
            if let parsed = try parsedResult.get() {
                try validate(parsed)
                return parsed
            }

            let data = try await socket.receive()
            lock.withLock {
                responseBuffer.append(data)
            }
        }
    }

    private func validate(_ response: AirPlayHTTPResponse) throws(ATVError) {
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 470 {
                throw ATVError.invalidCredentials("AirPlay pair-verify rejected credentials")
            }
            throw ATVError.http(statusCode: response.statusCode, message: response.reason)
        }
    }

    private func requestHeaders(_ headers: [String: String], body: Data?) -> String {
        var lines = ""
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            lines += "\(key): \(value)\r\n"
        }
        if let body {
            lines += "Content-Length: \(body.count)\r\n"
        }
        lines += "\r\n"
        return lines
    }

    private func airPlayAuthHeaders() -> [String: String] {
        [
            "User-Agent": AirPlaySupport.userAgent,
            "Connection": "keep-alive",
            "X-Apple-HKP": "3",
            "Content-Type": "application/octet-stream",
        ]
    }

    private func binaryPlist(_ value: Any) throws(ATVError) -> Data {
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: value,
                format: .binary,
                options: 0
            )
        } catch {
            throw ATVError.wrap(error)
        }
    }
}
