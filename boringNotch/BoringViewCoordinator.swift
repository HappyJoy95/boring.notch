//
//  BoringViewCoordinator.swift
//  boringNotch
//
//  Created by Alexander on 2024-11-20.
//

import AppKit
import Combine
import Defaults
import SwiftUI

enum SneakContentType {
    case brightness
    case volume
    case backlight
    case music
    case mic
    case battery
    case download
}

struct sneakPeek {
    var show: Bool = false
    var type: SneakContentType = .music
    var value: CGFloat = 0
    var icon: String = ""
}

struct SharedSneakPeek: Codable {
    var show: Bool
    var type: String
    var value: String
    var icon: String
}

enum NotificationMirroringPreferences {
    static let enabledKey = "visibleNotificationMirroringEnabled"
}

struct MirroredNotificationActivity: Identifiable, Equatable {
    let id: String
    let text: String
    let sourceBundleIdentifier: String?
    let receivedAt: Date
}

enum BrowserType {
    case chromium
    case safari
}

struct ExpandedItem {
    var show: Bool = false
    var type: SneakContentType = .battery
    var value: CGFloat = 0
    var browser: BrowserType = .chromium
}

@MainActor
class BoringViewCoordinator: ObservableObject {
    static let shared = BoringViewCoordinator()

    var openHomeAfterOutsideDismiss = false

    @Published var currentView: NotchViews = .home
    @Published var helloAnimationRunning: Bool = false
    @Published private(set) var codexPinnedTasks: [CodexPinnedTask] = []
    @Published private(set) var codexStatusEvent: CodexActivityEvent?
    @Published private(set) var mirroredNotification: MirroredNotificationActivity?
    @Published private(set) var notificationSourceStatus = ""
    @Published private(set) var codexUnreadTaskIDs = Set<String>()
    @Published private(set) var codexCompletionReminder: UUID?
    @Published private(set) var codexHighlightedTaskIDs = Set<String>()
    private var codexUnreadTracker: CodexUnreadTracker = {
        guard let data = UserDefaults.standard.data(forKey: "codexUnreadTracker.v1"),
              let saved = try? JSONDecoder().decode(CodexUnreadTracker.self, from: data) else {
            return CodexUnreadTracker()
        }
        return saved
    }()

    private var activityArbiter = ActivityArbiter()
    private var codexStatusExpiryTask: Task<Void, Never>?
    private var mirroredNotificationExpiryTask: Task<Void, Never>?
    private var sneakPeekDispatch: DispatchWorkItem?
    private var expandingViewDispatch: DispatchWorkItem?
    private var hudEnableTask: Task<Void, Never>?

    @AppStorage("firstLaunch") var firstLaunch: Bool = true
    @AppStorage("showWhatsNew") var showWhatsNew: Bool = true
    @AppStorage("musicLiveActivityEnabled") var musicLiveActivityEnabled: Bool = true
    @AppStorage("currentMicStatus") var currentMicStatus: Bool = true
    @AppStorage("codexTabEnabled") var codexTabEnabled: Bool = true {
        didSet {
            if !codexTabEnabled && currentView == .agent { currentView = .home }
        }
    }
    @Default(.boringShelf) private var shelfEnabled: Bool {
        didSet {
            if !shelfEnabled && currentView == .shelf { currentView = .home }
        }
    }

    @AppStorage("alwaysShowTabs") var alwaysShowTabs: Bool = true {
        didSet {
            if !alwaysShowTabs {
                openLastTabByDefault = false
                if ShelfStateViewModel.shared.isEmpty || !Defaults[.openShelfByDefault] {
                    currentView = .home
                }
            }
        }
    }

    @AppStorage("openLastTabByDefault") var openLastTabByDefault: Bool = false {
        didSet {
            if openLastTabByDefault {
                alwaysShowTabs = true
            }
        }
    }
    
    @Default(.hudReplacement) var hudReplacement: Bool
    
    // Legacy storage for migration
    @AppStorage("preferred_screen_name") private var legacyPreferredScreenName: String?
    
    // New UUID-based storage
    @AppStorage("preferred_screen_uuid") var preferredScreenUUID: String? {
        didSet {
            if let uuid = preferredScreenUUID {
                selectedScreenUUID = uuid
            }
            NotificationCenter.default.post(name: Notification.Name.selectedScreenChanged, object: nil)
        }
    }

    @Published var selectedScreenUUID: String = NSScreen.main?.displayUUID ?? ""

    @Published var optionKeyPressed: Bool = true
    private var accessibilityObserver: Any?
    private var hudReplacementCancellable: AnyCancellable?

    private init() {
        // Perform migration from name-based to UUID-based storage
        if preferredScreenUUID == nil, let legacyName = legacyPreferredScreenName {
            // Try to find screen by name and migrate to UUID
            if let screen = NSScreen.screens.first(where: { $0.localizedName == legacyName }),
               let uuid = screen.displayUUID {
                preferredScreenUUID = uuid
                NSLog("✅ Migrated display preference from name '\(legacyName)' to UUID '\(uuid)'")
            } else {
                // Fallback to main screen if legacy screen not found
                preferredScreenUUID = NSScreen.main?.displayUUID
                NSLog("⚠️ Could not find display named '\(legacyName)', falling back to main screen")
            }
            // Clear legacy value after migration
            legacyPreferredScreenName = nil
        } else if preferredScreenUUID == nil {
            // No legacy value, use main screen
            preferredScreenUUID = NSScreen.main?.displayUUID
        }
        
        selectedScreenUUID = preferredScreenUUID ?? NSScreen.main?.displayUUID ?? ""
        // Observe changes to accessibility authorization and react accordingly
        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.accessibilityAuthorizationChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                if Defaults[.hudReplacement] {
                    await MediaKeyInterceptor.shared.start()
                }
            }
        }

        // Observe changes to hudReplacement
        hudReplacementCancellable = Defaults.publisher(.hudReplacement)
            .sink { [weak self] change in
                Task { @MainActor in
                    guard let self = self else { return }

                    self.hudEnableTask?.cancel()
                    self.hudEnableTask = nil

                    if change.newValue {
                        self.hudEnableTask = Task { @MainActor in
                            let granted = await XPCHelperClient.shared.isAccessibilityAuthorized()
                            if Task.isCancelled { return }

                            if granted {
                                await MediaKeyInterceptor.shared.start()
                            } else {
                                Defaults[.hudReplacement] = false
                            }
                        }
                    } else {
                        MediaKeyInterceptor.shared.stop()
                    }
                }
            }

        Task { @MainActor in
            helloAnimationRunning = firstLaunch

            if Defaults[.hudReplacement] {
                let authorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
                if !authorized {
                    Defaults[.hudReplacement] = false
                } else {
                    await MediaKeyInterceptor.shared.start()
                }
            }
        }
    }

    func updateCodexPinnedTasks(_ tasks: [CodexPinnedTask]) {
        var seen = Set<String>()
        let pinned = Array(tasks.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }.prefix(96))
        let newlyUnread = codexUnreadTracker.update(pinned,
            readingID: CodexPinnedTasksService.shared.selectedTaskID)
        CodexPinnedTasksService.shared.recordReminders(newlyUnread)
        codexUnreadTaskIDs = codexUnreadTracker.unreadIDs
        saveCodexReadState()
        codexPinnedTasks = pinned
        if !newlyUnread.isEmpty && codexTabEnabled {
            codexHighlightedTaskIDs = newlyUnread
            currentView = .agent
            codexCompletionReminder = UUID()
        }
        let pinnedIDs = Set(pinned.map(\.id))
        activityArbiter.updatePinnedTaskIDs(pinnedIDs)
        if let event = codexStatusEvent, !pinnedIDs.contains(event.taskID) {
            clearCodexStatusEvent()
        }
    }

    func markCodexTaskRead(_ id: String) {
        codexUnreadTracker.markRead(id)
        codexUnreadTaskIDs = codexUnreadTracker.unreadIDs
        saveCodexReadState()
    }

    private func saveCodexReadState() {
        if let data = try? JSONEncoder().encode(codexUnreadTracker) {
            UserDefaults.standard.set(data, forKey: "codexUnreadTracker.v1")
        }
    }

    func applyCodexSnapshot(_ snapshot: CodexActivitySnapshot) {
        guard AgentTaskSnapshots.validated(snapshot.tasks, for: .codex) != nil else { return }
        CodexPinnedTasksService.shared.applyCodexSnapshot(snapshot)
        if let event = snapshot.event {
            receiveCodexStatus(event.activityEvent)
        }
    }

    func receiveCodexStatus(_ event: CodexActivityEvent) {
        let pinnedIDs = Set(codexPinnedTasks.map(\.id))
        activityArbiter.receive(event, pinnedTaskIDs: pinnedIDs)
        guard case .codexStatus = activityArbiter.selection(at: event.occurredAt) else { return }
        codexStatusExpiryTask?.cancel()
        codexStatusEvent = event
        codexStatusExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ActivityArbiter.quietWindow))
            guard !Task.isCancelled else { return }
            self?.clearCodexStatusEvent()
        }
    }

    private func clearCodexStatusEvent() {
        codexStatusExpiryTask?.cancel()
        codexStatusExpiryTask = nil
        codexStatusEvent = nil
    }

    func receiveMirroredNotification(identifier: String, text: String, sourceBundleIdentifier: String?, sourceDiagnostics: String, capturedAt: Date) {
        let boundedText = String(text.prefix(2400)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard UserDefaults.standard.bool(forKey: NotificationMirroringPreferences.enabledKey),
              !identifier.isEmpty, !boundedText.isEmpty else { return }

        if let bundleID = sourceBundleIdentifier {
            let foundIcon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
            notificationSourceStatus = "来源：\(bundleID)；系统图标\(foundIcon ? "可用" : "未找到")。\(sourceDiagnostics)"
        } else {
            notificationSourceStatus = "来源未识别，使用铃铛图标。\(sourceDiagnostics)"
        }
        mirroredNotificationExpiryTask?.cancel()
        mirroredNotification = MirroredNotificationActivity(id: identifier, text: boundedText, sourceBundleIdentifier: sourceBundleIdentifier, receivedAt: capturedAt)
        let configuredDuration = Defaults[.notificationDisplayDuration]
        let duration = configuredDuration.isFinite ? min(30, max(1, configuredDuration)) : 6
        mirroredNotificationExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, self?.mirroredNotification?.id == identifier else { return }
            self?.mirroredNotification = nil
            self?.mirroredNotificationExpiryTask = nil
        }
    }

    func clearMirroredNotification() {
        mirroredNotificationExpiryTask?.cancel()
        mirroredNotificationExpiryTask = nil
        mirroredNotification = nil
    }
    
    @objc func sneakPeekEvent(_ notification: Notification) {
        let decoder = JSONDecoder()
        if let decodedData = try? decoder.decode(
            SharedSneakPeek.self, from: notification.userInfo?.first?.value as! Data)
        {
            let contentType =
                decodedData.type == "brightness"
                ? SneakContentType.brightness
                : decodedData.type == "volume"
                    ? SneakContentType.volume
                    : decodedData.type == "backlight"
                        ? SneakContentType.backlight
                        : decodedData.type == "mic"
                            ? SneakContentType.mic : SneakContentType.brightness

            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .decimal
            let value = CGFloat((formatter.number(from: decodedData.value) ?? 0.0).floatValue)
            let icon = decodedData.icon

            print("Decoded: \(decodedData), Parsed value: \(value)")

            toggleSneakPeek(status: decodedData.show, type: contentType, value: value, icon: icon)

        } else {
            print("Failed to decode JSON data")
        }
    }

    func toggleSneakPeek(
        status: Bool, type: SneakContentType, duration: TimeInterval? = nil, value: CGFloat = 0,
        icon: String = ""
    ) {
        let isSystemHint = type == .volume || type == .brightness || type == .backlight || type == .mic
        sneakPeekDuration = duration ?? (isSystemHint ? min(10, max(0.5, Defaults[.compactHUDDuration])) : 1.5)
        if type != .music {
            // close()
            if !Defaults[.hudReplacement] {
                return
            }
        }
        Task { @MainActor in
            withAnimation(.smooth) {
                self.sneakPeek.show = status
                self.sneakPeek.type = type
                self.sneakPeek.value = value
                self.sneakPeek.icon = icon
            }
        }

        if type == .mic {
            currentMicStatus = value == 1
        }
    }

    private var sneakPeekDuration: TimeInterval = 1.5
    private var sneakPeekTask: Task<Void, Never>?

    // Helper function to manage sneakPeek timer using Swift Concurrency
    private func scheduleSneakPeekHide(after duration: TimeInterval) {
        sneakPeekTask?.cancel()

        sneakPeekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self = self, !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation {
                    self.toggleSneakPeek(status: false, type: .music)
                    self.sneakPeekDuration = 1.5
                }
            }
        }
    }

    @Published var sneakPeek: sneakPeek = .init() {
        didSet {
            if sneakPeek.show {
                scheduleSneakPeekHide(after: sneakPeekDuration)
            } else {
                sneakPeekTask?.cancel()
            }
        }
    }

    func toggleExpandingView(
        status: Bool,
        type: SneakContentType,
        value: CGFloat = 0,
        browser: BrowserType = .chromium
    ) {
        Task { @MainActor in
            withAnimation(.smooth) {
                self.expandingView.show = status
                self.expandingView.type = type
                self.expandingView.value = value
                self.expandingView.browser = browser
            }
        }
    }

    private var expandingViewTask: Task<Void, Never>?

    @Published var expandingView: ExpandedItem = .init() {
        didSet {
            if expandingView.show {
                expandingViewTask?.cancel()
                let isSystemHint = [.volume, .brightness, .backlight, .mic].contains(expandingView.type)
                let duration: TimeInterval = expandingView.type == .download
                    ? min(10, max(0.5, Defaults[.downloadHintDuration]))
                    : isSystemHint ? min(10, max(0.5, Defaults[.expandedHUDDuration])) : 3
                let currentType = expandingView.type
                expandingViewTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(duration))
                    guard let self = self, !Task.isCancelled else { return }
                    self.toggleExpandingView(status: false, type: currentType)
                }
            } else {
                expandingViewTask?.cancel()
            }
        }
    }
    
    func showEmpty() {
        currentView = .home
    }
}
