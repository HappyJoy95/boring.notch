//
//  QuickShareService.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

/// Dynamic representation of a sharing provider discovered at runtime
struct QuickShareProvider: Identifiable, Hashable, Sendable {
    var id: String
    var imageData: Data?
    var supportsRawText: Bool
}

class QuickShareService: ObservableObject {
    static let shared = QuickShareService()

    /// Finder exposes Xiaomi Share as a Services menu command rather than a
    /// standard macOS sharing extension.
    static let xiaomiProviderID = "xiaomi-interconnectivity"
    static let xiaomiProviderName = "小米互传"
    private static let xiaomiFinderServiceName = "使用小米互传发送"
    
    @Published var availableProviders: [QuickShareProvider] = []
    @Published var isPickerOpen = false
    private var cachedServices: [String: NSSharingService] = [:]
    // Hold security-scoped URLs during sharing
    private var sharingAccessingURLs: [URL] = []
    private var lifecycleDelegate: SharingLifecycleDelegate?
   
    init() {
        Task {
            await discoverAvailableProviders()
        }
    }
    
    // MARK: - Provider Discovery
    
    @MainActor
    func discoverAvailableProviders() async {
        let finder = ShareServiceFinder()

        // Use simple test items without creating actual temp files
        // This avoids issues with the Share Sheet retaining references to deleted files
        let testItems: [Any] = [
            URL(string:"http://example.com") ?? URL(fileURLWithPath: "/"),
            "Test Text" as NSString
        ]

        let services = await finder.findApplicableServices(for: testItems)

        var providers: [QuickShareProvider] = []

        for svc in services {
            let title = svc.title
            let imgData = svc.image.tiffRepresentation
            let supportsRawText = svc.canPerform(withItems: ["Test Text"])
            let provider = QuickShareProvider(id: title, imageData: imgData, supportsRawText: supportsRawText)
            if !providers.contains(provider) {
                providers.append(provider)
                cachedServices[title] = svc
            }
        }
        
        if let idx = providers.firstIndex(where: { $0.id == "AirDrop" }) {
            let ad = providers.remove(at: idx)
            providers.insert(ad, at: 0)
        }

        if !providers.contains(where: { $0.id == "System Share Menu" }) {
            providers.append(QuickShareProvider(id: "System Share Menu", imageData: nil, supportsRawText: true))
        }

        // This service is registered by Xiaomi Interconnectivity and may not
        // appear in NSSharingServicePicker's list of sharing extensions.
        if !providers.contains(where: { $0.id == Self.xiaomiProviderID }) {
            providers.append(QuickShareProvider(id: Self.xiaomiProviderID, imageData: nil, supportsRawText: false))
        }

        self.availableProviders = providers

    }
    
    // MARK: - File Picker
    @MainActor
    func showFilePicker(for provider: QuickShareProvider, from view: NSView?) async {
        guard !isPickerOpen else {
            print("⚠️ QuickShareService: File picker already open")
            return
        }

        isPickerOpen = true
        SharingStateManager.shared.beginInteraction()

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.title = "Select Files for \(provider.id)"
        panel.message = "Choose files to share via \(provider.id)"

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            defer {
                self?.isPickerOpen = false
                SharingStateManager.shared.endInteraction()
            }

            if response == .OK && !panel.urls.isEmpty {
                Task {
                    await self?.shareFilesOrText(panel.urls, using: provider, from: view)
                }
            }
        }

        let response = panel.runModal()
        completion(response)
    }
    
    // MARK: - Sharing
    @MainActor
    func shareFilesOrText(_ items: [Any], using provider: QuickShareProvider, from view: NSView?) async {
        let fileURLs = items.compactMap { $0 as? URL }.filter { $0.isFileURL }
        // Stop any previous sharing access
        stopSharingAccessingURLs()
        // Start security-scoped access for all file URLs
        sharingAccessingURLs = fileURLs.filter { $0.startAccessingSecurityScopedResource() }

        if provider.id == Self.xiaomiProviderID {
            guard !fileURLs.isEmpty else {
                NSLog("Xiaomi Share service only accepts files")
                stopSharingAccessingURLs()
                return
            }

            let pasteboard = NSPasteboard(name: NSPasteboard.Name("BoringNotch.XiaomiShareService"))
            pasteboard.clearContents()
            pasteboard.writeObjects(fileURLs as [NSURL])
            pasteboard.setPropertyList(fileURLs.map(\.path), forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))

            let succeeded = NSPerformService(Self.xiaomiFinderServiceName, pasteboard)
            if !succeeded {
                NSLog("Could not invoke Finder service: %@", Self.xiaomiFinderServiceName)
            }
            stopSharingAccessingURLs()
            return
        }

        // Setup lifecycle delegate to keep notch open during picker/service
        let delegate = SharingStateManager.shared.makeDelegate { [weak self] in
            self?.lifecycleDelegate = nil
            self?.stopSharingAccessingURLs()
        }
        lifecycleDelegate = delegate

        if let svc = cachedServices[provider.id], svc.canPerform(withItems: items) {
            // For direct service path, explicitly mark service interaction start
            delegate.markServiceBegan()
            svc.delegate = delegate
            svc.perform(withItems: items)
        } else {
            let picker = NSSharingServicePicker(items: items)
            picker.delegate = delegate
            delegate.markPickerBegan()
            if let view {
                picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
            }
        }
    }

    private func stopSharingAccessingURLs() {
        NSLog("Stopping sharing access to URLs")
        for url in sharingAccessingURLs {
            url.stopAccessingSecurityScopedResource()
        }
        sharingAccessingURLs.removeAll()
    }
// MARK: - SharingServiceDelegate

private class SharingServiceDelegate: NSObject {}
    
    func shareDroppedFiles(_ providers: [NSItemProvider], using shareProvider: QuickShareProvider, from view: NSView?) async {
        var itemsToShare: [Any] = []
        var foundText: String?

        for provider in providers {
            if let webURL = await provider.extractURL() {
                itemsToShare.append(webURL)
            } else if foundText == nil, let text = await provider.extractText() {
                foundText = text
            } else if let itemFileURL = await provider.extractItem() {
                let resolvedURL = await resolveShelfItemBookmark(for: itemFileURL) ?? itemFileURL
                itemsToShare.append(resolvedURL)
            }
        }

        // If text was found, prioritize sharing it.
        if let text = foundText {
            if shareProvider.supportsRawText {
                await shareFilesOrText([text], using: shareProvider, from: view)
            } else {
                if let tempTextURL = await TemporaryFileStorageService.shared.createTempFile(for: .text(text)) {
                    await shareFilesOrText([tempTextURL], using: shareProvider, from: view)
                    TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: tempTextURL)
                } else {
                    await shareFilesOrText([text], using: shareProvider, from: view)
                }
            }
        } else if !itemsToShare.isEmpty {
            await shareFilesOrText(itemsToShare, using: shareProvider, from: view)
        }
    }

    private func resolveShelfItemBookmark(for fileURL: URL) async -> URL? {
        let items = await ShelfStateViewModel.shared.items

        for itm in items {
            if let resolved = await ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: itm) {
                if resolved.standardizedFileURL.path == fileURL.standardizedFileURL.path {
                    return resolved
                }
            }
        }
        print("❌ Failed to resolve bookmark for shelf item")
        return nil
    }
}

// MARK: - App Storage Extension for Provider Selection

extension QuickShareProvider {
    static var defaultProvider: QuickShareProvider {
        let svc = QuickShareService.shared

        if let airdrop = svc.availableProviders.first(where: { $0.id == "AirDrop" }) {
            return airdrop
        }
        if let xiaomi = svc.availableProviders.first(where: { $0.id == QuickShareService.xiaomiProviderID }) {
            return xiaomi
        }
        return svc.availableProviders.first ?? QuickShareProvider(id: "System Share Menu", imageData: nil, supportsRawText: true)
    }
}
