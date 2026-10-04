import Foundation

enum CodexDisplayStatus: String, Codable, Equatable {
    case running
    case waiting
    case completed
    case interrupted
    case idle
}

struct CodexPinnedTask: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let status: CodexDisplayStatus
    let latestReply: String
    let messages: [CodexTaskMessage]?
    let updatedAt: Date

    init(id: String, title: String, status: CodexDisplayStatus, latestReply: String, messages: [CodexTaskMessage] = [], updatedAt: Date = Date()) {
        self.id = String(id.prefix(256))
        self.title = String(title.prefix(300))
        self.status = status
        self.latestReply = String(latestReply.prefix(4000))
        self.messages = Array(messages.suffix(12))
        self.updatedAt = updatedAt
    }
}

struct CodexTaskMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable, Equatable {
        case user
        case assistant
    }

    let id: String
    let role: Role
    let text: String
    let phase: String?

    init(id: String, role: Role, text: String, phase: String? = nil) {
        self.id = String(id.prefix(256))
        self.role = role
        self.text = String(text.prefix(2000))
        self.phase = phase
    }
}

struct CodexActivitySnapshot: Codable {
    let tasks: [CodexPinnedTask]
    let event: CodexActivityEventPayload?
}

struct CodexActivityEventPayload: Codable {
    let taskID: String
    let title: String
    let status: CodexDisplayStatus
    let occurredAt: Date

    var activityEvent: CodexActivityEvent {
        CodexActivityEvent(taskID: taskID, title: title, status: status, occurredAt: occurredAt)
    }
}

struct CodexActivityEvent: Equatable {
    let taskID: String
    let title: String
    let status: CodexDisplayStatus
    let occurredAt: Date
}

enum ActivitySelection: Equatable {
    case focus
    case codexStatus(CodexActivityEvent)
}

struct ActivityArbiter {
    static let quietWindow: TimeInterval = 5
    private(set) var latestEvent: CodexActivityEvent?
    private(set) var pinnedTaskIDs = Set<String>()

    mutating func receive(_ event: CodexActivityEvent, pinnedTaskIDs: Set<String>) {
        self.pinnedTaskIDs = pinnedTaskIDs
        guard pinnedTaskIDs.contains(event.taskID) else {
            if latestEvent?.taskID == event.taskID {
                latestEvent = nil
            }
            return
        }
        latestEvent = event
    }

    mutating func updatePinnedTaskIDs(_ ids: Set<String>) {
        pinnedTaskIDs = ids
        if let event = latestEvent, !ids.contains(event.taskID) {
            latestEvent = nil
        }
    }

    func selection(at date: Date = Date()) -> ActivitySelection {
        guard let event = latestEvent,
              pinnedTaskIDs.contains(event.taskID),
              date.timeIntervalSince(event.occurredAt) >= 0,
              date.timeIntervalSince(event.occurredAt) < Self.quietWindow else {
            return .focus
        }
        return .codexStatus(event)
    }
}
