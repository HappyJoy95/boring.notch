import Foundation
import SQLite3

/// Read-only adapter for WorkBuddy's current-account pinned sessions.
/// Never accesses credentials, tool results or reasoning records.
enum WorkBuddyTasksReader {
    /// Strip transport-injected context before truncating or exposing messages to the UI.
    static func displayText(_ text: String, role: String) -> String {
        if role == "user",
           let query = try? NSRegularExpression(pattern: "(?s)<user_query>(.*?)</user_query>") {
            let matches = query.matches(in: text, range: NSRange(text.startIndex..., in: text))
            if !matches.isEmpty {
                return matches.compactMap { match in
                    Range(match.range(at: 1), in: text).map { String(text[$0]) }
                }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        var result = text
        for tag in ["system-reminder", "memory_and_skills_reminder", "additional_data",
                    "current_time", "connector-status", "user_info", "project_context",
                    "project_layout", "identity_context", "product_identity",
                    "craft_mode", "manually_attached_skills", "automation_system_reminder"] {
            guard let expression = try? NSRegularExpression(
                pattern: "(?s)<" + tag + "(?:\\s[^>]*)?>.*?(?:</" + tag + ">|$)") else { continue }
            result = expression.stringByReplacingMatches(in: result,
                range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var root: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".workbuddy") }
    private enum ReadError: Error { case unavailable, invalidData }

    private static func json(_ url: URL) throws -> [String: Any] {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? 0) <= 2_000_000 else { throw ReadError.invalidData }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw ReadError.invalidData }
        return object
    }

    private static func records() throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let snapshot = try json(root.appendingPathComponent("storage/skeleton/account-snapshot.json"))
        guard let account = snapshot["primary"] as? [String: Any], let uid = account["uid"] as? String,
              !uid.isEmpty else { return [] }
        guard !uid.contains("/") else { throw ReadError.invalidData }
        let storage = root.appendingPathComponent("storage")
        let folders = try FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent == "user-" + uid || $0.lastPathComponent.hasPrefix("user-" + uid + "-") }
        var ids: [String] = []
        for folder in folders {
            let url = folder.appendingPathComponent("global/conversations.json")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let pins = try json(url)["pinned"] as? [[String: Any]] ?? []
            for pin in pins {
                if let id = pin["id"] as? String, UUID(uuidString: id) != nil, !ids.contains(id) { ids.append(id) }
            }
        }
        guard !ids.isEmpty else { return [] }
        var db: OpaquePointer?
        let path = root.appendingPathComponent("workbuddy.db").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; throw ReadError.unavailable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        let sql = "SELECT id, coalesce(custom_title,title,''), status, updated_at FROM sessions WHERE id=? AND user_id=? AND deleted_at IS NULL AND status<>'archived'"
        var result: [[String: Any]] = []
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for id in ids.prefix(32) {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw ReadError.invalidData }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, id, -1, transient)
            sqlite3_bind_text(statement, 2, uid, -1, transient)
            if sqlite3_step(statement) == SQLITE_ROW {
                func text(_ index: Int32) -> String {
                    guard let value = sqlite3_column_text(statement, index) else { return "" }
                    return String(cString: value)
                }
                result.append(["id": text(0), "title": text(1), "status": text(2), "updatedAt": text(3)])
            }
        }
        return result
    }

    private static func historyFile(_ id: String) throws -> URL? {
        guard UUID(uuidString: id) != nil else { throw ReadError.invalidData }
        let projects = root.appendingPathComponent("projects")
        for folder in try FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
            let file = folder.appendingPathComponent(id + ".jsonl")
            if FileManager.default.fileExists(atPath: file.path) {
                guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
                return file
            }
        }
        return nil
    }

    private static func page(_ id: String, cursor: String?) throws -> [String: Any] {
        guard let file = try historyFile(id) else { return ["messages": [[String: String]]()] }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let end: UInt64
        if let cursor {
            guard let value = UInt64(cursor), value <= size else { throw ReadError.invalidData }
            end = value
        } else { end = size }
        var start = end > 131072 ? end - 131072 : 0
        try handle.seek(toOffset: start)
        var data = try handle.read(upToCount: Int(end - start)) ?? Data()
        if start > 0 {
            guard let newline = data.firstIndex(of: 10) else { throw ReadError.invalidData }
            let skipped = data.distance(from: data.startIndex, to: newline) + 1
            data.removeFirst(skipped)
            start += UInt64(skipped)
        }
        var offset = start
        var messages: [(UInt64, [String: String])] = []
        for line in data.split(separator: 10, omittingEmptySubsequences: false) {
            defer { offset += UInt64(line.count + 1) }
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  row["type"] as? String == "message", let role = row["role"] as? String,
                  ["user", "assistant"].contains(role) else { continue }
            let parts = row["content"] as? [[String: Any]] ?? []
            let rawText = (row["content"] as? String) ?? parts.compactMap { part in
                ["text", "input_text", "output_text"].contains(part["type"] as? String ?? "")
                    ? part["text"] as? String : nil
            }.joined(separator: "\n")
            let text = displayText(rawText, role: role)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            messages.append((offset, ["id": row["id"] as? String ?? "wb-\(offset)", "role": role,
                "text": String(text.prefix(4000)), "phase": role == "assistant" ? "final_answer" : ""]))
        }
        let selected = Array(messages.suffix(32))
        var result: [String: Any] = ["messages": selected.map { $0.1 }]
        let next = messages.count > 32 ? selected.first?.0 ?? start : start
        if next > 0, next < end { result["nextCursor"] = String(next) }
        return result
    }

    static func read() throws -> Data {
        let tasks = try records().map { record -> [String: Any] in
            let id = record["id"] as! String
            let messages = (try? page(id, cursor: nil)["messages"] as? [[String: String]]) ?? []
            let raw = record["status"] as? String ?? ""
            let status: String
            switch raw {
            case "working", "running", "active": status = "running"
            case "waiting", "waiting_permission", "waiting_input": status = "waiting"
            case "completed": status = "completed"
            case "cancelled", "terminated", "error": status = "interrupted"
            default: status = "idle"
            }
            let value = record["updatedAt"] as? String ?? ""
            let date: Date
            if let number = Double(value) { date = Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number) }
            else { date = ISO8601DateFormatter().date(from: value) ?? Date(timeIntervalSince1970: 0) }
            return ["id": "workbuddy:" + id, "provider": "workbuddy", "title": record["title"] ?? "WorkBuddy",
                    "status": status, "latestReply": messages.last(where: { $0["role"] == "assistant" })?["text"] ?? "",
                    "messages": Array(messages.suffix(12)), "updatedAt": ISO8601DateFormatter().string(from: date)]
        }
        return try JSONSerialization.data(withJSONObject: tasks)
    }

    static func validatePinnedTask(_ taskID: String) throws {
        guard taskID.hasPrefix("workbuddy:"),
              try records().contains(where: { "workbuddy:" + ($0["id"] as? String ?? "") == taskID })
        else { throw ReadError.invalidData }
    }

    static func readHistory(_ taskID: String, cursor: String?) throws -> Data {
        let id = String(taskID.dropFirst("workbuddy:".count))
        guard taskID.hasPrefix("workbuddy:"), try records().contains(where: { $0["id"] as? String == id }) else { throw ReadError.invalidData }
        return try JSONSerialization.data(withJSONObject: page(id, cursor: cursor))
    }
}
