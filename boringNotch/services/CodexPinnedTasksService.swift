import Combine
import Foundation

@MainActor
final class CodexPinnedTasksService: ObservableObject {
    static let shared = CodexPinnedTasksService()

    @Published private(set) var tasks: [CodexPinnedTask] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshFailed = false
    @Published var selectedTaskID: String?

    private var inFlight: Task<[CodexPinnedTask]?, Never>?

    private init() {}

    func refresh() async {
        if let inFlight {
            isRefreshing = true
            if let tasks = await inFlight.value {
                self.tasks = tasks
                BoringViewCoordinator.shared.updateCodexPinnedTasks(tasks)
                lastRefreshFailed = false
            } else {
                lastRefreshFailed = true
            }
            isRefreshing = false
            self.inFlight = nil
            return
        }

        isRefreshing = true
        let request = Task<[CodexPinnedTask]?, Never> {
            guard let data = await XPCHelperClient.shared.readPinnedCodexTasks() else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode([CodexPinnedTask].self, from: data)
        }
        inFlight = request

        if let tasks = await request.value {
            self.tasks = tasks
            BoringViewCoordinator.shared.updateCodexPinnedTasks(tasks)
            lastRefreshFailed = false
        } else {
            lastRefreshFailed = true
        }
        isRefreshing = false
        inFlight = nil
    }

    func refreshSelectedTask() async {
        guard let selectedTaskID,
              let data = await XPCHelperClient.shared.readPinnedCodexTask(selectedTaskID) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let updatedTask = try? decoder.decode(CodexPinnedTask.self, from: data),
              let index = tasks.firstIndex(where: { $0.id == updatedTask.id }) else { return }
        tasks[index] = updatedTask
        BoringViewCoordinator.shared.updateCodexPinnedTasks(tasks)
        lastRefreshFailed = false
    }
}
