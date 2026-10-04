import Defaults
import SwiftUI

struct AgentTasksView: View {
    @ObservedObject private var service = CodexPinnedTasksService.shared

    var body: some View {
        Group {
            if !service.tasks.isEmpty {
                GeometryReader { geometry in
                    let outerInset = (Defaults[.cornerRadiusScaling]
                        ? cornerRadiusInsets.opened.top : cornerRadiusInsets.opened.bottom) + 12
                    let extensionWidth = max(0, outerInset - 20)
                    CodexPinnedTasksView(tasks: service.tasks, selectedTaskID: $service.selectedTaskID)
                        .frame(width: geometry.size.width + 2 * extensionWidth, height: 118)
                        .clipped()
                        .offset(x: -extensionWidth)
                }
                .frame(height: 118)
            } else if service.isRefreshing {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.7))
                    Text("Loading pinned Codex tasks…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if service.lastRefreshFailed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("Couldn’t read Codex tasks")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "pin.slash")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("No pinned Codex tasks")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                    Text("Pin a task in Codex to see its status and latest reply here.")
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
                    delay = 2.5
                } else if service.selectedTaskID != nil {
                    delay = 5
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
