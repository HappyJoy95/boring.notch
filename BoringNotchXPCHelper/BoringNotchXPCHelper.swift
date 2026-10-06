//
//  BoringNotchXPCHelper.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation
import AppKit
import ApplicationServices
import IOKit
import CoreGraphics

class BoringNotchXPCHelper: NSObject, BoringNotchXPCHelperProtocol {
    private weak var connection: NSXPCConnection?
    private var notificationBannerWatcher: NotificationBannerWatcher?

    init(connection: NSXPCConnection) {
        self.connection = connection
        super.init()
    }

    deinit {
        notificationBannerWatcher?.stop()
    }
    
    @objc func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void) {
        reply(AXIsProcessTrusted())
    }

    @objc func notificationCenterAccessibilitySummary(with reply: @escaping (String) -> Void) {
        guard AXIsProcessTrusted() else { reply("trusted=false"); return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else {
            reply("trusted=true notificationCenterProcess=missing")
            return
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var count = 0, titled = 0, valued = 0
        var roles: Set<String> = []
        func visit(_ element: AXUIElement, _ depth: Int) {
            guard depth < 12, count < 2000 else { return }
            count += 1
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success,
               let role = value as? String { roles.insert(role) }
            if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success,
               value is String { titled += 1 }
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
               value is String { valued += 1 }
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
               let children = value as? [AXUIElement] {
                for child in children { visit(child, depth + 1) }
            }
        }
        visit(root, 0)
        reply("trusted=true pid=\(app.processIdentifier) elements=\(count) titled=\(titled) valued=\(valued) roles=\(roles.sorted().joined(separator: ","))")
    }

    @objc func openOriginalNotification(_ text: String, bundleID: String, with reply: @escaping (Bool) -> Void) {
        NotificationBannerWatcher.openOriginal(text: text, bundleID: bundleID, reply: reply)
    }

    @objc func requestAccessibilityAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @objc func startNotificationBannerMonitoring(with reply: @escaping (Bool) -> Void) {
        guard AXIsProcessTrusted(), let connection else { reply(false); return }
        DispatchQueue.main.async {
            let watcher = self.notificationBannerWatcher ?? NotificationBannerWatcher(connection: connection)
            self.notificationBannerWatcher = watcher
            reply(watcher.start())
        }
    }

    @objc func stopNotificationBannerMonitoring() {
        DispatchQueue.main.async {
            self.notificationBannerWatcher?.stop()
            self.notificationBannerWatcher = nil
        }
    }

    private class KeyboardBrightnessClient {
        private static let keyboardID: UInt64 = 1
        private var clientInstance: NSObject?
        private let getSelector = NSSelectorFromString("brightnessForKeyboard:")
        private let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")

        init() {
            var loaded = false
            let bundlePaths = [
                "/System/Library/PrivateFrameworks/CoreBrightness.framework",
                "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
            ]
            for path in bundlePaths where !loaded {
                if let bundle = Bundle(path: path) {
                    loaded = bundle.load()
                }
            }
            if loaded, let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
                clientInstance = cls.init()
            }
        }

        var isAvailable: Bool { clientInstance != nil }

        func currentBrightness() -> Float? {
            guard let clientInstance,
                  let fn: BrightnessGetter = methodIMP(on: clientInstance, selector: getSelector, as: BrightnessGetter.self)
            else { return nil }
            return fn(clientInstance, getSelector, Self.keyboardID)
        }

        func setBrightness(_ value: Float) -> Bool {
            guard let clientInstance,
                  let fn: BrightnessSetter = methodIMP(on: clientInstance, selector: setSelector, as: BrightnessSetter.self)
            else { return false }
            return fn(clientInstance, setSelector, value, Self.keyboardID).boolValue
        }

        private typealias BrightnessGetter = @convention(c) (NSObject, Selector, UInt64) -> Float
        private typealias BrightnessSetter = @convention(c) (NSObject, Selector, Float, UInt64) -> ObjCBool

        private func methodIMP<T>(on object: NSObject, selector: Selector, as type: T.Type) -> T? {
            guard let cls = object_getClass(object),
                  let method = class_getInstanceMethod(cls, selector)
            else { return nil }
            let imp = method_getImplementation(method)
            return unsafeBitCast(imp, to: type)
        }
    }

    private static let keyboardClient = KeyboardBrightnessClient()

    @objc func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.isAvailable)
    }

    @objc func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void) {
        reply(Self.keyboardClient.currentBrightness().map { NSNumber(value: $0) })
    }

    @objc func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.setBrightness(value))
    }
    // MARK: - Screen Brightness (moved from client app into helper)

    @objc func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        var b: Float = 0
        reply(displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) || ioServiceFor(displayID: CGMainDisplayID()) != nil)
    }

    @objc func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void) {
        var b: Float = 0
        if displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) {
            reply(NSNumber(value: b))
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            var level: Float = 0
            if IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &level) == kIOReturnSuccess {
                IOObjectRelease(io)
                reply(NSNumber(value: level))
                return
            }
            IOObjectRelease(io)
        }
        reply(nil)
    }

    @objc func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        let clamped = max(0, min(1, value))
        if displayServicesSetBrightness(displayID: CGMainDisplayID(), value: clamped) {
            reply(true)
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            let ok = IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, clamped) == kIOReturnSuccess
            IOObjectRelease(io)
            reply(ok)
            return
        }
        reply(false)
    }

    @objc func readCodexQuota(with reply: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            reply(try? CodexQuotaReader.read())
        }
    }

    @objc func sendWorkBuddyInstruction(_ taskID: String, prompt: String, requestID: String, with reply: @escaping (String) -> Void) {
        Task { reply(await WorkBuddyInstructionSender.send(taskID: taskID, prompt: prompt, requestID: requestID)) }
    }

    @objc func probeWorkBuddyBridge(_ taskID: String, with reply: @escaping (String) -> Void) {
        Task { reply(await WorkBuddyInstructionSender.probe(taskID: taskID)) }
    }

    @objc func installWorkBuddyBridge(with reply: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .utility).async { reply(WorkBuddyInstructionSender.install()) }
    }

    @objc func readWorkBuddyTasks(with reply: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .utility).async { reply(try? WorkBuddyTasksReader.read()) }
    }

    @objc func readWorkBuddyHistory(_ taskID: String, cursor: String?, with reply: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .utility).async { reply(try? WorkBuddyTasksReader.readHistory(taskID, cursor: cursor)) }
    }

    @objc func controlDSHSession(_ sessionID: String, action: String, prompt: String?, requestID: String, with reply: @escaping (String) -> Void) {
        Task { reply(await DSHTasksReader.control(sessionID, action: action, prompt: prompt, requestID: requestID)) }
    }

    @objc func installDSHBridge(_ appPath: String?, isRunning: Bool, with reply: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let package = Bundle.main.url(forResource: "boring-notch-dsh-0.3.0", withExtension: "zip", subdirectory: "DSHDesktop/dist") else { reply("unsupported"); return }
            let script = Bundle.main.url(forResource: "install", withExtension: "mjs", subdirectory: "DSHDesktop")
            reply(DSHPluginInstaller.install(packageURL: package, scriptURL: script, appURL: appPath.map { URL(fileURLWithPath: $0) }, isRunning: isRunning))
        }
    }

    @objc func installMiMoBridge(with reply: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .utility).async { reply(MiMoBridgeClient.install()) }
    }
    @objc func probeMiMoBridge(with reply: @escaping (String) -> Void) {
        Task { reply(await MiMoBridgeClient.probe()) }
    }
    @objc func controlMiMoSession(_ sessionID: String, action: String, prompt: String?, requestID: String, with reply: @escaping (String) -> Void) {
        Task { reply(await MiMoBridgeClient.control(sessionID, action: action, prompt: prompt, requestID: requestID)) }
    }

    @objc func readMiMoTasks(with reply: @escaping (Data?) -> Void) {
        Task {
            guard let contexts = try? MiMoTasksReader.local.contexts() else { reply(nil); return }
            let statuses = await MiMoBridgeClient.statuses(contexts)
            reply(try? MiMoTasksReader.local.read(statuses: statuses))
        }
    }

    @objc func readMiMoHistory(_ sessionID: String, cursor: String?, with reply: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .utility).async { reply(try? MiMoTasksReader.local.readHistory(sessionID, cursor: cursor)) }
    }

    @objc func readDSHTasks(with reply: @escaping (Data?) -> Void) {
        Task { reply(await DSHTasksReader.readTasks()) }
    }

    @objc func readDSHHistory(_ sessionID: String, cursor: String?, with reply: @escaping (Data?) -> Void) {
        Task { reply(await DSHTasksReader.readHistory(sessionID, cursor: cursor)) }
    }

    @objc func readPinnedCodexTasks(with reply: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            reply(try? CodexPinnedTasksReader.read())
        }
    }

    @objc func readCodexHistory(_ threadID: String, cursor: String?, with reply: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            reply(try? CodexPinnedTasksReader.readHistory(threadID, cursor: cursor))
        }
    }

    @objc func readPinnedCodexTask(_ threadID: String, with reply: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            reply(try? CodexPinnedTasksReader.readPinnedTask(threadID))
        }
    }

    @objc func sendCodexInstruction(_ threadID: String, prompt: String, with reply: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try CodexPinnedTasksReader.validatePinnedThread(threadID)
                try CodexDesktopInstructionSender.send(threadID: threadID, prompt: prompt)
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    @objc func interruptCodexTask(_ threadID: String, with reply: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try CodexPinnedTasksReader.validatePinnedThread(threadID)
                try CodexDesktopInstructionSender.interrupt(threadID: threadID)
                reply(nil)
            } catch { reply(error.localizedDescription) }
        }
    }

    // MARK: - Private helpers for DisplayServices / IOKit access
    private func displayServicesGetBrightness(displayID: CGDirectDisplayID, out: inout Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesGetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        var tmp: Float = 0
        let r = fn(displayID, &tmp)
        if r == 0 { out = tmp; return true }
        return false
    }

    private func displayServicesSetBrightness(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }

    private func ioServiceFor(displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = IODisplayCreateInfoDictionary(service, 0).takeRetainedValue() as NSDictionary
            if let vendorID = info[kDisplayVendorID] as? UInt32,
               let productID = info[kDisplayProductID] as? UInt32,
               vendorID == CGDisplayVendorNumber(displayID),
               productID == CGDisplayModelNumber(displayID) {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    // MARK: - Helper handle for private framework
    private enum DisplayServicesHandle {
        static let handle: UnsafeMutableRawPointer? = {
            let paths = [
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices"
            ]
            for p in paths {
                if let h = dlopen(p, RTLD_LAZY) { return h }
            }
            return nil
        }()
    }
}

private final class NativeMusicControls {
    private struct PlayerSnapshot {
        let state: [String: Any]
        let actionableItems: [String: AXUIElement]
    }

    let bundleID: String
    init(_ bundleID: String) { self.bundleID = bundleID }

    private func nativeAttribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        _ = AXUIElementSetMessagingTimeout(element, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    private func nativeLabel(_ element: AXUIElement) -> String {
        let isMenuItem = nativeAttribute(element, kAXRoleAttribute) as? String == kAXMenuItemRole as String
        let keys = isMenuItem ? [kAXTitleAttribute, kAXDescriptionAttribute] : [kAXDescriptionAttribute, kAXTitleAttribute]
        for key in keys {
            if let value = nativeAttribute(element, key) as? String, !value.isEmpty { return value }
        }
        return ""
    }

    private func pressNativeMenuItem(_ title: String, cachedItems: [String: AXUIElement]? = nil) -> Bool {
        let elements = cachedItems == nil ? nativePlayerElements() : []
        if let item = cachedItems?[title] ?? elements.first(where: { nativeLabel($0) == title }) {
            return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
        }

        // Older client builds may only expose items after opening their menu.
        let controlMenu = bundleID == "com.netease.163music" ? "控制" : "播放控制"
        if let menu = cachedItems?[controlMenu] ?? elements.first(where: { nativeLabel($0) == controlMenu }) {
            AXUIElementPerformAction(menu, kAXPressAction as CFString)
        }
        if let item = nativePlayerElements().first(where: { nativeLabel($0) == title }) {
            return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
        }
        return false
    }

    private func nativePlayerElements() -> [AXUIElement] {
        guard AXIsProcessTrusted(), let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID).first else { return [] }
        var result: [AXUIElement] = []
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 12, result.count < 1500 else { return }
            guard !result.contains(where: { CFEqual($0, element) }) else { return }
            result.append(element)
            for child in nativeAttribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                visit(child, depth: depth + 1)
            }
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(root, 0.25)
        // Read QQ Music from its compact native menu bar; traversing the CEF window
        // on every playback update was expensive and could block the control queue.
        if let menu = nativeAttribute(root, kAXMenuBarAttribute),
           CFGetTypeID(menu) == AXUIElementGetTypeID() {
            visit(menu as! AXUIElement, depth: 0)
        }
        if bundleID != "com.tencent.QQMusicMac" { visit(root, depth: 0) }
        return result
    }

    private func qqPlaybackControls() -> [AXUIElement] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return [] }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(root, 0.2)
        let windows = nativeAttribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        var pending = windows.map { ($0, 0) }
        var seen = 0
        while !pending.isEmpty && seen < 100 {
            let (element, depth) = pending.removeFirst()
            seen += 1
            let role = nativeAttribute(element, kAXRoleAttribute) as? String ?? ""
            // QQ Music exposes its playback panel as AXUnknown, not AXPanel.
            if nativeLabel(element).contains("播放控制栏") {
                return nativeAttribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            }
            // The main window contains a large CEF song list; skip it and only
            // inspect the shallow native panels around the playback controls.
            if depth >= 4 || ["AXScrollArea", "AXTable", "AXWebArea", "AXHTMLArea"].contains(role) { continue }
            for child in nativeAttribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                pending.append((child, depth + 1))
            }
        }
        return []
    }

    private func qqPlaybackModeMenuItems() -> [String: AXUIElement] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return [:] }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar = nativeAttribute(root, kAXMenuBarAttribute),
              CFGetTypeID(menuBar) == AXUIElementGetTypeID() else { return [:] }
        let topLevelItems = nativeAttribute(menuBar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] ?? []
        guard let playbackMenu = topLevelItems.first(where: { nativeLabel($0) == "播放控制" }) else { return [:] }
        for menu in nativeAttribute(playbackMenu, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            let menuItems = nativeAttribute(menu, kAXChildrenAttribute) as? [AXUIElement] ?? []
            guard let modeItem = menuItems.first(where: { nativeLabel($0) == "播放模式" }) else { continue }
            for submenu in nativeAttribute(modeItem, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                let choices = nativeAttribute(submenu, kAXChildrenAttribute) as? [AXUIElement] ?? []
                return Dictionary(uniqueKeysWithValues: choices.compactMap { item in
                    let title = nativeLabel(item)
                    return ["随机播放", "单曲循环", "顺序播放"].contains(title) ? (title, item) : nil
                })
            }
        }
        return [:]
    }

    private func qqPlaybackModeState(_ items: [String: AXUIElement]) -> [String: Any]? {
        for (title, item) in items {
            guard let mark = nativeAttribute(item, "AXMenuItemMarkChar") as? String, !mark.isEmpty else { continue }
            switch title {
            case "随机播放": return ["repeatMode": 1, "isShuffled": true]
            case "单曲循环": return ["repeatMode": 2, "isShuffled": false]
            case "顺序播放": return ["repeatMode": 3, "isShuffled": false]
            default: continue
            }
        }
        return nil
    }

    private func quickQQSnapshot() -> PlayerSnapshot? {
        let controls = qqPlaybackControls()
        guard !controls.isEmpty else { return nil }
        var state: [String: Any] = ["favoriteAvailable": false]
        var actionable: [String: AXUIElement] = [:]
        for control in controls {
            let label = nativeLabel(control)
            if label.contains("播放模式（") { actionable["__repeatButton"] = control }
            if label.contains("我喜欢") {
                state["favoriteAvailable"] = true
                state["isFavorite"] = !label.contains("添加")
            }
        }
        if let button = actionable["__repeatButton"] {
            let label = nativeLabel(button)
            if label.contains("随机") { state["repeatMode"] = 1; state["isShuffled"] = true }
            else if label.contains("单曲") { state["repeatMode"] = 2; state["isShuffled"] = false }
            else if label.contains("顺序") { state["repeatMode"] = 3; state["isShuffled"] = false }
        }
        if let menuState = qqPlaybackModeState(qqPlaybackModeMenuItems()) {
            state.merge(menuState) { _, menuValue in menuValue }
        }
        return PlayerSnapshot(state: state, actionableItems: actionable)
    }

    private func snapshot() -> PlayerSnapshot {
        if bundleID == "com.tencent.QQMusicMac", let quick = quickQQSnapshot() { return quick }
        var result: [String: Any] = ["favoriteAvailable": false]
        var actionableItems: [String: AXUIElement] = [:]
        var menuState: [String: Any] = [:]
        let labels = Set(["我喜欢", "喜欢歌曲", "取消喜欢", "播放控制", "控制", "单曲循环", "顺序播放", "随机播放", "单曲", "全部", "关"])

        for item in nativePlayerElements() {
            let label = nativeLabel(item)
            let isMenuItem = nativeAttribute(item, kAXRoleAttribute) as? String == kAXMenuItemRole as String
            if labels.contains(label), actionableItems[label] == nil { actionableItems[label] = item }
            if bundleID == "com.tencent.QQMusicMac",
               nativeAttribute(item, kAXRoleAttribute) as? String == kAXMenuItemRole as String,
               nativeAttribute(item, kAXEnabledAttribute) as? Bool == true {
                // QQ Music keeps these menu items available even with no windows.
                if label == "喜欢歌曲" || label == "取消喜欢" {
                    menuState["favoriteAvailable"] = true
                    menuState["isFavorite"] = label == "取消喜欢"
                }
                if ["随机播放", "单曲循环", "顺序播放"].contains(label),
                   let mark = nativeAttribute(item, "AXMenuItemMarkChar") as? String, !mark.isEmpty {
                    menuState["repeatMode"] = label == "单曲循环" ? 2 : label == "顺序播放" ? 3 : 1
                    menuState["isShuffled"] = label == "随机播放"
                }
            }
            if label.contains("我喜欢") {
                result["favoriteAvailable"] = true
                result["isFavorite"] = !label.contains("添加")
            } else if label == "喜欢歌曲" || label == "取消喜欢" {
                result["favoriteAvailable"] = true
                if bundleID == "com.netease.163music" {
                    result["isFavorite"] = label == "取消喜欢"
                }
            }
            if label.contains("播放模式（") {
                result["repeatMode"] = label.contains("单曲") ? 2 : label.contains("随机") ? 1 : 3
                result["isShuffled"] = label.contains("随机")
            } else if label == "随机播放", bundleID == "com.netease.163music", isMenuItem {
                menuState["isShuffled"] = (nativeAttribute(item, "AXMenuItemMarkChar") as? String).map { !$0.isEmpty } ?? false
            } else if bundleID == "com.netease.163music", isMenuItem,
                      ["关", "单曲", "全部"].contains(label),
                      let mark = nativeAttribute(item, "AXMenuItemMarkChar") as? String, !mark.isEmpty {
                menuState["repeatMode"] = label == "单曲" ? 2 : label == "全部" ? 3 : 1
            }
        }
        // Verified menu state takes precedence over window controls when both exist.
        result.merge(menuState) { _, menuValue in menuValue }
        return PlayerSnapshot(state: result, actionableItems: actionableItems)
    }

    func run(_ action: String) -> Data? {
        guard ["com.netease.163music", "com.tencent.QQMusicMac"].contains(bundleID), AXIsProcessTrusted() else { return nil }
        if action == "repeat", bundleID == "com.tencent.QQMusicMac" {
            let modeItems = qqPlaybackModeMenuItems()
            guard let current = qqPlaybackModeState(modeItems),
                  let mode = current["repeatMode"] as? Int else { return nil }
            let nextTitle = mode == 1 ? "单曲循环" : mode == 2 ? "顺序播放" : "随机播放"
            guard let nextItem = modeItems[nextTitle],
                  AXUIElementPerformAction(nextItem, kAXPressAction as CFString) == .success else { return nil }
            let result: [String: Any] = [
                "repeatMode": mode == 1 ? 2 : mode == 2 ? 3 : 1,
                "isShuffled": mode == 3
            ]
            return try? JSONSerialization.data(withJSONObject: result)
        }
        let snapshot = snapshot()
        var result = snapshot.state

        if action == "like" || action == "unlike" {
            guard let liked = result["isFavorite"] as? Bool else { return nil }
            let shouldLike = action == "like"
            if liked != shouldLike {
                guard pressNativeMenuItem(liked ? "取消喜欢" : "喜欢歌曲", cachedItems: snapshot.actionableItems) else { return nil }
            }
            result["favoriteAvailable"] = true
            result["isFavorite"] = shouldLike
        } else if action == "repeat" {
            guard let mode = result["repeatMode"] as? Int,
                  let shuffled = result["isShuffled"] as? Bool else { return nil }
            if bundleID == "com.netease.163music" {
                if shuffled {
                    guard pressNativeMenuItem("随机播放", cachedItems: snapshot.actionableItems),
                          pressNativeMenuItem("单曲") else { return nil }
                    result["repeatMode"] = 2
                    result["isShuffled"] = false
                } else if mode == 2 {
                    guard pressNativeMenuItem("全部", cachedItems: snapshot.actionableItems) else { return nil }
                    result["repeatMode"] = 3
                    result["isShuffled"] = false
                } else {
                    guard pressNativeMenuItem("随机播放", cachedItems: snapshot.actionableItems) else { return nil }
                    result["repeatMode"] = 1
                    result["isShuffled"] = true
                }
            } else {
                let title = shuffled ? "单曲循环" : mode == 2 ? "顺序播放" : "随机播放"
                guard pressNativeMenuItem(title, cachedItems: snapshot.actionableItems) else { return nil }
                result["repeatMode"] = shuffled ? 2 : mode == 2 ? 3 : 1
                result["isShuffled"] = !shuffled && mode != 2
            }
        } else if action != "state" {
            return nil
        }

        if action == "repeat" {
            // Menu actions can update asynchronously. Publish only a fresh observed state,
            // rather than the mode predicted by the command sequence above.
            Thread.sleep(forTimeInterval: 0.15)
            result = self.snapshot().state
        }
        return try? JSONSerialization.data(withJSONObject: result)
    }
}

private let nativeMusicControlQueue = DispatchQueue(label: "com.happyjoy95.boringnotch.native-music-controls", qos: .userInitiated)

extension BoringNotchXPCHelper {
    @objc func nativeMusicControl(_ bundleID: String, action: String, with reply: @escaping (Data?) -> Void) {
        nativeMusicControlQueue.async { reply(NativeMusicControls(bundleID).run(action)) }
    }
}
