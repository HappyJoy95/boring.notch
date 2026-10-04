import Foundation
let raw = Data("""
[{"id":"workbuddy:12345678-1234-1234-1234-123456789abc","provider":"workbuddy","title":"Test","status":"completed","latestReply":"","messages":[],"updatedAt":"2026-10-04T00:00:00Z"}]
""".utf8)
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
let task = try decoder.decode([CodexPinnedTask].self, from: raw)[0]
precondition(task.isWorkBuddy && task.providerName == "WorkBuddy")
precondition(task.openURL?.scheme == "workbuddy")
precondition(task.openURL?.host == "chat")
var tracker = CodexUnreadTracker()
precondition(tracker.update([task]).isEmpty)
let codex = CodexPinnedTask(id: "12345678-1234-1234-1234-123456789abc", title: "Test", status: .running, latestReply: "")
precondition(!codex.isWorkBuddy && codex.openURL?.scheme == "codex")
precondition(task.id != codex.id)
precondition(tracker.update([task, codex]).isEmpty)
precondition(tracker.entries.count == 2)
tracker.markRead(task.id)
precondition(tracker.entries[codex.id]?.status == .running)
print("PASS: provider decoding, deep links, distinct IDs and independent read states")
