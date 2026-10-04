import Foundation

enum AgentSourcePreferences {
    static let codexKey = "agentSource.codexEnabled"
    static let workBuddyKey = "agentSource.workBuddyEnabled"
    static let dshKey = "agentSource.dshEnabled"
    static let mimoKey = "agentSource.mimoEnabled"

    static func isEnabled(_ source: AgentTaskSource, defaults: UserDefaults = .standard) -> Bool {
        let key: String
        switch source {
        case .codex: key = codexKey
        case .workBuddy: key = workBuddyKey
        case .dsh: key = dshKey
        case .mimo: key = mimoKey
        default: return false
        }
        return defaults.object(forKey: key) as? Bool ?? true
    }
}

enum AgentTaskComposer { case standard, workBuddyBridge }

struct AgentTaskCapabilities: Equatable {
    var composer: AgentTaskComposer = .standard
    var history = false
    var send = false
    var stop = false
}

enum AgentTaskSendResult: Equatable {
    case submitted, queued, unavailable, notPinned, invalid, busy, unknown
    case failure(String)
    var errorMessage: String? {
        switch self {
        case .submitted, .queued: return nil
        case .unavailable: return "发送组件未连接"
        case .notPinned: return "会话已取消置顶"
        case .invalid: return "消息为空或过长"
        case .busy: return "应用暂时无法接收消息"
        case .unknown: return "发送结果未确认，请在应用中核对，避免重复发送"
        case .failure(let message): return message
        }
    }
}

@MainActor
protocol AgentTaskProvider {
    var source: AgentTaskSource { get }
    var capabilities: AgentTaskCapabilities { get }
    func readTasks() async -> [CodexPinnedTask]?
    func readTask(_ task: CodexPinnedTask) async -> CodexPinnedTask?
    func readHistory(_ task: CodexPinnedTask, cursor: String?) async -> Data?
    /// A delivery result must never trigger a retry through another provider.
    func send(_ task: CodexPinnedTask, prompt: String) async -> AgentTaskSendResult
    func stop(_ task: CodexPinnedTask) async -> String?
}

extension AgentTaskProvider {
    func readTask(_ task: CodexPinnedTask) async -> CodexPinnedTask? {
        await readTasks()?.first { $0.id == task.id && $0.source == source }
    }
    func readHistory(_ task: CodexPinnedTask, cursor: String?) async -> Data? { nil }
    func send(_ task: CodexPinnedTask, prompt: String) async -> AgentTaskSendResult { .failure("此来源暂不支持发送") }
    func stop(_ task: CodexPinnedTask) async -> String? { "此来源暂不支持中止" }
}

struct AgentTaskRefreshResult {
    let tasks: [CodexPinnedTask]
    let failedSources: Set<AgentTaskSource>
    let updates: [AgentTaskSource: [CodexPinnedTask]?]
}

/// One registration per application; all operations are addressed by task source.
@MainActor
final class AgentTaskProviders {
    private let providers: [any AgentTaskProvider]
    private let defaults: UserDefaults
    init(_ providers: [any AgentTaskProvider], defaults: UserDefaults = .standard) {
        precondition(Set(providers.map(\.source)).count == providers.count, "Duplicate task source")
        self.providers = providers
        self.defaults = defaults
    }
    private func provider(for task: CodexPinnedTask) -> (any AgentTaskProvider)? {
        providers.first { $0.source == task.source }
    }
    func capabilities(for task: CodexPinnedTask) -> AgentTaskCapabilities {
        provider(for: task)?.capabilities ?? AgentTaskCapabilities()
    }
    func refresh(previous: [CodexPinnedTask]) async -> AgentTaskRefreshResult {
        // Start all reads before awaiting any provider, so a slow source cannot delay the others' reads.
        let enabledProviders = providers.filter { AgentSourcePreferences.isEnabled($0.source, defaults: defaults) }
        let requests = enabledProviders.map { provider in
            Task { @MainActor in
                let tasks = await provider.readTasks()
                return (provider.source, tasks.flatMap { AgentTaskSnapshots.validated($0, for: provider.source) })
            }
        }
        var updates: [AgentTaskSource: [CodexPinnedTask]?] = [:]
        var failed = Set<AgentTaskSource>()
        for request in requests {
            let (source, tasks) = await request.value
            updates.updateValue(tasks, forKey: source)
            if tasks == nil { failed.insert(source) }
        }
        for provider in providers where !AgentSourcePreferences.isEnabled(provider.source, defaults: defaults) {
            updates[provider.source] = []
        }
        return AgentTaskRefreshResult(tasks: AgentTaskSnapshots.merge(previous: previous, updates: updates), failedSources: failed, updates: updates)
    }
    func readTask(_ task: CodexPinnedTask) async -> CodexPinnedTask? {
        guard let provider = provider(for: task), let result = await provider.readTask(task),
              result.id == task.id, result.source == task.source else { return nil }
        return result
    }
    func readHistory(_ task: CodexPinnedTask, cursor: String?) async -> Data? {
        guard let provider = provider(for: task), provider.capabilities.history else { return nil }
        return await provider.readHistory(task, cursor: cursor)
    }
    func send(_ task: CodexPinnedTask, prompt: String) async -> AgentTaskSendResult {
        guard let provider = provider(for: task), provider.capabilities.send else { return .failure("此来源暂不支持发送") }
        return await provider.send(task, prompt: prompt)
    }
    func stop(_ task: CodexPinnedTask) async -> String? {
        guard let provider = provider(for: task), provider.capabilities.stop else { return "此来源暂不支持中止" }
        return await provider.stop(task)
    }
}
