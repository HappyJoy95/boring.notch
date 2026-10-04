import Darwin
import Foundation

/// Routes an explicit user instruction to the Codex Desktop process that owns
/// a task. This is a private, versioned Codex Desktop IPC and may be unavailable
/// on unsupported Desktop versions.
enum CodexDesktopInstructionSender {
    private static let maxFrameBytes = 8 * 1024 * 1024
    private static let ownerDiscoveryVersion = 1
    private static let startTurnVersion = 2

    static func send(threadID: String, prompt: String) throws {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !threadID.isEmpty, threadID.count <= 256 else { throw SendError.invalidInput }
        guard !text.isEmpty, text.count <= 12_000 else { throw SendError.invalidInput }

        let socketPath = defaultSocketPath()
        guard socketOwnedByCurrentUser(socketPath) else { throw SendError.unavailable }
        let descriptor = try connect(to: socketPath)
        defer { close(descriptor) }

        // Initialize returns result.clientId; reject unexpected replies before
        // any instruction is sent.
        let initialized = try request(descriptor, method: "initialize", version: 0, params: [
            "clientType": "boring-notch",
        ], timeoutMs: 1_500)
        guard let client = (initialized["result"] as? [String: Any])?["clientId"] as? String,
              !client.isEmpty else { throw SendError.protocolMismatch }

        let ownerResponse = try request(descriptor, method: "thread-owner-discovery", version: ownerDiscoveryVersion,
            params: ["hostId": "local", "conversationId": threadID], sourceClientID: client)
        guard let owner = ownerResponse["handledByClientId"] as? String, !owner.isEmpty, owner != client else {
            throw SendError.ownerUnavailable
        }

        let commandID = UUID().uuidString.lowercased()
        let response = try request(descriptor, method: "thread-follower-start-turn", version: startTurnVersion,
            params: [
                "conversationId": threadID,
                "turnStart": [
                    "request": [
                        "threadId": threadID,
                        "clientUserMessageId": commandID,
                        "input": [["type": "text", "text": text, "text_elements": []]],
                        "turnTrigger": "boringNotch",
                    ],
                    "context": ["inheritThreadSettings": true],
                ],
            ], sourceClientID: client, targetClientID: owner)
        guard response["handledByClientId"] as? String == owner,
              turnID(in: response) != nil else { throw SendError.protocolMismatch }
    }

    private static func defaultSocketPath() -> String {
        let environment = ProcessInfo.processInfo.environment
        let home = environment["CODEX_HOME"] ?? ((environment["HOME"] ?? NSHomeDirectory()) + "/.codex")
        return home + "/ipc/ipc.sock"
    }

    private static func socketOwnedByCurrentUser(_ path: String) -> Bool {
        var info = stat()
        guard path.withCString({ lstat($0, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0 else { return false }
        return true
    }

    private static func connect(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SendError.unavailable }
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied = path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: capacity) { target in
                    strlcpy(target, source, capacity)
                }
            }
        }
        guard copied < capacity else { close(fd); throw SendError.unavailable }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); throw SendError.unavailable }
        return fd
    }

    private static func request(_ fd: Int32, method: String, version: Int, params: [String: Any],
                                sourceClientID: String = "initializing-client", targetClientID: String? = nil,
                                timeoutMs: Int = 15_000) throws -> [String: Any] {
        let requestID = UUID().uuidString.lowercased()
        var message: [String: Any] = [
            "type": "request", "requestId": requestID, "sourceClientId": sourceClientID,
            "version": version, "method": method, "params": params, "timeoutMs": timeoutMs,
        ]
        if let targetClientID { message["targetClientId"] = targetClientID }
        let payload = try JSONSerialization.data(withJSONObject: message)
        guard !payload.isEmpty, payload.count <= maxFrameBytes else { throw SendError.invalidInput }
        var length = UInt32(payload.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        try writeAll(fd, data: frame)

        while true {
            let header = try readExactly(fd, count: 4)
            let size = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
            guard size > 0, size <= maxFrameBytes else { throw SendError.protocolMismatch }
            let data = try readExactly(fd, count: Int(size))
            guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SendError.protocolMismatch
            }
            guard envelope["requestId"] as? String == requestID else { continue }
            if envelope["error"] != nil { throw SendError.protocolMismatch }
            return envelope
        }
    }

    private static func turnID(in envelope: [String: Any]) -> String? {
        let result = envelope["result"] as? [String: Any]
        let nested = result?["result"] as? [String: Any]
        let turn = (nested?["turn"] as? [String: Any]) ?? (result?["turn"] as? [String: Any])
        return turn?["id"] as? String
    }

    private static func writeAll(_ fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw SendError.protocolMismatch }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw SendError.outcomeUnknown }
                offset += count
            }
        }
    }

    private static func readExactly(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { throw SendError.protocolMismatch }
            var offset = 0
            while offset < count {
                let received = Darwin.read(fd, base.advanced(by: offset), count - offset)
                guard received > 0 else { throw SendError.outcomeUnknown }
                offset += received
            }
        }
        return data
    }

    private enum SendError: LocalizedError {
        case invalidInput, unavailable, ownerUnavailable, protocolMismatch, outcomeUnknown
        var errorDescription: String? {
            switch self {
            case .invalidInput: return "指令为空或过长。"
            case .unavailable: return "未找到可用的 Codex Desktop 本地连接。"
            case .ownerUnavailable: return "Codex 没有正在管理这个会话的桌面进程。"
            case .protocolMismatch: return "Codex Desktop IPC 协议不兼容，指令未确认发送。"
            case .outcomeUnknown: return "连接中断，发送结果不确定；为避免重复，未自动重试。请在 Codex 中确认。"
            }
        }
    }
}
