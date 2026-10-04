import Foundation
import SQLite3

/// MiMo Desktop's pinned engine sessions. All queries are read-only and pin-scoped.
/// Live status is supplied by the bridge; an absent connection never implies completion.
struct MiMoTasksReader {
    let databaseURL: URL
    let storageURL: URL
    enum ReadError: Error { case invalid, unavailable, notPinned }

    static var local: Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { value in
            value.hasPrefix("/") ? URL(fileURLWithPath: value) : nil
        } ?? home.appendingPathComponent(".local/share")
        return Self(databaseURL: dataHome.appendingPathComponent("mimocode/mimocode.db"),
                    storageURL: home.appendingPathComponent("Library/Application Support/Xiaomi MiMo/Local Storage/leveldb"))
    }

    private func validID(_ id: String) -> Bool {
        id.hasPrefix("ses_") && id.utf8.count <= 128 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45
        }
    }

    func pinnedIDs() throws -> [String] {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return [] }
        let key = Data("_app://-\0\u{1}mimo.pinned".utf8)
        guard let data = try ChromiumLocalStorageReader.value(for: key, at: storageURL) else { return [] }
        guard data.count <= 128 * 1024, let encoding = data.first else { throw ReadError.invalid }
        let text: String?
        switch encoding {
        case 0: text = String(data: data.dropFirst(), encoding: .utf16LittleEndian)
        case 1: text = String(data: data.dropFirst(), encoding: .isoLatin1)
        default: throw ReadError.invalid
        }
        guard let text, let json = text.data(using: .utf8),
              let ids = try JSONSerialization.jsonObject(with: json) as? [String], ids.count <= 10_000 else { throw ReadError.invalid }
        var seen = Set<String>()
        return ids.filter { validID($0) && seen.insert($0).inserted }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard try databaseURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ReadError.invalid }
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; throw ReadError.unavailable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw ReadError.unavailable }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        return try body(db)
    }

    private func rows(_ db: OpaquePointer, sql: String, parameters: [String]) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ReadError.invalid }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, parameter) in parameters.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), parameter, -1, transient) == SQLITE_OK else { throw ReadError.invalid }
        }
        var result: [[String]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw ReadError.unavailable }
            result.append((0..<sqlite3_column_count(statement)).map { index in
                sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
            })
        }
    }
    private func session(_ db: OpaquePointer, id: String) throws -> [String]? {
        try rows(db, sql: "SELECT id, substr(title,1,300), time_updated, directory FROM session WHERE id=? AND parent_id IS NULL AND time_archived IS NULL", parameters: [id]).first
    }
    private struct Cursor: Codable { let time: Int64; let id: String }
    private func page(_ db: OpaquePointer, id: String, cursor: String?) throws -> [String: Any] {
        var parameters = [id], boundary = ""
        if let cursor {
            guard cursor.utf8.count < 1024, let data = Data(base64Encoded: cursor),
                  let value = try? JSONDecoder().decode(Cursor.self, from: data), value.time >= 0,
                  value.id.utf8.count <= 256 else { throw ReadError.invalid }
            boundary = " AND (m.time_created<CAST(? AS INTEGER) OR (m.time_created=CAST(? AS INTEGER) AND m.id<?))"
            parameters += [String(value.time), String(value.time), value.id]
        }
        // SQL prefilters main-agent messages with displayable text. Tool/reasoning parts never leave SQLite.
        let sql = """
        SELECT m.id, json_extract(m.data,'$.role'), m.time_created,
          (SELECT substr(group_concat(body,char(10)),1,4000) FROM
            (SELECT substr(json_extract(p.data,'$.text'),1,4000) AS body FROM part p
             WHERE p.message_id=m.id AND p.session_id=m.session_id
               AND json_extract(p.data,'$.type')='text'
               AND coalesce(json_extract(p.data,'$.synthetic'),0)=0
               AND coalesce(json_extract(p.data,'$.ignored'),0)=0
             ORDER BY p.time_created,p.id LIMIT 64))
        FROM message m WHERE m.session_id=? AND m.agent_id='main'
          AND json_extract(m.data,'$.role') IN ('user','assistant')
          AND EXISTS (SELECT 1 FROM part p WHERE p.message_id=m.id AND p.session_id=m.session_id
            AND json_extract(p.data,'$.type')='text'
            AND coalesce(json_extract(p.data,'$.synthetic'),0)=0
            AND coalesce(json_extract(p.data,'$.ignored'),0)=0
            AND trim(coalesce(json_extract(p.data,'$.text'),''))<>'')
        \(boundary) ORDER BY m.time_created DESC,m.id DESC LIMIT 33
        """
        let records = try rows(db, sql: sql, parameters: parameters)
        let selected = Array(records.prefix(32))
        let messages = selected.reversed().map { row -> [String: String] in
            ["id": row[0], "role": row[1], "text": String(row[3].prefix(4000)),
             "phase": row[1] == "assistant" ? "final_answer" : ""]
        }
        var result: [String: Any] = ["messages": messages]
        if records.count > 32, let last = selected.last, let time = Int64(last[2]) {
            result["nextCursor"] = try JSONEncoder().encode(Cursor(time: time, id: last[0])).base64EncodedString()
        }
        return result
    }
    struct Context: Codable, Equatable {
        let id: String
        let directory: String
    }
    func contexts() throws -> [Context] {
        let ids = try pinnedIDs()
        guard !ids.isEmpty else { return [] }
        return try withDatabase { db in
            try ids.prefix(32).compactMap { id in
                guard let record = try session(db, id: id), record[3].hasPrefix("/"), record[3].utf8.count <= 4096 else { return nil }
                return Context(id: id, directory: record[3])
            }
        }
    }
    func context(_ id: String) throws -> Context {
        guard validID(id), let value = try contexts().first(where: { $0.id == id }) else { throw ReadError.notPinned }
        return value
    }
    private func displayStatus(_ db: OpaquePointer, id: String, live: String?) throws -> String {
        switch live {
        case "running", "waiting", "interrupted", "completed": return live!
        case "idle":
            let latest = try rows(db, sql: """
                SELECT json_extract(data,'$.role'), json_extract(data,'$.time.completed'), json_extract(data,'$.error.name')
                FROM message WHERE session_id=? AND agent_id='main' AND json_extract(data,'$.role') IN ('user','assistant')
                ORDER BY time_created DESC,id DESC LIMIT 1
                """, parameters: [id]).first
            guard let latest, latest[0] == "assistant" else { return "idle" }
            if !latest[2].isEmpty { return "interrupted" }
            return latest[1].isEmpty ? "idle" : "completed"
        default: return "idle"
        }
    }

    func read(statuses: [String: String] = [:]) throws -> Data {
        let ids = try pinnedIDs()
        guard !ids.isEmpty else { return Data("[]".utf8) }
        return try withDatabase { db in
            var tasks: [[String: Any]] = []
            for id in ids.prefix(32) {
                guard let record = try session(db, id: id) else { continue }
                let messages = try page(db, id: id, cursor: nil)["messages"] as? [[String: String]] ?? []
                let number = Double(record[2]) ?? 0
                let date = Date(timeIntervalSince1970: number / 1000)
                tasks.append(["id": "mimo:" + id, "provider": "mimo", "title": record[1], "status": try displayStatus(db, id: id, live: statuses[id]),
                              "updatedAt": ISO8601DateFormatter().string(from: date),
                              "latestReply": messages.last(where: { $0["role"] == "assistant" })?["text"] ?? "",
                              "messages": Array(messages.suffix(12))])
            }
            return try JSONSerialization.data(withJSONObject: tasks)
        }
    }
    func readHistory(_ id: String, cursor: String?) throws -> Data {
        guard validID(id), try pinnedIDs().contains(id) else { throw ReadError.notPinned }
        return try withDatabase { db in
            guard try session(db, id: id) != nil else { throw ReadError.notPinned }
            return try JSONSerialization.data(withJSONObject: page(db, id: id, cursor: cursor))
        }
    }
}
