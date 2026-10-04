import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let start = Date(timeIntervalSince1970: 1_000)
let task = CodexActivityEvent(taskID: "pinned-1", title: "Build app", status: .running, occurredAt: start)
var arbiter = ActivityArbiter()
expect(arbiter.selection(at: start) == .focus, "music/focus is the default")
arbiter.receive(task, pinnedTaskIDs: ["pinned-1"])
expect(arbiter.selection(at: start) == .codexStatus(task), "pinned task event temporarily overrides focus")
expect(arbiter.selection(at: start.addingTimeInterval(4.9)) == .codexStatus(task), "event remains visible within quiet window")
expect(arbiter.selection(at: start.addingTimeInterval(5.1)) == .focus, "event expires back to current focus")
let next = CodexActivityEvent(taskID: "pinned-1", title: "Build app", status: .waiting, occurredAt: start.addingTimeInterval(4))
arbiter.receive(next, pinnedTaskIDs: ["pinned-1"])
expect(arbiter.selection(at: start.addingTimeInterval(8.9)) == .codexStatus(next), "a newer event resets the quiet window")
expect(arbiter.selection(at: start.addingTimeInterval(9.1)) == .focus, "new event expires after its own quiet window")
arbiter.receive(task, pinnedTaskIDs: [])
expect(arbiter.selection(at: start) == .focus, "unpinning drops the temporary override")
print("ActivityArbiter assertions passed")
