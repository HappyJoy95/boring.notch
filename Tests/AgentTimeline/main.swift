import Foundation
func message(_ id: String, _ time: Double, _ index: Int, _ text: String = "") throws -> CodexTaskMessage {
    let data = try JSONSerialization.data(withJSONObject: ["id": id, "role": "assistant", "text": text, "timelineTime": time, "timelineIndex": index])
    return try JSONDecoder().decode(CodexTaskMessage.self, from: data)
}
let first = try message("a", 10, 0)
let middle = try message("b", 10, 1)
let last = try message("c", 20, 0)
let merged = AgentMessageTimeline.merge([first, last], [middle, try message("a", 10, 0, "updated")])
precondition(merged.map(\.id) == ["a", "b", "c"])
precondition(merged[0].text == "updated")
let legacy = ["a", "c"].map { CodexTaskMessage(id: $0, role: .assistant, text: "") }
let incoming = ["b", "c"].map { CodexTaskMessage(id: $0, role: .assistant, text: "") }
precondition(AgentMessageTimeline.merge(legacy, incoming).map(\.id) == ["a", "b", "c"])
precondition(AgentMessageTimeline.merge([first, first], [first]).count == 1)
print("PASS: earlier live message ordering, within-turn order, updates, legacy anchors, deduplication")
