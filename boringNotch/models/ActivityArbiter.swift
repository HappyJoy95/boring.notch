import Foundation

enum CodexDisplayStatus: String, Codable, Equatable {
    case running
    case waiting
    case completed
    case interrupted
    case idle
}

/// Extensible source identity. Codex keeps its legacy unprefixed task IDs.
struct AgentTaskSource: RawRepresentable, Hashable, Codable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let codex = Self(rawValue: "codex")
    static let workBuddy = Self(rawValue: "workbuddy")
    static let dsh = Self(rawValue: "dsh")
    static let mimo = Self(rawValue: "mimo")

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .workBuddy: return "WorkBuddy"
        case .dsh: return "DSH"
        case .mimo: return "MiMo Desktop"
        default: return rawValue
        }
    }
    var icon: String {
        switch self {
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .workBuddy: return "person.crop.square"
        default: return "cpu"
        }
    }
    func taskID(_ localID: String) -> String {
        self == .codex ? localID : rawValue + ":" + localID
    }
    func openURL(localID: String) -> URL? {
        let path = localID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? ""
        switch self {
        case .codex: return URL(string: "codex://threads/" + path)
        case .workBuddy: return URL(string: "workbuddy://chat/" + path)
        default: return nil
        }
    }
}

struct CodexPinnedTask: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let status: CodexDisplayStatus
    let latestReply: String
    let messages: [CodexTaskMessage]?
    let provider: String?
    let updatedAt: Date
    var source: AgentTaskSource {
        if let provider { return AgentTaskSource(rawValue: provider) }
        if let colon = id.firstIndex(of: ":") { return AgentTaskSource(rawValue: String(id[..<colon])) }
        return .codex
    }
    var localID: String {
        let prefix = source.rawValue + ":"
        return id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
    }
    // Compatibility for existing clients; routing uses source, never this Boolean.
    var isWorkBuddy: Bool { source == .workBuddy }
    var providerName: String { source.displayName }
    var openURL: URL? { source.openURL(localID: localID) }

    init(id: String, title: String, status: CodexDisplayStatus, latestReply: String, messages: [CodexTaskMessage] = [], updatedAt: Date = Date(), source: AgentTaskSource? = nil) {
        let inferred = id.firstIndex(of: ":").map { AgentTaskSource(rawValue: String(id[..<$0])) } ?? .codex
        let source = source ?? inferred
        let prefix = source.rawValue + ":"
        let localID = id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
        self.provider = source == .codex ? nil : source.rawValue
        self.id = source.taskID(String(localID.prefix(256)))
        self.title = String(title.prefix(300))
        self.status = status
        self.latestReply = String(latestReply.prefix(4000))
        self.messages = Array(messages.suffix(12))
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, status, latestReply, messages, provider, updatedAt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try c.decode(String.self, forKey: .id)
        let explicit = try c.decodeIfPresent(String.self, forKey: .provider)
        let prefix = rawID.firstIndex(of: ":").map { String(rawID[..<$0]) }
        let source = AgentTaskSource(rawValue: explicit ?? prefix ?? "codex")
        let validSource = !source.rawValue.isEmpty && source.rawValue.count <= 64
            && source.rawValue.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_").contains($0) }
        guard validSource, !rawID.isEmpty, prefix == nil || prefix == source.rawValue else {
            throw DecodingError.dataCorruptedError(forKey: .provider, in: c, debugDescription: "Invalid or conflicting task source")
        }
        let localID = prefix == nil ? rawID : String(rawID.dropFirst(source.rawValue.count + 1))
        guard !localID.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Empty local task ID")
        }
        id = source.taskID(localID)
        provider = source == .codex ? nil : source.rawValue
        title = try c.decode(String.self, forKey: .title)
        status = try c.decode(CodexDisplayStatus.self, forKey: .status)
        latestReply = try c.decode(String.self, forKey: .latestReply)
        messages = try c.decodeIfPresent([CodexTaskMessage].self, forKey: .messages)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

/// nil means failure; an empty successful snapshot removes only that source.
enum AgentTaskSnapshots {
    static func validated(_ tasks: [CodexPinnedTask], for source: AgentTaskSource) -> [CodexPinnedTask]? {
        guard tasks.allSatisfy({ $0.source == source }), Set(tasks.map(\.id)).count == tasks.count else { return nil }
        return tasks
    }
    static func merge(previous: [CodexPinnedTask], updates: [AgentTaskSource: [CodexPinnedTask]?]) -> [CodexPinnedTask] {
        var sources: [AgentTaskSource] = []
        for task in previous where !sources.contains(task.source) { sources.append(task.source) }
        for source in updates.keys.sorted(by: { $0.rawValue < $1.rawValue }) where !sources.contains(source) { sources.append(source) }
        return sources.flatMap { source in
            if let value = updates[source], let tasks = value, let valid = validated(tasks, for: source) { return valid }
            return previous.filter { $0.source == source }
        }
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
    let timelineTime: Double?
    let timelineIndex: Int?

    init(id: String, role: Role, text: String, phase: String? = nil) {
        self.timelineTime = nil
        self.timelineIndex = nil
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

// Stores only task/message identifiers and timestamps, never message contents.
struct CodexUnreadTracker: Codable {
    struct Entry: Codable {
        var status: CodexDisplayStatus
        var completionKey: String
        var unread: Bool
    }
    private(set) var entries: [String: Entry] = [:]
    var unreadIDs: Set<String> { Set(entries.filter { $0.value.unread }.map(\.key)) }

    static func completionKey(_ task: CodexPinnedTask) -> String {
        task.messages?.last(where: { $0.role == .assistant && $0.phase != "commentary" })?.id
            ?? String(task.updatedAt.timeIntervalSince1970)
    }

    mutating func update(_ tasks: [CodexPinnedTask], readingID: String? = nil) -> Set<String> {
        var newlyUnread = Set<String>()
        let ids = Set(tasks.map(\.id))
        entries = entries.filter { ids.contains($0.key) }
        for task in tasks {
            let key = Self.completionKey(task)
            let previous = entries[task.id]
            let newCompletion = task.status == .completed && previous != nil
                && (previous?.status != .completed || previous?.completionKey != key)
            var unread = task.status == .completed && (previous?.unread == true || newCompletion)
            if readingID == task.id { unread = false }
            if newCompletion && unread { newlyUnread.insert(task.id) }
            entries[task.id] = Entry(status: task.status, completionKey: key, unread: unread)
        }
        return newlyUnread
    }

    mutating func markRead(_ id: String) { entries[id]?.unread = false }
}

// Update overlapping messages in place and order by authoritative turn time.
// For older records without ordering metadata, insert before the next shared ID.
enum AgentMessageTimeline {
    static func merge(_ history: [CodexTaskMessage], _ incoming: [CodexTaskMessage]) -> [CodexTaskMessage] {
        var result: [CodexTaskMessage] = []
        var seen = Set<String>()
        for message in history where seen.insert(message.id).inserted { result.append(message) }
        for (position, message) in incoming.enumerated() {
            if let index = result.firstIndex(where: { $0.id == message.id }) {
                result[index] = message
            } else if let anchor = incoming.dropFirst(position + 1).first(where: { candidate in result.contains { $0.id == candidate.id } }),
                      let index = result.firstIndex(where: { $0.id == anchor.id }) {
                result.insert(message, at: index)
            } else { result.append(message) }
        }
        if result.allSatisfy({ $0.timelineTime != nil }) {
            let positions = Dictionary(uniqueKeysWithValues: result.enumerated().map { ($0.element.id, $0.offset) })
            result.sort {
                if $0.timelineTime != $1.timelineTime { return $0.timelineTime! < $1.timelineTime! }
                if $0.timelineIndex != $1.timelineIndex { return ($0.timelineIndex ?? 0) < ($1.timelineIndex ?? 0) }
                return positions[$0.id]! < positions[$1.id]!
            }
        }
        return result
    }
}
