import Foundation

@MainActor final class BoringViewCoordinator {
    static let shared = BoringViewCoordinator()
    var codexTabEnabled = false
    var updates = 0
    var tasks: [CodexPinnedTask] = []
    func updateCodexPinnedTasks(_ tasks: [CodexPinnedTask]) { self.tasks = tasks; updates += 1 }
}
@MainActor final class XPCHelperClient {
    static let shared = XPCHelperClient()
    func readPinnedCodexTasks() async -> Data? { nil }
    func readWorkBuddyTasks() async -> Data? { nil }
    func controlMiMoSession(sessionID: String, action: String, prompt: String? = nil) async -> String { "unavailable" }
    func readMiMoTasks() async -> Data? { nil }
    func readMiMoHistory(sessionID: String, cursor: String?) async -> Data? { nil }
    func controlDSHSession(sessionID: String, action: String, prompt: String? = nil) async -> String { "unavailable" }
    func readDSHTasks() async -> Data? { nil }
    func readPinnedCodexTask(_ id: String) async -> Data? { nil }
    func readCodexHistory(threadID: String, cursor: String?) async -> Data? { nil }
    func readWorkBuddyHistory(taskID: String, cursor: String?) async -> Data? { nil }
    func readDSHHistory(sessionID: String, cursor: String?) async -> Data? { nil }
    func sendCodexInstruction(threadID: String, prompt: String) async -> String? { "unavailable" }
    func interruptCodexTask(threadID: String) async -> String? { "unavailable" }
    func sendWorkBuddyInstruction(taskID: String, prompt: String, requestID: String) async -> String { "unknown" }
}
@MainActor final class DelayedProvider: AgentTaskProvider {
    let source: AgentTaskSource
    let capabilities = AgentTaskCapabilities(history: true)
    var snapshot: [CodexPinnedTask]?
    var held = false
    var pending: CheckedContinuation<[CodexPinnedTask]?, Never>?
    var reads = 0
    var historyReads = 0
    init(_ source: AgentTaskSource, _ snapshot: [CodexPinnedTask]) { self.source = source; self.snapshot = snapshot }
    func readTasks() async -> [CodexPinnedTask]? {
        reads += 1
        if held { return await withCheckedContinuation { pending = $0 } }
        return snapshot
    }
    func readHistory(_ task: CodexPinnedTask, cursor: String?) async -> Data? {
        historyReads += 1
        return Data("{\"messages\":[{\"id\":\"same-message\",\"role\":\"assistant\",\"text\":\"\(source.rawValue)\"}],\"nextCursor\":null}".utf8)
    }
    func release() { held = false; pending?.resume(returning: snapshot); pending = nil }
}
@main struct ServiceTests {
    @MainActor static func main() async {
        let name = "AgentProviderTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let codexTask = CodexPinnedTask(id: "same", title: "initial", status: .running, latestReply: "")
        let buddyTask = CodexPinnedTask(id: "same", title: "buddy", status: .running, latestReply: "", source: .workBuddy)
        let codex = DelayedProvider(.codex, [codexTask])
        let buddy = DelayedProvider(.workBuddy, [buddyTask])
        let service = CodexPinnedTasksService(providers: AgentTaskProviders([codex, buddy], defaults: defaults), defaults: defaults)
        await service.refresh()
        precondition(service.tasks.count == 2 && !service.lastRefreshFailed)
        await service.loadHistory(codexTask.id)
        await service.loadHistory(buddyTask.id)
        precondition(service.histories[codexTask.id]?.messages.first?.text == "codex")
        precondition(service.histories[buddyTask.id]?.messages.first?.text == "workbuddy")
        await service.loadHistory("unknown:same")
        precondition(codex.historyReads == 1 && buddy.historyReads == 1)
        codex.held = true; buddy.held = true
        let updateCount = BoringViewCoordinator.shared.updates
        let first = Task { await service.refresh() }
        for _ in 0..<1000 { if codex.pending != nil && buddy.pending != nil { break }; await Task.yield() }
        precondition(codex.pending != nil && buddy.pending != nil && service.isRefreshing)
        let second = Task { await service.refresh() }
        await Task.yield()
        precondition(codex.reads == 2 && buddy.reads == 2)
        let pushed = CodexPinnedTask(id: "same", title: "pushed", status: .completed, latestReply: "")
        service.applyCodexSnapshot(CodexActivitySnapshot(tasks: [pushed], event: nil))
        precondition(service.tasks.count == 2 && service.tasks.first?.title == "pushed")
        codex.snapshot = nil; buddy.snapshot = []
        codex.release(); buddy.release()
        await first.value; await second.value
        precondition(service.tasks == [pushed])
        precondition(service.failedSources == [.codex] && service.lastRefreshFailed && !service.isRefreshing)
        precondition(BoringViewCoordinator.shared.updates == updateCount + 2) // push plus one shared refresh
        precondition(service.histories[buddyTask.id] == nil)
        let oldTasks = service.tasks
        service.applyCodexSnapshot(CodexActivitySnapshot(tasks: [buddyTask], event: nil))
        precondition(service.tasks == oldTasks)
        print("PASS: shared refresh, partial failure, push during read and history source isolation")
    }
}

// Standalone service regression does not load the app's Defaults package.
enum Defaults {
    enum Key { case agentRefreshInterval }
    static subscript(_ key: Key) -> Double { 5 }
}
