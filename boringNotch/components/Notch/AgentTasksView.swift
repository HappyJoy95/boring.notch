import Defaults
import SwiftUI

struct AgentTasksView: View {
    @AppStorage("agentCardSortOrder") private var sortOrder = 1
    private var sortedTasks: [CodexPinnedTask] {
        service.tasks.sorted { left, right in
            if sortOrder == 0 {
                let l = service.reminderTimes[left.id] ?? 0
                let r = service.reminderTimes[right.id] ?? 0
                if l != r { return l > r }
            }
            if sortOrder == 2, left.providerName != right.providerName {
                return left.providerName < right.providerName
            }
            let l = service.addedTimes[left.id] ?? 0
            let r = service.addedTimes[right.id] ?? 0
            return l == r ? left.id < right.id : l < r
        }
    }
    @ObservedObject private var service = CodexPinnedTasksService.shared

    var body: some View {
        Group {
            if !service.tasks.isEmpty {
                GeometryReader { geometry in
                    let outerInset = (Defaults[.cornerRadiusScaling]
                        ? cornerRadiusInsets.opened.top : cornerRadiusInsets.opened.bottom) + 12
                    let notchSideInset = Defaults[.cornerRadiusScaling]
                        ? cornerRadiusInsets.opened.top : cornerRadiusInsets.closed.top
                    let extensionWidth = outerInset - notchSideInset - agentCardInset - 2
                    CodexPinnedTasksView(tasks: sortedTasks, selectedTaskID: $service.selectedTaskID,
                                         pageWidth: geometry.size.width + 2 * extensionWidth,
                                         sortOrder: sortOrder)
                        .frame(width: geometry.size.width + 2 * extensionWidth, height: 134)
                        .clipped()
                        .offset(x: -extensionWidth)
                }
                .frame(height: 134)
            } else if service.isRefreshing {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.7))
                    Text("正在读取置顶会话…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if service.lastRefreshFailed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("无法读取会话")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "pin.slash")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("暂无置顶会话")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                    Text("在已启用的 AI Agent 应用中置顶会话，即可在这里查看回复。")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 50)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 8)
        .task {
            var nextListRefresh = Date.distantPast
            while !Task.isCancelled {
                if Date() >= nextListRefresh {
                    await service.refresh()
                    nextListRefresh = Date().addingTimeInterval(10)
                }
                if service.selectedTaskID != nil {
                    await service.refreshSelectedTask()
                }
                let selectedTask = service.tasks.first { $0.id == service.selectedTaskID }
                let delay: TimeInterval
                if selectedTask?.status == .running {
                    delay = min(2.5, min(30, max(2, Defaults[.agentRefreshInterval])))
                } else if service.selectedTaskID != nil {
                    delay = min(30, max(2, Defaults[.agentRefreshInterval]))
                } else {
                    delay = 10
                }
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    break
                }
            }
        }
        .onDisappear {
            service.selectedTaskID = nil
        }
    }
}
