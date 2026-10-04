import Foundation
let id = UUID().uuidString
func receipt(_ accepted: Bool, _ status: String?, commandID: String? = nil) -> String {
    var value: [String: Any] = ["schema_version": 1, "command_id": commandID ?? id, "accepted": accepted]
    value["status"] = status
    return WorkBuddyInstructionSender.receipt(value, requestID: id)
}
precondition(receipt(true, "submitted") == "submitted")
precondition(receipt(true, "queued") == "queued")
precondition(receipt(false, "unknown") == "unknown")
precondition(receipt(false, "failed") == "failed")
precondition(receipt(true, "failed") == "unknown")
precondition(receipt(true, nil) == "unknown")
precondition(receipt(true, "submitted", commandID: UUID().uuidString) == "unknown")
precondition(WorkBuddyInstructionSender.receipt([:], requestID: id) == "unknown")
print("PASS: matching receipt, queue, rejection and ambiguous responses")
