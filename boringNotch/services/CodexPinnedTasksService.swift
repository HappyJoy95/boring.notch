import AppKit
import Combine
import Defaults
import Foundation

@MainActor
final class CodexPinnedTasksService: ObservableObject {
    static let shared = CodexPinnedTasksService()

    @Published private(set) var addedTimes = [String: Double]()
    @Published private(set) var reminderTimes = [String: Double]()

    func recordReminders(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        for id in ids { reminderTimes[id] = now }
        defaults.set(reminderTimes, forKey: "agentReminderTimes")
    }

    @Published private(set) var tasks: [CodexPinnedTask] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshFailed = false
    @Published private(set) var failedSources: Set<AgentTaskSource> = []

    private let providers: AgentTaskProviders
    private let defaults: UserDefaults

    func capabilities(for task: CodexPinnedTask) -> AgentTaskCapabilities { providers.capabilities(for: task) }

    func send(_ id: String, prompt: String) async -> String? {
        await sendResult(id, prompt: prompt).errorMessage
    }

    func sendResult(_ id: String, prompt: String) async -> AgentTaskSendResult {
        guard let task = tasks.first(where: { $0.id == id }) else { return .notPinned }
        return await providers.send(task, prompt: prompt)
    }

    func stop(_ id: String) async -> String? {
        guard let task = tasks.first(where: { $0.id == id }) else { return "会话已移除" }
        return await providers.stop(task)
    }
    @Published var selectedTaskID: String?

    struct History {
        var messages: [CodexTaskMessage] = []
        var cursor: String?
        var loaded = false
        var loading = false
        var failed = false
    }
    private struct HistoryPage: Decodable {
        let messages: [CodexTaskMessage]
        let nextCursor: String?
    }
    @Published private(set) var histories: [String: History] = [:]
    private var refreshingHistoryIDs = Set<String>()

    func loadHistory(_ id: String) async {
        guard let task = tasks.first(where: { $0.id == id }), capabilities(for: task).history else { return }
        var history = histories[id] ?? History()
        guard !history.loading, !refreshingHistoryIDs.contains(id), !history.loaded || history.cursor != nil else { return }
        history.loading = true
        history.failed = false
        histories[id] = history
        let data = await providers.readHistory(task, cursor: history.cursor)
        guard tasks.contains(where: { $0.id == id && $0.source == task.source }) else { return }
        guard let data, let page = try? JSONDecoder().decode(HistoryPage.self, from: data) else {
            history.loading = false
            history.failed = true
            histories[id] = history
            return
        }
        let existingIDs = Set(history.messages.map(\.id))
        var seen = Set<String>()
        let older = page.messages.filter { !existingIDs.contains($0.id) && seen.insert($0.id).inserted }
        history.messages = AgentMessageTimeline.merge(older, history.messages)
        history.cursor = page.nextCursor == history.cursor ? nil : page.nextCursor
        history.loaded = true
        history.loading = false
        histories[id] = history
    }

    private var previousPinnedIDs: Set<String>?

    private func applyPinnedTasks(_ tasks: [CodexPinnedTask]) {
        let ids = Set(tasks.map(\.id))
        let added = previousPinnedIDs.map { ids.subtracting($0) } ?? []
        previousPinnedIDs = ids
        let now = Date().timeIntervalSince1970
        for (index, task) in tasks.enumerated() where addedTimes[task.id] == nil {
            addedTimes[task.id] = now + Double(index) * 0.000001
        }
        defaults.set(addedTimes, forKey: "agentAddedTimes")
        self.tasks = tasks
        histories = histories.filter { ids.contains($0.key) }
        if let selectedTaskID, !ids.contains(selectedTaskID) { self.selectedTaskID = nil }
        BoringViewCoordinator.shared.updateCodexPinnedTasks(tasks)
        if !added.isEmpty, BoringViewCoordinator.shared.codexTabEnabled {
            NSSound(named: NSSound.Name("Ping"))?.play()
        }
    }

    private var monitoringTask: Task<Void, Never>?

    private var inFlight: Task<Void, Never>?

    private convenience init() {
        self.init(providers: AgentTaskProviders([CodexTaskProvider(), WorkBuddyTaskProvider(), DSHTaskProvider(), MiMoTaskProvider()]))
    }

    init(providers: AgentTaskProviders, defaults: UserDefaults = .standard) {
        self.providers = providers
        self.defaults = defaults
        addedTimes = defaults.dictionary(forKey: "agentAddedTimes") as? [String: Double] ?? [:]
        reminderTimes = defaults.dictionary(forKey: "agentReminderTimes") as? [String: Double] ?? [:]
    }

    func startMonitoring() {
        guard monitoringTask == nil else { return }
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if BoringViewCoordinator.shared.codexTabEnabled
                    || AgentSourcePreferences.isEnabled(.workBuddy)
                    || AgentSourcePreferences.isEnabled(.dsh)
                    || AgentSourcePreferences.isEnabled(.mimo) {
                    await self.refresh()
                }
                do { try await Task.sleep(for: .seconds(min(30, max(2, Defaults[.agentRefreshInterval])))) }
                catch { return }
            }
        }
    }

    func refresh() async {
        if let inFlight {
            await inFlight.value
            return
        }
        isRefreshing = true
        let request = Task { @MainActor in
            let result = await providers.refresh(previous: tasks)
            // Merge against the latest state: pushed snapshots may arrive during a read.
            applyPinnedTasks(AgentTaskSnapshots.merge(previous: tasks, updates: result.updates))
            failedSources = result.failedSources
            lastRefreshFailed = !result.failedSources.isEmpty
            isRefreshing = false
            inFlight = nil
        }
        inFlight = request
        await request.value
    }

    func applyCodexSnapshot(_ snapshot: CodexActivitySnapshot) {
        guard AgentSourcePreferences.isEnabled(.codex) else {
            applyPinnedTasks(tasks.filter { $0.source != .codex })
            return
        }
        guard let tasks = AgentTaskSnapshots.validated(snapshot.tasks, for: .codex) else { return }
        applyPinnedTasks(AgentTaskSnapshots.merge(previous: self.tasks, updates: [.codex: tasks]))
    }

    func refreshSelectedTask() async {
        guard let id = selectedTaskID, let task = tasks.first(where: { $0.id == id }) else { return }
        if let updatedTask = await providers.readTask(task),
           let index = tasks.firstIndex(where: { $0.id == id }) {
            tasks[index] = updatedTask
            BoringViewCoordinator.shared.updateCodexPinnedTasks(tasks)
            failedSources.remove(task.source)
            lastRefreshFailed = !failedSources.isEmpty
        } else {
            failedSources.insert(task.source)
            lastRefreshFailed = true
        }

        guard task.source == .dsh, selectedTaskID == id else { return }
        if histories[id]?.loaded == true {
            await refreshLatestDSHHistory(for: task)
        } else if histories[id]?.failed == true {
            await loadHistory(id)
        }
    }

    private func refreshLatestDSHHistory(for task: CodexPinnedTask) async {
        let id = task.id
        guard selectedTaskID == id,
              let currentHistory = histories[id], currentHistory.loaded, !currentHistory.loading,
              !refreshingHistoryIDs.contains(id) else { return }

        refreshingHistoryIDs.insert(id)
        defer { refreshingHistoryIDs.remove(id) }

        guard let data = await providers.readHistory(task, cursor: nil),
              let page = try? JSONDecoder().decode(HistoryPage.self, from: data),
              selectedTaskID == id,
              tasks.contains(where: { $0.id == id && $0.source == task.source }),
              var history = histories[id], history.loaded, !history.loading else { return }

        history.messages = AgentMessageTimeline.merge(history.messages, page.messages)
        if let pageCursor = page.nextCursor,
           let separator = pageCursor.firstIndex(of: ":"),
           let earliestLoadedSequence = history.messages.compactMap(\.timelineIndex).min() {
            // DSH cursors are tied to the latest sequence. Keep older-page loading
            // anchored before the oldest message already present in the timeline.
            history.cursor = String(pageCursor[..<separator]) + ":" + String(earliestLoadedSequence)
        } else {
            history.cursor = page.nextCursor
        }
        history.failed = false
        histories[id] = history
    }
}

/// Existing XPC endpoints are isolated behind their source adapters.
@MainActor
private struct CodexTaskProvider: AgentTaskProvider {
    let source = AgentTaskSource.codex
    let capabilities = AgentTaskCapabilities(history: true, send: true, stop: true)
    func readTasks() async -> [CodexPinnedTask]? {
        decodeTasks(await XPCHelperClient.shared.readPinnedCodexTasks())
    }
    func readTask(_ task: CodexPinnedTask) async -> CodexPinnedTask? {
        guard let data = await XPCHelperClient.shared.readPinnedCodexTask(task.localID) else { return nil }
        return try? taskDecoder().decode(CodexPinnedTask.self, from: data)
    }
    func readHistory(_ task: CodexPinnedTask, cursor: String?) async -> Data? {
        await XPCHelperClient.shared.readCodexHistory(threadID: task.localID, cursor: cursor)
    }
    func send(_ task: CodexPinnedTask, prompt: String) async -> AgentTaskSendResult {
        if let error = await XPCHelperClient.shared.sendCodexInstruction(threadID: task.localID, prompt: prompt) {
            return .failure(error)
        }
        return .submitted
    }
    func stop(_ task: CodexPinnedTask) async -> String? {
        await XPCHelperClient.shared.interruptCodexTask(threadID: task.localID)
    }
}

@MainActor
private struct WorkBuddyTaskProvider: AgentTaskProvider {
    let source = AgentTaskSource.workBuddy
    let capabilities = AgentTaskCapabilities(composer: .workBuddyBridge, history: true, send: true)
    func readTasks() async -> [CodexPinnedTask]? {
        decodeTasks(await XPCHelperClient.shared.readWorkBuddyTasks())
    }
    func readHistory(_ task: CodexPinnedTask, cursor: String?) async -> Data? {
        await XPCHelperClient.shared.readWorkBuddyHistory(taskID: task.id, cursor: cursor)
    }
    func send(_ task: CodexPinnedTask, prompt: String) async -> AgentTaskSendResult {
        let result = await XPCHelperClient.shared.sendWorkBuddyInstruction(
            taskID: task.id, prompt: prompt, requestID: UUID().uuidString.lowercased())
        switch result {
        case "submitted": return .submitted
        case "queued": return .queued
        case "unavailable", "missing": return .unavailable
        case "notPinned": return .notPinned
        case "invalid": return .invalid
        case "busy": return .busy
        case "failed": return .failure("WorkBuddy 未接收消息，请在应用中查看后再试")
        default: return .unknown
        }
    }
}

@MainActor
private struct DSHTaskProvider: AgentTaskProvider {
    let source = AgentTaskSource.dsh
    let capabilities = AgentTaskCapabilities(history: true, send: true, stop: true)
    func send(_ task: CodexPinnedTask, prompt: String) async -> AgentTaskSendResult {
        switch await XPCHelperClient.shared.controlDSHSession(sessionID: task.localID, action: "send", prompt: prompt) {
        case "queued": return .queued
        case "submitted": return .submitted
        case "notPinned": return .notPinned
        case "invalid": return .invalid
        case "busy": return .busy
        case "unavailable": return .failure("请安装并启用 DSH 插件 0.3.0，然后重启 DSH")
        default: return .unknown
        }
    }
    func stop(_ task: CodexPinnedTask) async -> String? {
        switch await XPCHelperClient.shared.controlDSHSession(sessionID: task.localID, action: "stop") {
        case "submitted": return nil
        case "notPinned": return "会话已取消置顶"
        case "unavailable": return "请安装并启用 DSH 插件 0.3.0，然后重启 DSH"
        case "busy": return "上一项操作尚未完成，请稍后重试"
        default: return "打断结果未确认，请在 DSH 中核对"
        }
    }
    func readTasks() async -> [CodexPinnedTask]? {
        decodeTasks(await XPCHelperClient.shared.readDSHTasks())
    }
    func readHistory(_ task: CodexPinnedTask, cursor: String?) async -> Data? {
        await XPCHelperClient.shared.readDSHHistory(sessionID: task.localID, cursor: cursor)
    }
}

@MainActor
private struct MiMoTaskProvider: AgentTaskProvider {
    let source = AgentTaskSource.mimo
    let capabilities = AgentTaskCapabilities(history: true, send: true, stop: true)
    func send(_ task: CodexPinnedTask, prompt: String) async -> AgentTaskSendResult {
        switch await XPCHelperClient.shared.controlMiMoSession(sessionID: task.localID, action: "send", prompt: prompt) {
        case "submitted": return .submitted
        case "notPinned": return .notPinned
        case "invalid": return .invalid
        case "busy": return .busy
        case "unavailable": return .failure("MiMo 发送组件未连接，请在 AI Agent 设置中检查连接")
        case "failed": return .failure("MiMo 未接收消息，请在 MiMo 中检查后再试")
        default: return .unknown
        }
    }
    func stop(_ task: CodexPinnedTask) async -> String? {
        switch await XPCHelperClient.shared.controlMiMoSession(sessionID: task.localID, action: "stop") {
        case "submitted": return nil
        case "notPinned": return "会话已取消置顶"
        case "unavailable": return "MiMo 接入组件未连接，请重启 MiMo 后检查连接"
        default: return "打断结果未确认，请在 MiMo 中核对"
        }
    }
    func readTasks() async -> [CodexPinnedTask]? {
        decodeTasks(await XPCHelperClient.shared.readMiMoTasks())
    }
    func readHistory(_ task: CodexPinnedTask, cursor: String?) async -> Data? {
        await XPCHelperClient.shared.readMiMoHistory(sessionID: task.localID, cursor: cursor)
    }
}

private func taskDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

private func decodeTasks(_ data: Data?) -> [CodexPinnedTask]? {
    data.flatMap { try? taskDecoder().decode([CodexPinnedTask].self, from: $0) }
}
