import Foundation

func expect(_ expected: String, _ thread: [String: Any], _ turn: [String: Any]) {
    let actual = CodexPinnedTasksReader.displayStatus(thread: thread, turns: [turn])
    precondition(actual == expected, "Expected \(expected), got \(actual)")
}
expect("running", [:], ["status": "interrupted", "completedAt": NSNull(), "durationMs": NSNull()])
expect("running", [:], ["status": "interrupted"])
expect("interrupted", [:], ["status": "interrupted", "completedAt": 123, "durationMs": 20])
expect("interrupted", [:], ["status": "interrupted", "completedAt": NSNull(), "durationMs": 0])
expect("running", ["status": ["type": "active"]], ["status": "interrupted", "completedAt": 123])
expect("waiting", ["status": ["type": "active", "activeFlags": ["waitingOnApproval"]]], ["status": "inProgress"])
expect("completed", [:], ["status": "completed"])
print("PASS: null end fields, terminal interruption, active status, approval, completion")
