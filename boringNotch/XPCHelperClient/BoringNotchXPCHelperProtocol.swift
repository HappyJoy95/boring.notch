//
//  BoringNotchXPCHelperProtocol.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation

/// The protocol that this service will vend as its API. This protocol will also need to be visible to the process hosting the service.
@objc protocol BoringNotchXPCHelperProtocol {
    func nativeMusicControl(_ bundleID: String, action: String, with reply: @escaping (Data?) -> Void)
    func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void)
    func notificationCenterAccessibilitySummary(with reply: @escaping (String) -> Void)
    func startNotificationBannerMonitoring(with reply: @escaping (Bool) -> Void)
    func openOriginalNotification(_ text: String, bundleID: String, with reply: @escaping (Bool) -> Void)
    func stopNotificationBannerMonitoring()
    func requestAccessibilityAuthorization()
    // Keyboard backlight / CoreBrightness access (performed by the helper)
    func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void)
    func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    // Screen brightness access (performed by the helper)
    func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void)
    func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    func readCodexQuota(with reply: @escaping (Data?) -> Void)
    func sendWorkBuddyInstruction(_ taskID: String, prompt: String, requestID: String, with reply: @escaping (String) -> Void)
    func probeWorkBuddyBridge(_ taskID: String, with reply: @escaping (String) -> Void)
    func installWorkBuddyBridge(with reply: @escaping (String) -> Void)
    func readWorkBuddyTasks(with reply: @escaping (Data?) -> Void)
    func readWorkBuddyHistory(_ taskID: String, cursor: String?, with reply: @escaping (Data?) -> Void)
    func controlDSHSession(_ sessionID: String, action: String, prompt: String?, requestID: String, with reply: @escaping (String) -> Void)
    func installDSHBridge(_ appPath: String?, isRunning: Bool, with reply: @escaping (String) -> Void)
    func installMiMoBridge(with reply: @escaping (String) -> Void)
    func probeMiMoBridge(with reply: @escaping (String) -> Void)
    func controlMiMoSession(_ sessionID: String, action: String, prompt: String?, requestID: String, with reply: @escaping (String) -> Void)
    func readMiMoTasks(with reply: @escaping (Data?) -> Void)
    func readMiMoHistory(_ sessionID: String, cursor: String?, with reply: @escaping (Data?) -> Void)
    func readDSHTasks(with reply: @escaping (Data?) -> Void)
    func readDSHHistory(_ sessionID: String, cursor: String?, with reply: @escaping (Data?) -> Void)
    func readPinnedCodexTasks(with reply: @escaping (Data?) -> Void)
    func readCodexHistory(_ threadID: String, cursor: String?, with reply: @escaping (Data?) -> Void)
    func readPinnedCodexTask(_ threadID: String, with reply: @escaping (Data?) -> Void)
    func interruptCodexTask(_ threadID: String, with reply: @escaping (String?) -> Void)
    func sendCodexInstruction(_ threadID: String, prompt: String, with reply: @escaping (String?) -> Void)
}

@objc protocol BoringNotchNotificationEventReceiving {
    func didCaptureNotification(_ identifier: String, text: String, sourceBundleIdentifier: String?, sourceDiagnostics: String, capturedAt: Double, with reply: @escaping (Bool) -> Void)
}
