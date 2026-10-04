import Foundation
import Combine
import Darwin

@MainActor
final class CodexActivityReceiver: ObservableObject {
    static let shared = CodexActivityReceiver()
    static let port: UInt16 = 57321

    @Published private(set) var isListening = false
    @Published private(set) var pairingToken: String
    @Published private(set) var lastReceivedAt: Date?

    private var listener: LoopbackSocketServer?

    private init() {
        if let saved = UserDefaults.standard.string(forKey: "codexActivityPairingToken"), !saved.isEmpty {
            pairingToken = saved
        } else {
            pairingToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            UserDefaults.standard.set(pairingToken, forKey: "codexActivityPairingToken")
        }
    }

    func start() {
        guard listener == nil else { return }
        do {
            let newListener = try LoopbackSocketServer(port: Self.port) { [weak self] socket, data in
                Task { @MainActor in
                    guard let self else {
                        Darwin.close(socket)
                        return
                    }
                    guard let request = Self.parseRequest(data) else {
                        self.respond(socket, status: 400, body: "invalid request")
                        return
                    }
                    self.handle(request, on: socket)
                }
            }
            listener = newListener
            newListener.start()
            isListening = true
        } catch {
            isListening = false
        }
    }

    func stop() {
        listener?.stop()
        listener = nil
        isListening = false
        BoringViewCoordinator.shared.updateCodexPinnedTasks([])
    }

    func rotatePairingToken() {
        pairingToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(pairingToken, forKey: "codexActivityPairingToken")
        lastReceivedAt = nil
        BoringViewCoordinator.shared.updateCodexPinnedTasks([])
    }

    private func handle(_ request: LocalRequest, on socket: Int32) {
        guard request.method == "POST", request.path == "/v1/snapshot" else {
            respond(socket, status: 404, body: "not found")
            return
        }
        guard constantTimeEqual(request.authorization, "Bearer \(pairingToken)") else {
            respond(socket, status: 401, body: "unauthorized")
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(CodexActivitySnapshot.self, from: request.body),
              snapshot.tasks.count <= 64,
              snapshot.tasks.allSatisfy({
                  $0.id.count <= 256 && $0.title.count <= 300 && $0.latestReply.count <= 4000
                    && ($0.messages?.count ?? 0) <= 12
                    && ($0.messages?.allSatisfy({ $0.id.count <= 256 && $0.text.count <= 2000 }) ?? true)
              }),
              snapshot.event.map({ $0.taskID.count <= 256 && $0.title.count <= 300 }) ?? true else {
            respond(socket, status: 400, body: "invalid snapshot")
            return
        }
        BoringViewCoordinator.shared.applyCodexSnapshot(snapshot)
        lastReceivedAt = Date()
        respond(socket, status: 204, body: "")
    }

    private func respond(_ socket: Int32, status: Int, body: String) {
        let reason = status == 204 ? "No Content" : status == 200 ? "OK" : "Error"
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(bodyData)
        response.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < rawBuffer.count {
                let result = Darwin.send(socket, baseAddress.advanced(by: sent), rawBuffer.count - sent, 0)
                guard result > 0 else { break }
                sent += result
            }
        }
        Darwin.shutdown(socket, SHUT_RDWR)
        Darwin.close(socket)
    }

    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    private static func parseRequest(_ data: Data) -> LocalRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else { return nil }
        let headerLines = headerText.components(separatedBy: "\r\n")
        guard let firstLine = headerLines.first else { return nil }
        let requestParts = firstLine.split(separator: " ")
        guard requestParts.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let lengthValue = headers["content-length"], let length = Int(lengthValue), length >= 0, length <= 500_000 else { return nil }
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + length else { return nil }
        return LocalRequest(
            method: String(requestParts[0]),
            path: String(requestParts[1]),
            authorization: headers["authorization"] ?? "",
            body: data[bodyStart..<(bodyStart + length)]
        )
    }
}

private final class LoopbackSocketServer {
    private let listenerSocket: Int32
    private let acceptQueue = DispatchQueue(label: "com.boringnotch.codex-activity.accept", qos: .utility)
    private let clientQueue = DispatchQueue(label: "com.boringnotch.codex-activity.client", qos: .utility, attributes: .concurrent)
    private let onRequest: (Int32, Data) -> Void
    private let lock = NSLock()
    private var stopped = false

    init(port: UInt16, onRequest: @escaping (Int32, Data) -> Void) throws {
        self.onRequest = onRequest
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            Darwin.close(socket)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard Darwin.listen(socket, 16) == 0 else {
            let code = errno
            Darwin.close(socket)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        listenerSocket = socket
    }

    func start() {
        acceptQueue.async { [weak self] in self?.acceptConnections() }
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        Darwin.shutdown(listenerSocket, SHUT_RDWR)
        Darwin.close(listenerSocket)
    }

    private func acceptConnections() {
        while true {
            lock.lock()
            let shouldStop = stopped
            lock.unlock()
            if shouldStop { return }

            var address = sockaddr()
            var addressLength = socklen_t(MemoryLayout<sockaddr>.size)
            let client = Darwin.accept(listenerSocket, &address, &addressLength)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            clientQueue.async { [onRequest] in
                Self.setClientOptions(client)
                let request = Self.readRequest(client)
                onRequest(client, request)
            }
        }
    }

    private static func setClientOptions(_ socket: Int32) {
        var noSignal: Int32 = 1
        _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func readRequest(_ socket: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count <= 524_288 {
            let count = Darwin.recv(socket, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
            if requestIsComplete(data) { break }
        }
        return data
    }

    private static func requestIsComplete(_ data: Data) -> Bool {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter) else { return data.count >= 8_192 }
        guard let header = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else { return true }
        guard let line = header.components(separatedBy: "\r\n").dropFirst().first(where: { $0.lowercased().hasPrefix("content-length:") }),
              let length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)),
              (0...500_000).contains(length) else { return true }
        return data.count >= headerRange.upperBound + length
    }
}

private struct LocalRequest {
    let method: String
    let path: String
    let authorization: String
    let body: Data
}
