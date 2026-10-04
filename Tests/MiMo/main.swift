import Foundation
func check(_ result: @autoclosure () throws -> Bool) rethrows { let value = try result(); precondition(value) }
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Data("_app://-\0\u{1}mimo.pinned".utf8)
func value(_ name: String) throws -> Data? { try ChromiumLocalStorageReader.value(for: key, at: root.appendingPathComponent(name)) }
try check(try value("table") == Data("\u{1}[\"ses_one\",\"ses_two\"]".utf8))
try check(try value("wal") == Data("\u{1}[\"ses_two\"]".utf8))
try check(try value("deleted") == nil)
try check(try value("partial") == Data("\u{1}[\"ses_two\"]".utf8))
try check(try value("fragmented")?.count == 40012)
for name in ["bad", "badcrc"] {
    do { _ = try value(name); preconditionFailure("invalid store accepted") } catch {}
}
func reader(_ store: String) -> MiMoTasksReader {
    MiMoTasksReader(databaseURL: root.appendingPathComponent("mimocode.db"), storageURL: root.appendingPathComponent(store))
}
let rows = try JSONSerialization.jsonObject(with: reader("table").read()) as! [[String: Any]]
precondition(rows.map { $0["id"] as! String } == ["mimo:ses_one", "mimo:ses_two"])
precondition(rows.allSatisfy { $0["provider"] as? String == "mimo" && $0["status"] as? String == "idle" && $0["latestReply"] as? String == "body-69" })
try check(try reader("empty").pinnedIDs() == [])
try check(try reader("deleted").pinnedIDs() == [])
try check(try reader("utf16").pinnedIDs() == ["ses_two"])
try check(try reader("fragmented").pinnedIDs() == ["ses_two"])
var cursor: String?; var texts: [String] = []; var counts: [Int] = []
repeat {
    let page = try JSONSerialization.jsonObject(with: reader("table").readHistory("ses_one", cursor: cursor)) as! [String: Any]
    let messages = page["messages"] as! [[String: String]]
    counts.append(messages.count); texts = messages.map { $0["text"]! } + texts
    cursor = page["nextCursor"] as? String
} while cursor != nil
precondition(counts == [32, 32, 6] && texts == (0..<70).map { "body-\($0)" })
for id in ["ses_unpinned", "ses_child", "ses_archived", "../ses_one"] {
    do { _ = try reader("table").readHistory(id, cursor: nil); preconditionFailure("unapproved history") } catch {}
}
do { _ = try reader("table").readHistory("ses_one", cursor: "garbage"); preconditionFailure("bad cursor") } catch {}
print("PASS: MiMo pinned WAL/table/delete/compaction, fragmented logs, CRC, UTF16, history paging and content isolation")

let mixed = try JSONSerialization.jsonObject(with: reader("mixed").read()) as! [[String: Any]]
precondition(mixed.count == 1 && mixed[0]["id"] as? String == "mimo:ses_one")
var tieCursor: String?, tieTexts: [String] = []
repeat {
    let page = try JSONSerialization.jsonObject(with: reader("tie").readHistory("ses_tie", cursor: tieCursor)) as! [String: Any]
    tieTexts = (page["messages"] as! [[String: String]]).map { $0["text"]! } + tieTexts
    tieCursor = page["nextCursor"] as? String
} while tieCursor != nil
precondition(tieTexts == (0..<70).map { "body-\($0)" })
try check(try ChromiumLocalStorageReader.decodeSnappy([5,0,97,1,1]) == Array("aaaaa".utf8))
try check(try ChromiumLocalStorageReader.decodeSnappy([6,8,97,98,99,10,3,0]) == Array("abcabc".utf8))
try check(try ChromiumLocalStorageReader.decodeSnappy([6,8,97,98,99,11,3,0,0,0]) == Array("abcabc".utf8))
do { _ = try ChromiumLocalStorageReader.decodeSnappy([5,0,97,1,0]); preconditionFailure("zero-offset accepted") } catch {}
print("PASS: archived/child/duplicate filtering, equal-timestamp pagination and all Snappy copy types")

let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
let decoded = try decoder.decode([CodexPinnedTask].self, from: reader("table").read())
precondition(decoded.count == 2 && decoded[0].source == .mimo && decoded[0].messages?.count == 12)
print("PASS: MiMo payload decodes into shared conversation model")
let contexts = try reader("mixed").contexts()
precondition(contexts.count == 1 && contexts.first?.directory == "/tmp/project")
do { _ = try reader("table").context("ses_unpinned"); preconditionFailure("unpinned context accepted") } catch {}
let liveTasks = try decoder.decode([CodexPinnedTask].self, from: reader("table").read(statuses: ["ses_one":"idle", "ses_two":"waiting"]))
precondition(liveTasks[0].status == .completed && liveTasks[1].status == .waiting)
let offlineTasks = try decoder.decode([CodexPinnedTask].self, from: reader("table").read())
precondition(offlineTasks.allSatisfy { $0.status == .idle })
print("PASS: pin-scoped control context, authoritative live status and offline idle fallback")
