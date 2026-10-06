import AppKit
import ApplicationServices

/// XPC services process dispatch messages without pumping the main CFRunLoop.
/// AXObserver sources need a live run loop of their own.
private final class NotificationAXRunLoop {
    static let shared = NotificationAXRunLoop()
    private var runLoop: CFRunLoop!
    private var thread: Thread!

    private init() {
        let ready = DispatchSemaphore(value: 0)
        thread = Thread {
            self.runLoop = CFRunLoopGetCurrent()
            var context = CFRunLoopSourceContext(
                version: 0, info: nil, retain: nil, release: nil,
                copyDescription: nil, equal: nil, hash: nil,
                schedule: nil, cancel: nil, perform: { _ in }
            )
            let keepAlive = CFRunLoopSourceCreate(nil, 0, &context)!
            CFRunLoopAddSource(self.runLoop, keepAlive, .defaultMode)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "BoringNotch.NotificationAX"
        thread.start()
        ready.wait()
    }

    func perform(_ work: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, work)
        CFRunLoopWakeUp(runLoop)
    }

    func sync<T>(_ work: @escaping () -> T) -> T {
        if Thread.current === thread { return work() }
        let completed = DispatchSemaphore(value: 0)
        var result: T!
        perform {
            result = work()
            completed.signal()
        }
        completed.wait()
        return result
    }
}

private struct NotificationAXNode {
    let element: AXUIElement
    let depth: Int
}

private struct NotificationCloseAction {
    let element: AXUIElement
    let name: String
}

/// Reads only newly-created, visible Notification Center banner subtrees.
/// Notification text is kept in memory and delivered directly to the app.
final class NotificationBannerWatcher {
    private static let notificationCenterBundleID = "com.apple.notificationcenterui"
    private static let maximumNodes = 100
    private static let maximumDepth = 14
    private static let maximumPayloadLength = 2400

    private weak var connection: NSXPCConnection?
    private var observer: AXObserver?
    private var isActive = false
    private var fingerprints: [String: Date] = [:]

    init(connection: NSXPCConnection?) {
        self.connection = connection
    }

    static func openOriginal(text: String, bundleID: String, reply: @escaping (Bool) -> Void) {
        NotificationAXRunLoop.shared.perform {
            guard AXIsProcessTrusted(), !text.isEmpty,
                  let host = NSRunningApplication.runningApplications(withBundleIdentifier: notificationCenterBundleID).first else { reply(false); return }
            let reader = NotificationBannerWatcher(connection: nil)
            let root = AXUIElementCreateApplication(host.processIdentifier)
            _ = AXUIElementSetMessagingTimeout(root, 0.15)
            func targets() -> [AXUIElement] {
                let groups = reader.walk(root).filter { reader.role(of: $0.element) == kAXGroupRole as String }
                var matches: [(AXUIElement, Int)] = []
                for group in groups {
                    let subtree = reader.walk(group.element)
                    let content = String(reader.textLines(in: subtree).joined(separator: "\n").prefix(maximumPayloadLength))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard content == text else { continue }
                    let closes = reader.closeActions(in: subtree)
                    guard closes.count == 1 else { continue }
                    let metadata = reader.sourceMetadata(scope: group.element, close: closes[0])
                    guard reader.identifySource(in: metadata.nodes, headers: metadata.headers) == bundleID else { continue }
                    var names: CFArray?
                    guard AXUIElementCopyActionNames(group.element, &names) == .success,
                          (names as? [String] ?? []).contains(kAXPressAction as String) else { continue }
                    matches.append((group.element, subtree.count))
                }
                // Nested groups for one notification share ancestry; choose its smallest actionable group.
                guard let smallest = matches.min(by: { $0.1 < $1.1 }) else { return [] }
                let tree = reader.walk(smallest.0)
                guard matches.allSatisfy({ match in
                    CFEqual(match.0, smallest.0) || reader.walk(match.0).contains(where: { CFEqual($0.element, smallest.0) })
                        || tree.contains(where: { CFEqual($0.element, match.0) })
                }) else { return [] }
                return [smallest.0]
            }
            if let target = targets().first {
                reply(AXUIElementPerformAction(target, kAXPressAction as CFString) == .success)
                return
            }
            // Open only the clock menu extra, never a text-matched unrelated menu item.
            var clock: AXUIElement?
            for id in ["com.apple.controlcenter", "com.apple.systemuiserver"] {
                guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { continue }
                let app = AXUIElementCreateApplication(process.processIdentifier)
                _ = AXUIElementSetMessagingTimeout(app, 0.15)
                var nodes = reader.walk(app)
                for key in ["AXExtrasMenuBar", kAXMenuBarAttribute] {
                    var bar: CFTypeRef?
                    if AXUIElementCopyAttributeValue(app, key as CFString, &bar) == .success,
                       let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() { nodes += reader.walk(bar as! AXUIElement) }
                }
                clock = nodes.first(where: {
                    reader.attribute($0.element, kAXIdentifierAttribute) == "com.apple.menuextra.clock"
                })?.element
                if clock != nil { break }
            }
            guard let clock, AXUIElementPerformAction(clock, kAXPressAction as CFString) == .success else { reply(false); return }
            var attempts = 0
            func retry() {
                attempts += 1
                if let target = targets().first {
                    let accepted = AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
                    if !accepted { _ = AXUIElementPerformAction(clock, kAXPressAction as CFString) }
                    reply(accepted)
                } else if attempts < 6 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                        NotificationAXRunLoop.shared.perform { retry() }
                    }
                } else {
                    _ = AXUIElementPerformAction(clock, kAXPressAction as CFString)
                    reply(false)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                NotificationAXRunLoop.shared.perform { retry() }
            }
        }
    }

    @discardableResult
    func start() -> Bool {
        NotificationAXRunLoop.shared.sync { self.startOnRunLoop() }
    }

    private func startOnRunLoop() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        if isActive { return true }
        guard let host = NSRunningApplication.runningApplications(
                withBundleIdentifier: Self.notificationCenterBundleID
              ).first else { return false }

        let root = AXUIElementCreateApplication(host.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(root, 0.12)

        var candidate: AXObserver?
        guard AXObserverCreate(host.processIdentifier, notificationBannerAXCallback, &candidate) == .success,
              let candidate else { return false }

        let context = Unmanaged.passUnretained(self).toOpaque()
        let notifications = [kAXWindowCreatedNotification, kAXCreatedNotification]
        let results = notifications.map {
            AXObserverAddNotification(candidate, root, $0 as CFString, context)
        }
        guard results.contains(.success) else { return false }

        observer = candidate
        isActive = true
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(candidate), .defaultMode)
        return true
    }

    func stop() {
        NotificationAXRunLoop.shared.sync { self.stopOnRunLoop() }
    }

    private func stopOnRunLoop() {
        guard isActive else { return }
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        fingerprints.removeAll(keepingCapacity: false)
        isActive = false
    }

    fileprivate func handleCreatedElement(_ element: AXUIElement, retriesRemaining: Int = 3) {
        guard isActive else { return }
        let tree = walk(element)
        let groups = tree.filter { role(of: $0.element) == kAXGroupRole as String }
        // WindowCreated is a fallback for OS versions that expose a banner without a group.
        let scopes = groups.isEmpty && role(of: element) == kAXWindowRole as String
            ? [NotificationAXNode(element: element, depth: 0)]
            : groups

        var candidates: [(scope: NotificationAXNode, tree: [NotificationAXNode], lines: [String], close: NotificationCloseAction)] = []
        for scope in scopes {
            let subtree = walk(scope.element)
            guard !subtree.isEmpty else { continue }
            let lines = textLines(in: subtree)
            guard !lines.isEmpty else { continue }
            let closes = closeActions(in: subtree)
            guard closes.count == 1, let close = closes.first else { continue }
            candidates.append((scope, subtree, lines, close))
        }

        // The smallest group with one explicit close action represents a single banner.
        guard let candidate = candidates.min(by: { $0.tree.count < $1.tree.count }) else {
            guard retriesRemaining > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                NotificationAXRunLoop.shared.perform { [weak self] in
                    self?.handleCreatedElement(element, retriesRemaining: retriesRemaining - 1)
                }
            }
            return
        }
        let text = String(candidate.lines.joined(separator: "\n").prefix(Self.maximumPayloadLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isDuplicate(text) else { return }

        let metadata = sourceMetadata(scope: candidate.scope.element, close: candidate.close)
        let sourceBundleIdentifier = identifySource(in: metadata.nodes, headers: metadata.headers)
        let images = metadata.nodes.filter { role(of: $0.element) == kAXImageRole as String }
        let identifierCount = metadata.nodes.filter { attribute($0.element, kAXIdentifierAttribute) != nil }.count
        let imageHasWeChat = images.contains { node in
            [attribute(node.element, kAXDescriptionAttribute), attribute(node.element, kAXTitleAttribute)]
                .compactMap { $0 }.contains { $0.contains("微信") || $0.lowercased().contains("wechat") }
        }
        // Report structural facts only; do not export AX strings that may contain private content.
        let runningApps = NSWorkspace.shared.runningApplications
        let weChatApps = runningApps.filter {
            ($0.bundleIdentifier ?? "").lowercased().contains("wechat")
                || ($0.localizedName ?? "").contains("微信")
        }
        let containerNodes = metadata.nodes.filter {
            [kAXGroupRole as String, kAXWindowRole as String].contains(role(of: $0.element) ?? "")
        }
        let descriptions = containerNodes.flatMap { node in
            [attribute(node.element, kAXDescriptionAttribute),
             attribute(node.element, "AXAttributedDescription"),
             attribute(node.element, kAXTitleAttribute)].compactMap { $0 }
        }
        let weChatPrefixCount = descriptions.filter {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return value.hasPrefix("微信") || value.hasPrefix("wechat")
        }.count
        let bundleIdentifierCount = metadata.nodes.compactMap {
            attribute($0.element, kAXIdentifierAttribute)
        }.filter { $0.lowercased().contains("com.tencent") }.count
        let knownWeChatIDs = weChatApps.compactMap(\.bundleIdentifier).filter {
            $0.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil
        }.joined(separator: ",")
        let sourceDiagnostics = "来源范围 \(metadata.scopes) 层，图像节点 \(images.count)，标识字段 \(identifierCount)，微信图像标签\(imageHasWeChat ? "存在" : "未发现")。运行应用 \(runningApps.count)，微信应用 \(weChatApps.count)（\(knownWeChatIDs)），外层描述 \(descriptions.count)，微信开头 \(weChatPrefixCount)，腾讯标识 \(bundleIdentifierCount)。"

        let identifier = UUID().uuidString
        if let receiver = connection?.remoteObjectProxyWithErrorHandler({ _ in })
            as? BoringNotchNotificationEventReceiving {
            receiver.didCaptureNotification(identifier, text: text, sourceBundleIdentifier: sourceBundleIdentifier, sourceDiagnostics: sourceDiagnostics, capturedAt: Date().timeIntervalSince1970) { [weak self] accepted in
                guard accepted else { return }
                NotificationAXRunLoop.shared.perform {
                    guard self?.isActive == true else { return }
                    // Dismiss only after the main app has accepted the in-memory payload.
                    _ = AXUIElementPerformAction(candidate.close.element, candidate.close.name as CFString)
                }
            }
        }
    }

    private func walk(_ root: AXUIElement) -> [NotificationAXNode] {
        var queue = [NotificationAXNode(element: root, depth: 0)]
        var result: [NotificationAXNode] = []
        var cursor = 0

        while cursor < queue.count && result.count < Self.maximumNodes {
            let node = queue[cursor]
            cursor += 1
            guard !result.contains(where: { CFEqual($0.element, node.element) }) else { continue }
            result.append(node)
            guard node.depth < Self.maximumDepth else { continue }

            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node.element, kAXChildrenAttribute as CFString, &value) == .success,
                  let children = value as? [AXUIElement] else { continue }
            for child in children where queue.count < Self.maximumNodes {
                queue.append(NotificationAXNode(element: child, depth: node.depth + 1))
            }
        }
        return result
    }

    private func textLines(in nodes: [NotificationAXNode]) -> [String] {
        var lines: [String] = []
        for node in nodes where role(of: node.element) == kAXStaticTextRole as String {
            if let text = firstText(node.element, attributes: [kAXValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute]) {
                appendUnique(text, to: &lines)
            }
        }

        if lines.isEmpty {
            for node in nodes where role(of: node.element) == kAXGroupRole as String {
                if let text = firstText(node.element, attributes: [kAXDescriptionAttribute, "AXAttributedDescription", kAXValueAttribute]) {
                    appendUnique(text, to: &lines)
                }
            }
        }

        return Array(lines.prefix(8).map { String($0.prefix(600)) })
    }

    /// Inspect ancestors only while they expose the same unique single-banner close action.
    private func sourceMetadata(scope: AXUIElement, close: NotificationCloseAction)
        -> (nodes: [NotificationAXNode], headers: [String], scopes: Int) {
        var current: AXUIElement? = scope
        var nodes: [NotificationAXNode] = []
        var headers: [String] = []
        var scopeCount = 0
        for _ in 0..<6 {
            guard let element = current else { break }
            let subtree = walk(element)
            let closes = closeActions(in: subtree)
            guard subtree.count < Self.maximumNodes, closes.count == 1,
                  CFEqual(closes[0].element, close.element), closes[0].name == close.name else { break }
            scopeCount += 1
            for node in subtree where !nodes.contains(where: { CFEqual($0.element, node.element) }) {
                nodes.append(node)
            }
            if let header = textLines(in: subtree).first { appendUnique(header, to: &headers) }
            if role(of: element) == kAXWindowRole as String { break }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = (parent as! AXUIElement)
            guard role(of: current!) != kAXApplicationRole as String else { break }
        }
        return (nodes, headers, scopeCount)
    }

    /// Resolve source using identifiers, exact labels, and app prefixes in container descriptions.
    private func identifySource(in nodes: [NotificationAXNode], headers: [String]) -> String? {
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier != Self.notificationCenterBundleID && $0.bundleURL != nil
                && $0.activationPolicy == .regular
        }
        let identifiers = nodes.compactMap { attribute($0.element, kAXIdentifierAttribute) }
        let imageLabels = nodes.filter { role(of: $0.element) == kAXImageRole as String }
            .flatMap { node in
                [attribute(node.element, kAXDescriptionAttribute), attribute(node.element, kAXTitleAttribute)]
                    .compactMap { $0 }
            }
        let labels = imageLabels + headers
        let containerDescriptions = nodes.filter {
            [kAXGroupRole as String, kAXWindowRole as String].contains(role(of: $0.element) ?? "")
        }.flatMap { node in
            [attribute(node.element, kAXDescriptionAttribute),
             attribute(node.element, "AXAttributedDescription")].compactMap { $0 }
        }
        var matches = Set<String>()
        for application in applications {
            guard let bundleID = application.bundleIdentifier else { continue }
            if identifiers.contains(where: { identifier in
                // Composite AX identifiers may wrap the source bundle ID in a banner identifier.
                identifier.range(of: "(?<![A-Za-z0-9._-])" + NSRegularExpression.escapedPattern(for: bundleID)
                    + "(?![A-Za-z0-9_-])", options: .regularExpression) != nil
            }) {
                matches.insert(bundleID)
                continue
            }
            var names = [application.localizedName].compactMap { $0 }
            if let url = application.bundleURL, let bundle = Bundle(url: url) {
                names += [bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                          bundle.object(forInfoDictionaryKey: "CFBundleName") as? String].compactMap { $0 }
            }
            if bundleID == "com.tencent.xinWeChat" { names += ["微信", "WeChat"] }
            if labels.contains(where: { label in
                names.contains { label.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare($0) == .orderedSame }
            }) || containerDescriptions.contains(where: { description in
                names.contains { name in
                    let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, text.lowercased().hasPrefix(name.lowercased()) else { return false }
                    let suffix = text.dropFirst(name.count)
                    // Only accept a leading app label with a header separator, never a body substring.
                    return suffix.isEmpty || suffix.first.map { "，,:：\n\r\t ".contains($0) } == true
                }
            }) { matches.insert(bundleID) }
        }
        return matches.count == 1 ? matches.first : nil
    }

    private func closeActions(in nodes: [NotificationAXNode]) -> [NotificationCloseAction] {
        var semantic: [NotificationCloseAction] = []
        var buttonFallbacks: [NotificationCloseAction] = []

        for node in nodes {
            var rawNames: CFArray?
            if AXUIElementCopyActionNames(node.element, &rawNames) == .success,
               let names = rawNames as? [String] {
                for name in names {
                    var rawDescription: CFString?
                    _ = AXUIElementCopyActionDescription(node.element, name as CFString, &rawDescription)
                    let description = (rawDescription as String?) ?? ""
                    if isCloseAction(name: name, description: description) {
                        semantic.append(NotificationCloseAction(element: node.element, name: name))
                    }
                }
            }

            guard role(of: node.element) == kAXButtonRole as String else { continue }
            let subrole = attribute(node.element, kAXSubroleAttribute) ?? ""
            let label = [attribute(node.element, kAXTitleAttribute), attribute(node.element, kAXDescriptionAttribute)]
                .compactMap { $0 }.joined(separator: " ")
            if subrole == kAXCloseButtonSubrole as String || isCloseAction(name: label, description: label) {
                buttonFallbacks.append(NotificationCloseAction(element: node.element, name: kAXPressAction as String))
            }
        }

        let distinctSemantic = distinctActions(semantic)
        if !distinctSemantic.isEmpty { return distinctSemantic }
        return distinctActions(buttonFallbacks)
    }

    private func distinctActions(_ actions: [NotificationCloseAction]) -> [NotificationCloseAction] {
        var result: [NotificationCloseAction] = []
        for action in actions where !result.contains(where: {
            CFEqual($0.element, action.element) && $0.name == action.name
        }) {
            result.append(action)
        }
        return result
    }

    private func isCloseAction(name: String, description: String) -> Bool {
        let name = name.lowercased()
        let description = description.lowercased()
        let combined = name + " " + description
        guard !combined.contains("clear"), !combined.contains("all"), !combined.contains("清除全部"), !combined.contains("全部移除") else {
            return false
        }
        return name.hasPrefix("name:close")
            || ["close", "关闭", "關閉", "dismiss"].contains(where: combined.contains)
    }

    private func firstText(_ element: AXUIElement, attributes: [String]) -> String? {
        for name in attributes {
            if let text = attribute(element, name), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func appendUnique(_ text: String, to lines: inout [String]) {
        guard !text.isEmpty, !lines.contains(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) else { return }
        lines.append(text)
    }

    private func role(of element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        if let string = value as? String { return string }
        return (value as? NSAttributedString)?.string
    }

    private func isDuplicate(_ text: String) -> Bool {
        let now = Date()
        fingerprints = fingerprints.filter { now.timeIntervalSince($0.value) < 4 }
        let fingerprint = text.lowercased()
        guard fingerprints[fingerprint] == nil else { return true }
        if fingerprints.count >= 64, let oldest = fingerprints.min(by: { $0.value < $1.value })?.key {
            fingerprints.removeValue(forKey: oldest)
        }
        fingerprints[fingerprint] = now
        return false
    }
}

private func notificationBannerAXCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let watcher = Unmanaged<NotificationBannerWatcher>.fromOpaque(context).takeUnretainedValue()
    watcher.handleCreatedElement(element)
}
