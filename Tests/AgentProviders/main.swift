import Foundation
func decoded(_ id: String, _ provider: String? = nil, status: String = "running") throws -> CodexPinnedTask {
    var row: [String: Any] = ["id": id, "title": "Test", "status": status, "latestReply": "", "messages": [], "updatedAt": "2026-10-04T00:00:00Z"]
    if let provider { row["provider"] = provider }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(CodexPinnedTask.self, from: JSONSerialization.data(withJSONObject: row))
}
let codex = try decoded("same")
let buddy = try decoded("same", "workbuddy")
let third = try decoded("same", "third")
precondition(codex.source == .codex && codex.id == "same")
precondition(buddy.source == .workBuddy && buddy.id == "workbuddy:same")
precondition(third.source.rawValue == "third" && third.id == "third:same")
precondition(third.openURL == nil && third.providerName != "Codex")
let legacyBuddy = try decoded("workbuddy:same")
let prefixedCodex = try decoded("codex:same", "codex")
precondition(legacyBuddy.id == buddy.id && prefixedCodex.id == codex.id)
do { _ = try decoded("workbuddy:same", "codex"); preconditionFailure("mixed source accepted") } catch {}
let roundTrip = try JSONDecoder().decode(CodexPinnedTask.self, from: JSONEncoder().encode(third))
precondition(roundTrip == third)
let previous = [codex, buddy, third]
let result = AgentTaskSnapshots.merge(previous: previous, updates: [.codex: [], .workBuddy: nil])
precondition(result.map(\.id) == [buddy.id, third.id])
let failed = AgentTaskSnapshots.merge(previous: previous, updates: [.codex: nil, .workBuddy: nil])
precondition(failed == previous)
let push = AgentTaskSnapshots.merge(previous: previous, updates: [.codex: [codex]])
precondition(push == previous)
precondition(AgentTaskSnapshots.validated([buddy], for: .codex) == nil)
precondition(AgentTaskSnapshots.validated([buddy, buddy], for: .workBuddy) == nil)
precondition(AgentTaskSnapshots.validated([], for: .codex) == [])
var tracker = CodexUnreadTracker()
precondition(tracker.update(previous).isEmpty)
let finished = try [decoded("same", status: "completed"), decoded("same", "workbuddy", status: "completed"), decoded("same", "third", status: "completed")]
precondition(tracker.update(finished) == Set(finished.map(\.id)))
tracker.markRead(buddy.id)
let restored = try JSONDecoder().decode(CodexUnreadTracker.self, from: JSONEncoder().encode(tracker))
precondition(restored.unreadIDs == [codex.id, third.id])
print("PASS: source identity, compatibility, unknown source, snapshot isolation and unread persistence")
let mimo = try decoded("same", "mimo")
precondition(mimo.source == .mimo && mimo.id == "mimo:same" && mimo.providerName == "MiMo Desktop")
precondition(mimo.openURL == nil)
let withMiMo = AgentTaskSnapshots.merge(previous: [codex, buddy, mimo], updates: [.mimo: []])
precondition(withMiMo == [codex, buddy])
print("PASS: MiMo source identity and independent removal")
