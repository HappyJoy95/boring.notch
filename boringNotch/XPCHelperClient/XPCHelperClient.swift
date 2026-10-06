import Foundation
import Cocoa
import AsyncXPCConnection

@MainActor
final class XPCHelperClient: NSObject {
    static let shared = XPCHelperClient()
    
    private let serviceName = "com.happyjoy95.boringnotch.BoringNotchXPCHelper"
    
    private var remoteService: RemoteXPCService<BoringNotchXPCHelperProtocol>?
    private var connection: NSXPCConnection?
    private var lastKnownAuthorization: Bool?
    private var monitoringTask: Task<Void, Never>?
    
    deinit {
        connection?.invalidate()
        monitoringTask?.cancel()
    }
    
    // MARK: - Connection Management (Main Actor Isolated)
    
    @MainActor
    private func ensureRemoteService() -> RemoteXPCService<BoringNotchXPCHelperProtocol> {
        if let existing = remoteService {
            return existing
        }
        
        let conn = NSXPCConnection(serviceName: serviceName)
        conn.exportedInterface = NSXPCInterface(with: BoringNotchNotificationEventReceiving.self)
        conn.exportedObject = NotificationEventReceiver.shared
        
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.remoteService = nil
            }
        }
        
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.remoteService = nil
            }
        }
        
        conn.resume()
        
        let service = RemoteXPCService<BoringNotchXPCHelperProtocol>(
            connection: conn,
            remoteInterface: BoringNotchXPCHelperProtocol.self
        )
        
        connection = conn
        remoteService = service
        return service
    }
    
    @MainActor
    private func getRemoteService() -> RemoteXPCService<BoringNotchXPCHelperProtocol>? {
        remoteService
    }
    
    @MainActor
    private func notifyAuthorizationChange(_ granted: Bool) {
        guard lastKnownAuthorization != granted else { return }
        lastKnownAuthorization = granted
        NotificationCenter.default.post(
            name: .accessibilityAuthorizationChanged,
            object: nil,
            userInfo: ["granted": granted]
        )
    }

    // MARK: - Monitoring
    func startMonitoringAccessibilityAuthorization(every interval: TimeInterval = 3.0) {
        // Ensure only one monitor exists
        stopMonitoringAccessibilityAuthorization()
        monitoringTask = Task { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                // Call the helper method periodically which will notify on change
                _ = await self.isAccessibilityAuthorized()
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch { break }
            }
        }
    }

    func stopMonitoringAccessibilityAuthorization() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    // Expose whether the client is actively monitoring (useful for tests/debug)
    var isMonitoring: Bool {
        return monitoringTask != nil
    }
    
    // MARK: - Accessibility
    
    func requestAccessibilityAuthorization() {
        Task {
            let service = ensureRemoteService()
            try? await service.withService { service in
                service.requestAccessibilityAuthorization()
            }
        }
    }
    
    func nativeMusicControl(_ bundleID: String, action: String) async -> Data? {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.nativeMusicControl(bundleID, action: action) { data in
                    continuation.resume(returning: data)
                }
            }
        } catch { return nil }
    }

    func isAccessibilityAuthorized() async -> Bool {
        do {
            let service = ensureRemoteService()
            let result: Bool = try await service.withContinuation { service, continuation in
                service.isAccessibilityAuthorized { authorized in
                    continuation.resume(returning: authorized)
                }
            }
            await MainActor.run {
                notifyAuthorizationChange(result)
            }
            return result
        } catch {
            return false
        }
    }

    func notificationCenterAccessibilitySummary() async -> String {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.notificationCenterAccessibilitySummary { summary in
                    continuation.resume(returning: summary)
                }
            }
        } catch { return "xpcError=\(error.localizedDescription)" }
    }

    func startNotificationBannerMonitoring() async -> Bool {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.startNotificationBannerMonitoring { started in
                    continuation.resume(returning: started)
                }
            }
        } catch { return false }
    }

    func openOriginalNotification(text: String, bundleID: String) async -> Bool {
        do {
            return try await ensureRemoteService().withContinuation { service, continuation in
                service.openOriginalNotification(text, bundleID: bundleID) { continuation.resume(returning: $0) }
            }
        } catch { return false }
    }

    func stopNotificationBannerMonitoring() async {
        guard let service = getRemoteService() else { return }
        try? await service.withService { service in
            service.stopNotificationBannerMonitoring()
        }
    }
    
    // MARK: - Keyboard Brightness
    
    func isKeyboardBrightnessAvailable() async -> Bool {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.isKeyboardBrightnessAvailable { available in
                    continuation.resume(returning: available)
                }
            }
        } catch {
            return false
        }
    }
    
    func currentKeyboardBrightness() async -> Float? {
        do {
            let service = ensureRemoteService()
            let result: NSNumber? = try await service.withContinuation { service, continuation in
                service.currentKeyboardBrightness { value in
                    continuation.resume(returning: value)
                }
            }
            return result?.floatValue
        } catch {
            return nil
        }
    }
    
    func setKeyboardBrightness(_ value: Float) async -> Bool {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.setKeyboardBrightness(value) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
    }
    
    // MARK: - Screen Brightness
    
    func isScreenBrightnessAvailable() async -> Bool {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.isScreenBrightnessAvailable { available in
                    continuation.resume(returning: available)
                }
            }
        } catch {
            return false
        }
    }
    
    func currentScreenBrightness() async -> Float? {
        do {
            let service = ensureRemoteService()
            let result: NSNumber? = try await service.withContinuation { service, continuation in
                service.currentScreenBrightness { value in
                    continuation.resume(returning: value)
                }
            }
            return result?.floatValue
        } catch {
            return nil
        }
    }
    
    func setScreenBrightness(_ value: Float) async -> Bool {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.setScreenBrightness(value) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
    }

    func readCodexQuota() async -> Data? {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.readCodexQuota { data in
                    continuation.resume(returning: data)
                }
            }
        } catch {
            return nil
        }
    }

    func readWorkBuddyTasks() async -> Data? {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.readWorkBuddyTasks { continuation.resume(returning: $0) }
            }
        } catch { return nil }
    }

    func readWorkBuddyHistory(taskID: String, cursor: String?) async -> Data? {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.readWorkBuddyHistory(taskID, cursor: cursor) { continuation.resume(returning: $0) }
            }
        } catch { return nil }
    }

    func controlDSHSession(sessionID: String, action: String, prompt: String? = nil) async -> String {
        let requestID = UUID().uuidString
        do {
            return try await ensureRemoteService().withContinuation { service, continuation in
                service.controlDSHSession(sessionID, action: action, prompt: prompt, requestID: requestID) {
                    continuation.resume(returning: $0)
                }
            }
        } catch { return "unknown" }
    }

    func installDSHBridge(appPath: String?, isRunning: Bool) async -> String {
        do {
            return try await ensureRemoteService().withContinuation { service, continuation in
                service.installDSHBridge(appPath, isRunning: isRunning) { continuation.resume(returning: $0) }
            }
        } catch { return "unknown" }
    }

    func installMiMoBridge() async -> String {
        do {
            return try await ensureRemoteService().withContinuation { service, continuation in
                service.installMiMoBridge { continuation.resume(returning: $0) }
            }
        } catch { return "failed" }
    }
    func probeMiMoBridge() async -> String {
        do {
            return try await ensureRemoteService().withContinuation { service, continuation in
                service.probeMiMoBridge { continuation.resume(returning: $0) }
            }
        } catch { return "unavailable" }
    }
    func controlMiMoSession(sessionID: String, action: String, prompt: String? = nil) async -> String {
        let requestID = UUID().uuidString
        do {
            return try await ensureRemoteService().withContinuation { service, continuation in
                service.controlMiMoSession(sessionID, action: action, prompt: prompt, requestID: requestID) {
                    continuation.resume(returning: $0)
                }
            }
        } catch { return "unknown" }
    }

    func readMiMoTasks() async -> Data? {
        do {
            return try await ensureRemoteService().withContinuation { service, continuation in
                service.readMiMoTasks { continuation.resume(returning: $0) }
            }
        } catch { return nil }
    }

    func readMiMoHistory(sessionID: String, cursor: String?) async -> Data? {
        do {
            return try await ensureRemoteService().withContinuation { service, continuation in
                service.readMiMoHistory(sessionID, cursor: cursor) { continuation.resume(returning: $0) }
            }
        } catch { return nil }
    }

    func readDSHTasks() async -> Data? {
        do {
            return try await ensureRemoteService().withContinuation { service, continuation in
                service.readDSHTasks { continuation.resume(returning: $0) }
            }
        } catch { return nil }
    }

    func readDSHHistory(sessionID: String, cursor: String?) async -> Data? {
        do {
            return try await ensureRemoteService().withContinuation { service, continuation in
                service.readDSHHistory(sessionID, cursor: cursor) { continuation.resume(returning: $0) }
            }
        } catch { return nil }
    }

    func readPinnedCodexTasks() async -> Data? {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.readPinnedCodexTasks { data in
                    continuation.resume(returning: data)
                }
            }
        } catch {
            return nil
        }
    }

    func readCodexHistory(threadID: String, cursor: String?) async -> Data? {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.readCodexHistory(threadID, cursor: cursor) { data in
                    continuation.resume(returning: data)
                }
            }
        } catch { return nil }
    }

    func readPinnedCodexTask(_ threadID: String) async -> Data? {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.readPinnedCodexTask(threadID) { data in
                    continuation.resume(returning: data)
                }
            }
        } catch {
            return nil
        }
    }

    func interruptCodexTask(threadID: String) async -> String? {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.interruptCodexTask(threadID) { error in
                    continuation.resume(returning: error)
                }
            }
        } catch { return error.localizedDescription }
    }

    func installWorkBuddyBridge() async -> String {
        do {
            return try await ensureRemoteService().withContinuation { service, continuation in
                service.installWorkBuddyBridge { continuation.resume(returning: $0) }
            }
        } catch { return "failed" }
    }

    func sendWorkBuddyInstruction(taskID: String, prompt: String, requestID: String) async -> String {
        do {
            return try await ensureRemoteService().withContinuation { service, continuation in
                service.sendWorkBuddyInstruction(taskID, prompt: prompt, requestID: requestID) {
                    continuation.resume(returning: $0)
                }
            }
        } catch { return "unknown" }
    }

    func probeWorkBuddyBridge(taskID: String) async -> String {
        do {
            return try await ensureRemoteService().withContinuation { service, continuation in
                service.probeWorkBuddyBridge(taskID) { continuation.resume(returning: $0) }
            }
        } catch { return "unavailable" }
    }

    func sendCodexInstruction(threadID: String, prompt: String) async -> String? {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.sendCodexInstruction(threadID, prompt: prompt) { error in
                    continuation.resume(returning: error)
                }
            }
        } catch {
            return error.localizedDescription
        }
    }
}

private final class NotificationEventReceiver: NSObject, BoringNotchNotificationEventReceiving {
    static let shared = NotificationEventReceiver()

    func didCaptureNotification(_ identifier: String, text: String, sourceBundleIdentifier: String?, sourceDiagnostics: String, capturedAt: Double, with reply: @escaping (Bool) -> Void) {
        let boundedText = String(text.prefix(2400)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard UserDefaults.standard.bool(forKey: NotificationMirroringPreferences.enabledKey),
              !identifier.isEmpty, !boundedText.isEmpty else { reply(false); return }
        Task { @MainActor in
            BoringViewCoordinator.shared.receiveMirroredNotification(
                identifier: identifier,
                text: boundedText,
                sourceBundleIdentifier: sourceBundleIdentifier,
                sourceDiagnostics: sourceDiagnostics,
                capturedAt: Date(timeIntervalSince1970: capturedAt)
            )
            reply(true)
        }
    }
}

extension Notification.Name {
    static let accessibilityAuthorizationChanged = Notification.Name("accessibilityAuthorizationChanged")
}
