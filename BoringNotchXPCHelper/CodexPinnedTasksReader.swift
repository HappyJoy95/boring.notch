import Darwin
import Foundation

enum CodexPinnedTasksReader {
    static func readPinnedTask(_ threadID: String) throws -> Data {
        guard !threadID.isEmpty, threadID.count <= 256 else { throw ReaderError.invalidThreadID }
        let client = try CodexAppServerClient()
        let listing = try client.request("thread/list", id: 2, params: [
            "limit": 200,
            "archived": false,
            "isPinned": true,
            "useStateDbOnly": true,
        ])
        guard let result = listing["result"] as? [String: Any],
              let threads = result["data"] as? [[String: Any]],
              let thread = threads.first(where: { candidate in
                  (candidate["id"] as? String) == threadID
                    && candidate["archived"] as? Bool != true
                    && candidate["isArchived"] as? Bool != true
                    && (candidate["section"] as? [String: Any])?["name"] as? String == "Pinned"
              }) else { throw ReaderError.notPinned }

        let turns = try client.requestTurns([(3, threadID)])[3] ?? []
        return try JSONSerialization.data(withJSONObject: taskSnapshot(thread: thread, turns: turns))
    }

    static func validatePinnedThread(_ threadID: String) throws {
        guard !threadID.isEmpty, threadID.count <= 256 else { throw ReaderError.invalidThreadID }
        let client = try CodexAppServerClient()
        let listing = try client.request("thread/list", id: 2, params: [
            "limit": 200,
            "archived": false,
            "isPinned": true,
            "useStateDbOnly": true,
        ])
        guard let result = listing["result"] as? [String: Any],
              let threads = result["data"] as? [[String: Any]] else {
            throw ReaderError.invalidResponse
        }
        let isPinned = threads.contains { thread in
            (thread["id"] as? String) == threadID
                && thread["archived"] as? Bool != true
                && thread["isArchived"] as? Bool != true
                && (thread["section"] as? [String: Any])?["name"] as? String == "Pinned"
        }
        guard isPinned else { throw ReaderError.notPinned }
    }

    static func read() throws -> Data {
        let client = try CodexAppServerClient()
        let listing = try client.request("thread/list", id: 2, params: [
            "limit": 200,
            "archived": false,
            "isPinned": true,
            "useStateDbOnly": true,
        ])
        guard
            let result = listing["result"] as? [String: Any],
            let threads = result["data"] as? [[String: Any]]
        else {
            throw ReaderError.invalidResponse
        }

        let pinned = threads.filter { thread in
            guard let section = thread["section"] as? [String: Any] else { return false }
            return section["name"] as? String == "Pinned"
                && thread["archived"] as? Bool != true
                && thread["isArchived"] as? Bool != true
                && (thread["id"] as? String)?.isEmpty == false
        }.prefix(64)

        let requests: [(Int, String)] = pinned.enumerated().compactMap { index, thread in
            guard let id = thread["id"] as? String else { return nil }
            return (index + 3, id)
        }
        let turnsByRequest = try client.requestTurns(requests)

        let tasks: [[String: Any]] = requests.enumerated().compactMap { index, request in
            let thread = pinned[pinned.startIndex + index]
            let turns = turnsByRequest[request.0] ?? []
            return taskSnapshot(thread: thread, turns: turns)
        }

        return try JSONSerialization.data(withJSONObject: tasks)
    }

    private static func taskSnapshot(thread: [String: Any], turns: [[String: Any]]) -> [String: Any] {
        [
            "id": thread["id"] as? String ?? "",
            "title": (thread["name"] as? String)
                ?? (thread["title"] as? String)
                ?? (thread["preview"] as? String).map { String($0.prefix(64)) }
                ?? "Untitled task",
            "status": displayStatus(thread: thread, turns: turns),
            "latestReply": latestFinalReply(in: turns),
            "messages": latestMessages(in: turns),
            "updatedAt": timestampString(thread["updatedAt"]),
        ]
    }

    private static func latestFinalReply(in turns: [[String: Any]]) -> String {
        for turn in turns {
            let items = (turn["items"] as? [[String: Any]])
                ?? ((turn["turn"] as? [String: Any])?["items"] as? [[String: Any]])
                ?? []
            if let finalItem = items.reversed().first(where: {
                $0["type"] as? String == "agentMessage"
                    && $0["phase"] as? String == "final_answer"
                    && ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }), let text = finalItem["text"] as? String {
                return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
            }
        }
        return ""
    }

    private static func latestMessages(in turns: [[String: Any]]) -> [[String: String]] {
        guard let turn = turns.first else { return [] }
        let items = (turn["items"] as? [[String: Any]])
            ?? ((turn["turn"] as? [String: Any])?["items"] as? [[String: Any]])
            ?? []
        return items.enumerated().compactMap { index, item in
            let type = item["type"] as? String
            let role: String
            switch type {
            case "userMessage": role = "user"
            case "agentMessage":
                guard ["commentary", "final_answer"].contains(item["phase"] as? String ?? "") else { return nil }
                role = "assistant"
            default: return nil // Never surface reasoning or tool payloads.
            }
            let text = messageText(item).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return [
                "id": (item["id"] as? String) ?? "\(index)-\(role)",
                "role": role,
                "text": String(text.prefix(2_000)),
                "phase": (item["phase"] as? String) ?? "",
            ]
        }.suffix(12).map { $0 }
    }

    private static func messageText(_ item: [String: Any]) -> String {
        if let text = item["text"] as? String { return text }
        if let content = item["content"] as? String { return content }
        if let content = item["content"] as? [[String: Any]] {
            return content.compactMap { part in
                (part["text"] as? String) ?? (part["value"] as? String)
            }.joined(separator: "\n")
        }
        return ""
    }

    private static func displayStatus(thread: [String: Any], turns: [[String: Any]]) -> String {
        let status = thread["status"] as? [String: Any]
        let flags = status?["activeFlags"] as? [String] ?? []
        if flags.contains("waitingOnApproval") { return "waiting" }
        if status?["type"] as? String == "active" { return "running" }
        if let latestTurn = turns.first, let latestStatus = latestTurn["status"] as? String {
            switch latestStatus {
            case "completed": return "completed"
            case "interrupted":
                // Desktop can expose an interrupted turn while it is still attached to
                // its live owner; completedAt/durationMs distinguish terminal history.
                if latestTurn["completedAt"] == nil && latestTurn["durationMs"] == nil {
                    return "running"
                }
                return "interrupted"
            case "inProgress", "active": return "running"
            default: break
            }
        }
        return "idle"
    }

    private static func timestampString(_ value: Any?) -> String {
        if let text = value as? String, ISO8601DateFormatter().date(from: text) != nil { return text }
        if let number = value as? NSNumber, number.doubleValue.isFinite {
            return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: number.doubleValue))
        }
        return ISO8601DateFormatter().string(from: Date())
    }

    private enum ReaderError: Error {
        case invalidThreadID
        case notPinned
        case codexNotFound
        case timedOut(String)
        case invalidResponse
        case serverRejected
    }

    private final class CodexAppServerClient {
        private let process: Process
        private let input: Pipe
        private let output: Pipe
        private var buffer = Data()

        init() throws {
            process = Process()
            input = Pipe()
            output = Pipe()
            process.executableURL = try Self.codexExecutable()
            process.arguments = ["app-server"]
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()

            try send([
                "method": "initialize",
                "id": 1,
                "params": [
                    "clientInfo": ["name": "boring-notch", "title": "Boring Notch", "version": "0.1.0"],
                    "capabilities": [:] as [String: String],
                ],
            ])
            _ = try readResponse(id: 1)
            try send(["method": "initialized", "params": [:] as [String: String]])
        }

        deinit {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }

        func request(_ method: String, id: Int, params: [String: Any]) throws -> [String: Any] {
            try send(["method": method, "id": id, "params": params])
            return try readResponse(id: id)
        }

        func requestTurns(_ requests: [(Int, String)]) throws -> [Int: [[String: Any]]] {
            guard !requests.isEmpty else { return [:] }
            var result: [Int: [[String: Any]]] = [:]
            for (id, threadID) in requests {
                do {
                    try send([
                        "method": "thread/turns/list",
                        "id": id,
                        "params": ["threadId": threadID, "limit": 1, "sortDirection": "desc", "itemsView": "full"],
                    ])
                    let messages = try readMessages(matching: [id], until: Date().addingTimeInterval(5))
                    guard let message = messages.first(where: { $0.0 == id })?.1 else {
                        result[id] = []
                        continue
                    }
                    let response = message["result"] as? [String: Any]
                    result[id] = message["error"] == nil ? ((response?["data"] as? [[String: Any]]) ?? []) : []
                } catch {
                    // A single conversation may be temporarily unavailable; still show its pinned task.
                    NSLog("Codex pinned task turn lookup failed for request %d: %@", id, String(describing: error))
                    result[id] = []
                }
            }
            return result
        }

        private static func codexExecutable() throws -> URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let knownPaths = [
                "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex").path,
            ]
            if let path = knownPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                return URL(fileURLWithPath: path)
            }
            let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            if let path = searchPath.split(separator: ":")
                .map({ URL(fileURLWithPath: String($0)).appendingPathComponent("codex").path })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                return URL(fileURLWithPath: path)
            }
            throw ReaderError.codexNotFound
        }

        private func send(_ object: [String: Any]) throws {
            var line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            line.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: line)
        }

        private func readResponse(id expectedID: Int) throws -> [String: Any] {
            let results = try readMessages(matching: [expectedID], until: Date().addingTimeInterval(5))
            guard let message = results.first(where: { $0.0 == expectedID })?.1 else {
                throw ReaderError.timedOut("request \(expectedID)")
            }
            return message
        }

        private func readMessages(matching ids: Set<Int>, until deadline: Date) throws -> [(Int, [String: Any])] {
            let descriptor = output.fileHandleForReading.fileDescriptor
            var messages: [(Int, [String: Any])] = []

            while Date() < deadline {
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    guard
                        let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                        let id = (message["id"] as? NSNumber)?.intValue,
                        ids.contains(id)
                    else { continue }
                    messages.append((id, message))
                }
                if !messages.isEmpty { return messages }

                let remaining = max(1, Int32(deadline.timeIntervalSinceNow * 1_000))
                var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let pollResult = Darwin.poll(&readiness, 1, remaining)
                if pollResult == 0 { throw ReaderError.timedOut("request IDs \(ids.sorted())") }
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    throw ReaderError.invalidResponse
                }
                var bytes = [UInt8](repeating: 0, count: 8_192)
                let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                guard count > 0 else { throw ReaderError.invalidResponse }
                buffer.append(contentsOf: bytes.prefix(count))
            }
            throw ReaderError.timedOut("request IDs \(ids.sorted())")
        }
    }
}
