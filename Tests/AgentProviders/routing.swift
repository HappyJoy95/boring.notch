import Foundation

@MainActor
final class TestProvider: AgentTaskProvider {
    let source: AgentTaskSource
    let capabilities = AgentTaskCapabilities(history: true, send: true, stop: true)
    var snapshot: [CodexPinnedTask]?
    var calls: [String] = []
    init(_ source: AgentTaskSource, _ snapshot: [CodexPinnedTask]?) { self.source = source; self.snapshot = snapshot }
    func readTasks() async -> [CodexPinnedTask]? { calls.append("list"); return snapshot }
    func readTask(_ task: CodexPinnedTask) async -> CodexPinnedTask? { calls.append("task:" + task.localID); return task }
    func readHistory(_ task: CodexPinnedTask, cursor: String?) async -> Data? { calls.append("history:" + task.localID); return Data() }
    func send(_ task: CodexPinnedTask, prompt: String) async -> AgentTaskSendResult { calls.append("send:" + task.localID); return .submitted }
    func stop(_ task: CodexPinnedTask) async -> String? { calls.append("stop:" + task.localID); return nil }
}

@main struct RoutingTests {
    @MainActor static func main() async {
        let codexTask = CodexPinnedTask(id: "same", title: "", status: .running, latestReply: "")
        let buddyTask = CodexPinnedTask(id: "same", title: "", status: .running, latestReply: "", source: .workBuddy)
        let thirdSource = AgentTaskSource.mimo
        let thirdTask = CodexPinnedTask(id: "same", title: "", status: .running, latestReply: "", source: thirdSource)
        let codex = TestProvider(.codex, [codexTask])
        let buddy = TestProvider(.workBuddy, [buddyTask])
        let third = TestProvider(thirdSource, [thirdTask])
        let preferenceName = "AgentRoutingTests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: preferenceName)!
        defer { preferences.removePersistentDomain(forName: preferenceName) }
        let registry = AgentTaskProviders([codex, buddy, third], defaults: preferences)
        let result = await registry.refresh(previous: [])
        precondition(Set(result.tasks.map(\.id)) == [codexTask.id, buddyTask.id, thirdTask.id])
        precondition(result.failedSources.isEmpty)
        _ = await registry.readHistory(thirdTask, cursor: nil)
        _ = await registry.send(buddyTask, prompt: "hello")
        _ = await registry.stop(codexTask)
        precondition(third.calls == ["list", "history:same"])
        precondition(buddy.calls == ["list", "send:same"])
        precondition(codex.calls == ["list", "stop:same"])
        let unknown = CodexPinnedTask(id: "same", title: "", status: .idle, latestReply: "", source: AgentTaskSource(rawValue: "unknown"))
        let unknownHistory = await registry.readHistory(unknown, cursor: nil)
        let unknownSend = await registry.send(unknown, prompt: "hello")
        let unknownStop = await registry.stop(unknown)
        precondition(unknownHistory == nil && unknownSend != .submitted && unknownStop != nil)
        precondition(codex.calls == ["list", "stop:same"])
        buddy.snapshot = nil
        codex.snapshot = []
        third.snapshot = [buddyTask] // A malformed response must not overwrite another source.
        let partial = await registry.refresh(previous: result.tasks)
        precondition(partial.failedSources == [.workBuddy, thirdSource])
        precondition(Set(partial.tasks.map(\.id)) == [buddyTask.id, thirdTask.id])
        codex.snapshot = [codexTask]; buddy.snapshot = [buddyTask]; third.snapshot = [thirdTask]
        preferences.set(false, forKey: AgentSourcePreferences.mimoKey)
        let disabled = await registry.refresh(previous: result.tasks)
        precondition(disabled.tasks == [codexTask, buddyTask])
        preferences.set(true, forKey: AgentSourcePreferences.mimoKey)
        let enabled = await registry.refresh(previous: disabled.tasks)
        precondition(Set(enabled.tasks.map(\.id)) == Set(result.tasks.map(\.id)))
        print("PASS: three providers, operation routing, unsupported operations and partial failure isolation")
    }
}
