//
//  NotchHomeView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-18.
//  Modified by Harsh Vardhan Goswami & Richard Kunkli & Mustafa Ramadan
//

import Combine
import Defaults
import SwiftUI

// MARK: - Music Player Components

struct MusicPlayerView: View {
    @EnvironmentObject var vm: BoringViewModel
    let albumArtNamespace: Namespace.ID
    var useHorizontalLayout: Bool = false

    var body: some View {
        if useHorizontalLayout {
            MusicControlsView(albumArtNamespace: albumArtNamespace)
                .frame(height: 171)
        } else {
            VStack(spacing: 5) {
                AlbumArtView(vm: vm, albumArtNamespace: albumArtNamespace)
                    .frame(width: 54, height: 54)
                MusicControlsView()
                    .drawingGroup()
                    .compositingGroup()
                    .frame(height: 112)
            }
        }
    }
}

struct AlbumArtView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var vm: BoringViewModel
    let albumArtNamespace: Namespace.ID

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if Defaults[.lightingEffect] {
                albumArtBackground
            }
            albumArtButton
        }
    }

    private var albumArtBackground: some View {
        Image(nsImage: musicManager.albumArt)
            .resizable()
            .clipped()
            .clipShape(
                RoundedRectangle(
                    cornerRadius: Defaults[.cornerRadiusScaling]
                        ? MusicPlayerImageSizes.cornerRadiusInset.opened
                        : MusicPlayerImageSizes.cornerRadiusInset.closed)
            )
            .aspectRatio(1, contentMode: .fit)
            .scaleEffect(x: 1.3, y: 1.4)
            .rotationEffect(.degrees(92))
            .blur(radius: 40)
            .opacity(musicManager.isPlaying ? 0.5 : 0)
    }

    private var albumArtButton: some View {
        ZStack {
            Button {
                musicManager.openMusicApp()
            } label: {
                ZStack(alignment:.bottomTrailing) {
                    albumArtImage
                    appIconOverlay
                }
            }
            .buttonStyle(PlainButtonStyle())
            .scaleEffect(musicManager.isPlaying ? 1 : 0.85)
            
            albumArtDarkOverlay
        }
    }

    private var albumArtDarkOverlay: some View {
        Rectangle()
            .aspectRatio(1, contentMode: .fit)
            .foregroundColor(Color.black)
            .opacity(musicManager.isPlaying ? 0 : 0.8)
            .blur(radius: 50)
    }
                

    private var albumArtImage: some View {
        Image(nsImage: musicManager.albumArt)
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
            .clipped()
            .clipShape(
                RoundedRectangle(
                    cornerRadius: Defaults[.cornerRadiusScaling]
                        ? MusicPlayerImageSizes.cornerRadiusInset.opened
                        : MusicPlayerImageSizes.cornerRadiusInset.closed)
            )
    }

    @ViewBuilder
    private var appIconOverlay: some View {
        if vm.notchState == .open && !musicManager.usingAppIconForArtwork {
            AppIcon(for: musicManager.bundleIdentifier ?? "com.apple.Music")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 30)
                .offset(x: 10, y: 10)
                .transition(.scale.combined(with: .opacity))
                .zIndex(2)
        }
    }
}

struct MusicControlsView: View {
    var albumArtNamespace: Namespace.ID? = nil
    @ObservedObject var musicManager = MusicManager.shared
        @EnvironmentObject var vm: BoringViewModel
        @ObservedObject var webcamManager = WebcamManager.shared
    @State private var sliderValue: Double = 0
    @State private var dragging: Bool = false
    @State private var lastDragged: Date = .distantPast
    @Default(.musicControlSlots) private var slotConfig
    @Default(.musicControlSlotLimit) private var slotLimit

    var body: some View {
        VStack(alignment: .leading) {
            if let albumArtNamespace {
                GeometryReader { geometry in
                    HStack(spacing: 16) {
                        AlbumArtView(vm: vm, albumArtNamespace: albumArtNamespace)
                            .frame(width: 90, height: 90)
                        songInfo(width: max(0, geometry.size.width - 106))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 100)
                musicSlider
            } else {
                songInfoAndSlider
                    .frame(height: 82)
            }
            slotToolbar
                .frame(height: 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(PlainButtonStyle())
    }

    private var songInfoAndSlider: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 4) {
                songInfo(width: geo.size.width)
                musicSlider
            }
        }
        .padding(.top, 10)
        .padding(.leading, 5)
    }

    private func songInfo(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MarqueeText(
                $musicManager.songTitle, font: .headline, nsFont: .headline, textColor: .white,
                frameWidth: width)
            MarqueeText(
                $musicManager.artistName,
                font: .headline,
                nsFont: .headline,
                textColor: Defaults[.playerColorTinting]
                    ? Color(nsColor: musicManager.avgColor)
                        .ensureMinimumBrightness(factor: 0.6) : .gray,
                frameWidth: width
            )
            .fontWeight(.medium)
            if Defaults[.enableLyrics] {
                TimelineView(.animation(minimumInterval: 0.25)) { timeline in
                    let currentElapsed: Double = {
                        guard musicManager.isPlaying else { return musicManager.elapsedTime }
                        let delta = timeline.date.timeIntervalSince(musicManager.timestampDate)
                        let progressed = musicManager.elapsedTime + (delta * musicManager.playbackRate)
                        return min(max(progressed, 0), musicManager.songDuration)
                    }()
                    let line: String = {
                        if musicManager.isFetchingLyrics { return "Loading lyrics…" }
                        if !musicManager.syncedLyrics.isEmpty {
                            return musicManager.lyricLine(at: currentElapsed)
                        }
                        let trimmed = musicManager.currentLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? "No lyrics found" : trimmed.replacingOccurrences(of: "\n", with: " ")
                    }()
                    let isPersian = line.unicodeScalars.contains { scalar in
                        let v = scalar.value
                        return v >= 0x0600 && v <= 0x06FF
                    }
                    MarqueeText(
                        .constant(line),
                        font: .subheadline,
                        nsFont: .subheadline,
                        textColor: musicManager.isFetchingLyrics ? .gray.opacity(0.7) : .gray,
                        frameWidth: width
                    )
                    .font(isPersian ? .custom("Vazirmatn-Regular", size: NSFont.preferredFont(forTextStyle: .subheadline).pointSize) : .subheadline)
                    .lineLimit(1)
                    .opacity(musicManager.isPlaying ? 1 : 0)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var musicSlider: some View {
        TimelineView(.animation(minimumInterval: musicManager.playbackRate > 0 ? 0.1 : nil)) { timeline in
            MusicSliderView(
                sliderValue: $sliderValue,
                duration: $musicManager.songDuration,
                lastDragged: $lastDragged,
                color: musicManager.avgColor,
                dragging: $dragging,
                currentDate: timeline.date,
                timestampDate: musicManager.timestampDate,
                elapsedTime: musicManager.elapsedTime,
                playbackRate: musicManager.playbackRate,
                isPlaying: musicManager.isPlaying
            ) { newValue in
                MusicManager.shared.seek(to: newValue)
            }
            .padding(.top, 5)
            .frame(height: 36)
        }
    }

    private var slotToolbar: some View {
        let slots = activeSlots
        return HStack(spacing: 6) {
            ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                slotView(for: slot)
                    .frame(alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var activeSlots: [MusicControlButton] {
        let sanitizedLimit = min(
            max(slotLimit, MusicControlButton.minSlotCount),
            MusicControlButton.maxSlotCount
        )
        let padded = slotConfig.padded(to: sanitizedLimit, filler: .none)
        let result = Array(padded.prefix(sanitizedLimit))
        // If calendar and camera are both visible alongside music, hide the edge slots
        let shouldHideEdges = Defaults[.showCalendar] && Defaults[.showMirror] && webcamManager.cameraAvailable && vm.isCameraExpanded
        if shouldHideEdges && result.count >= 5 {
            return Array(result.dropFirst().dropLast())
        }

        return result
    }

    @ViewBuilder
    private func slotView(for slot: MusicControlButton) -> some View {
        switch slot {
        case .shuffle:
            HoverButton(icon: "shuffle", iconColor: musicManager.isShuffled ? .red : .primary, scale: .medium) {
                MusicManager.shared.toggleShuffle()
            }
        case .previous:
            HoverButton(icon: "backward.fill", scale: .medium) {
                MusicManager.shared.previousTrack()
            }
        case .playPause:
            HoverButton(icon: musicManager.isPlaying ? "pause.fill" : "play.fill", scale: .large) {
                MusicManager.shared.togglePlay()
            }
        case .next:
            HoverButton(icon: "forward.fill", scale: .medium) {
                MusicManager.shared.nextTrack()
            }
        case .repeatMode:
            HoverButton(icon: repeatIcon, iconColor: repeatIconColor, scale: .medium) {
                MusicManager.shared.toggleRepeat()
            }
        case .volume:
            VolumeControlView()
        case .favorite:
            FavoriteControlButton()
        case .goBackward:
            HoverButton(icon: "gobackward.15", scale: .medium) {
                MusicManager.shared.skip(seconds: -15)
            }
        case .goForward:
            HoverButton(icon: "goforward.15", scale: .medium) {
                MusicManager.shared.skip(seconds: 15)
            }
        case .none:
            Color.clear.frame(height: 1)
        }
    }

    private var repeatIcon: String {
        switch musicManager.repeatMode {
        case .off:
            return "repeat"
        case .all:
            return "repeat"
        case .one:
            return "repeat.1"
        }
    }

    private var repeatIconColor: Color {
        switch musicManager.repeatMode {
        case .off:
            return .primary
        case .all, .one:
            return .red
        }
    }
}

struct FavoriteControlButton: View {
    @ObservedObject var musicManager = MusicManager.shared

    var body: some View {
        HoverButton(icon: iconName, iconColor: iconColor, scale: .medium) {
            MusicManager.shared.toggleFavoriteTrack()
        }
        .disabled(!musicManager.canFavoriteTrack)
        .opacity(musicManager.canFavoriteTrack ? 1 : 0.35)
    }

    private var iconName: String {
        musicManager.isFavoriteTrack ? "heart.fill" : "heart"
    }

    private var iconColor: Color {
        musicManager.isFavoriteTrack ? .red : .primary
    }
}

private extension Array where Element == MusicControlButton {
    func padded(to length: Int, filler: MusicControlButton) -> [MusicControlButton] {
        if count >= length { return self }
        return self + Array(repeating: filler, count: length - count)
    }
}

// MARK: - Volume Control View

struct VolumeControlView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @State private var volumeSliderValue: Double = 0.5
    @State private var dragging: Bool = false
    @State private var showVolumeSlider: Bool = false
    @State private var lastVolumeUpdateTime: Date = Date.distantPast
    private let volumeUpdateThrottle: TimeInterval = 0.1
    
    var body: some View {
        HStack(spacing: 4) {
            Button(action: {
                if musicManager.volumeControlSupported {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        showVolumeSlider.toggle()
                    }
                }
            }) {
                Image(systemName: volumeIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(musicManager.volumeControlSupported ? .white : .gray)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!musicManager.volumeControlSupported)
            .frame(width: 24)

            if showVolumeSlider && musicManager.volumeControlSupported {
                CustomSlider(
                    value: $volumeSliderValue,
                    range: 0.0...1.0,
                    color: .white,
                    dragging: $dragging,
                    lastDragged: .constant(Date.distantPast),
                    onValueChange: { newValue in
                        MusicManager.shared.setVolume(to: newValue)
                    },
                    onDragChange: { newValue in
                        let now = Date()
                        if now.timeIntervalSince(lastVolumeUpdateTime) > volumeUpdateThrottle {
                            MusicManager.shared.setVolume(to: newValue)
                            lastVolumeUpdateTime = now
                        }
                    }
                )
                .frame(width: 48, height: 8)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .clipped()
        .onReceive(musicManager.$volume) { volume in
            if !dragging {
                volumeSliderValue = volume
            }
        }
        .onReceive(musicManager.$volumeControlSupported) { supported in
            if !supported {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showVolumeSlider = false
                }
            }
        }
        .onChange(of: showVolumeSlider) { _, isShowing in
            if isShowing {
                // Sync volume from app when slider appears
                Task {
                    await MusicManager.shared.syncVolumeFromActiveApp()
                }
            }
        }
        .onDisappear {
            // volumeUpdateTask?.cancel() // No longer needed
        }
    }
    
    
    private var volumeIcon: String {
        if !musicManager.volumeControlSupported {
            return "speaker.slash"
        } else if volumeSliderValue == 0 {
            return "speaker.slash.fill"
        } else if volumeSliderValue < 0.33 {
            return "speaker.1.fill"
        } else if volumeSliderValue < 0.66 {
            return "speaker.2.fill"
        } else {
            return "speaker.3.fill"
        }
    }
}

// MARK: - Main View

struct NotchHomeView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var webcamManager = WebcamManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Default(.showCalendar) private var showCalendar
    @Default(.showMirror) private var showMirror
    let albumArtNamespace: Namespace.ID

    var body: some View {
        Group {
            if !coordinator.firstLaunch {
                mainContent
            }
        }
        // simplified: use a straightforward opacity transition
        .transition(.opacity)
    }

    private var shouldShowCamera: Bool {
        showMirror && webcamManager.cameraAvailable && vm.isCameraExpanded
    }

    private var hasAuxiliaryPanel: Bool {
        showCalendar || shouldShowCamera
    }

    private var homeContentWidth: CGFloat {
        openNotchSize.width - cornerRadiusInsets.opened.top * 2 - 24
    }

    private var mainContent: some View {
        HStack(alignment: .top, spacing: 8) {
            MusicPlayerView(albumArtNamespace: albumArtNamespace, useHorizontalLayout: !hasAuxiliaryPanel)
                .frame(width: hasAuxiliaryPanel ? 190 : nil, alignment: .topLeading)
                .frame(maxWidth: hasAuxiliaryPanel ? nil : .infinity, alignment: .topLeading)

            if hasAuxiliaryPanel {
                VStack(alignment: .leading, spacing: 8) {
                    if showCalendar {
                        CalendarView()
                            .frame(width: shouldShowCamera ? 220 : 230)
                            .onHover { vm.isHoveringCalendar = $0 }
                            .environmentObject(vm)
                            .transition(.opacity)
                    }
                    if shouldShowCamera {
                        CameraPreviewView(webcamManager: webcamManager)
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .opacity(vm.notchState == .closed ? 0 : 1)
                            .blur(radius: vm.notchState == .closed ? 20 : 0)
                            .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.76, blendDuration: 0), value: shouldShowCamera)
                    }
                }
                .frame(width: 230, alignment: .topLeading)
            }

            if hasAuxiliaryPanel {
                Spacer(minLength: 0)
            }

            CodexQuotaStrip()
                .frame(width: 124)
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
        .frame(width: homeContentWidth, alignment: .leading)
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
        .blur(radius: vm.notchState == .closed ? 30 : 0)
    }
}

struct CodexStatusActivityView: View {
    let event: CodexActivityEvent

    var body: some View {
        Button(action: openCodex) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title.isEmpty ? "Codex" : event.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(event.status.displayTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.68))
                }
                Spacer(minLength: 0)
                Text("Codex")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Codex")
    }

    private func openCodex() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            NSWorkspace.shared.open(appURL)
        }
    }
}

struct CodexPinnedTasksView: View {
    let tasks: [CodexPinnedTask]
    @Binding var selectedTaskID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ScrollView(.horizontal) {
                HStack(spacing: 9) {
                    ForEach(tasks) { task in
                        taskTile(task)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 3)
            }
            .scrollIndicators(.hidden)

        }
        .padding(.vertical, 8)
        .onChange(of: tasks) { _, updatedTasks in
            if let selectedTaskID, !updatedTasks.contains(where: { $0.id == selectedTaskID }) {
                self.selectedTaskID = nil
            }
        }
    }

    private func taskTile(_ task: CodexPinnedTask) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.28)) {
                selectedTaskID = selectedTaskID == task.id ? nil : task.id
            }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 12, weight: .bold))
                    Text("Codex")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    Circle()
                        .fill(task.status == .running ? Color.blue : Color.white.opacity(0.36))
                        .frame(width: 7, height: 7)
                }
                Text(task.title.isEmpty ? String(localized: "Untitled task") : task.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    Image(systemName: task.status == .running ? "waveform" : "terminal")
                        .font(.system(size: 10, weight: .semibold))
                    Text(task.status.displayTitle)
                        .font(.system(size: 10, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(task.status == .running ? Color.blue : Color.white.opacity(0.62))
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(12)
            .frame(width: 160, height: 92, alignment: .topLeading)
            .background(
                LinearGradient(colors: [Color.white.opacity(0.12), Color.white.opacity(0.045)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 20)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(selectedTaskID == task.id ? Color.blue.opacity(0.8) : Color.white.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("Show task details")

    }
}

// The notch itself cannot become key. A nonactivating child panel allows editing
// without changing focus behavior for music, shelf and other notch controls.
struct CodexTaskPanelAnchor: NSViewRepresentable {
    let isPresented: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.updatePanel = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.update(from: view)
        }
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        context.coordinator.isPresented = isPresented
        // SwiftUI's layout is final on the next main-loop iteration.
        DispatchQueue.main.async { [weak view] in view?.updatePanel?() }
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) {
        view.updatePanel = nil
        coordinator.dismiss()
    }

    final class AnchorView: NSView {
        var updatePanel: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updatePanel?() }
        override func layout() { super.layout(); updatePanel?() }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            updatePanel?()
        }
    }

    final class DetailWindow: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    @MainActor final class Coordinator {
        var isPresented = false
        private var panel: DetailWindow?
        private var mouseMonitor: Any?

        func update(from anchor: NSView) {
            guard isPresented, let parent = anchor.window, anchor.bounds.width > 0 else {
                dismiss()
                return
            }
            let rect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let screen = parent.screen ?? NSScreen.main
            let bottom = screen?.visibleFrame.minY ?? 0
            let height = min(440, rect.minY - 8 - bottom)
            guard height >= 180 else { dismiss(); return }
            let panel: DetailWindow
            if let existing = self.panel {
                panel = existing
            } else {
                panel = DetailWindow(contentRect: .zero,
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isFloatingPanel = true
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = true
                panel.isReleasedWhenClosed = false
                panel.hidesOnDeactivate = false
                panel.level = parent.level
                panel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
                panel.appearance = NSAppearance(named: .darkAqua)
                panel.contentView = NSHostingView(rootView: CodexSelectedTaskPanel())
                self.panel = panel
                parent.addChildWindow(panel, ordered: .above)
                mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                    if let panel = self?.panel,
                       event.window !== panel, event.window !== panel.parent {
                        CodexPinnedTasksService.shared.selectedTaskID = nil
                    }
                    return event
                }
            }
            panel.sharingType = parent.sharingType
            panel.setFrame(NSRect(x: rect.minX, y: rect.minY - 8 - height,
                                  width: rect.width, height: height), display: true)
            if !panel.isVisible { panel.makeKeyAndOrderFront(nil) }
        }

        func dismiss() {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            mouseMonitor = nil
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            panel = nil
        }
    }
}

private struct CodexSelectedTaskPanel: View {
    @ObservedObject private var service = CodexPinnedTasksService.shared

    var body: some View {
        if let task = service.tasks.first(where: { $0.id == service.selectedTaskID }) {
            CodexTaskDetailPanel(task: task) { service.selectedTaskID = nil }
                .id(task.id)
                .onExitCommand { service.selectedTaskID = nil }
        }
    }
}

private struct CodexTaskDetailPanel: View {
    let task: CodexPinnedTask
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(task.title.isEmpty ? String(localized: "Untitled task") : task.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(task.status.displayTitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(task.status == .running ? Color.blue : Color.white.opacity(0.62))
            }
            HStack {
                Text("最近对话").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("关闭会话详情")
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        if let messages = task.messages, !messages.isEmpty {
                            ForEach(messages) { message in
                                messageRow(message)
                                    .id(message.id)
                            }
                        } else if !task.latestReply.isEmpty {
                            Text(task.latestReply)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.82))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("暂无对话内容")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .padding(.trailing, 4)
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    if let lastID = task.messages?.last?.id {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
                .onChange(of: task.messages?.last?.id) { _, lastID in
                    if let lastID { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(lastID, anchor: .bottom) } }
                }
            }
            .frame(maxHeight: .infinity)
            CodexTaskReplyComposer(task: task)
            Button("在 Codex 中打开") {
                guard let url = URL(string: "codex://threads/\(task.id)") else { return }
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.45))
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.10)))
        .preferredColorScheme(.dark)
    }

    private func messageRow(_ message: CodexTaskMessage) -> some View {
        let isUser = message.role == .user
        return HStack {
            if isUser { Spacer(minLength: 34) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: isUser ? "person.fill" : "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text(isUser ? "你" : (message.phase == "commentary" ? "Codex · 实时进度" : "Codex"))
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(isUser ? Color.white.opacity(0.52) : Color.blue.opacity(0.95))
                Text(message.text)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.88))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isUser ? Color.white.opacity(0.055) : Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isUser ? Color.white.opacity(0.06) : Color.blue.opacity(0.22), lineWidth: 1))
            if !isUser { Spacer(minLength: 34) }
        }
    }

}

private struct CodexTaskReplyComposer: View {
    let task: CodexPinnedTask
    @FocusState private var isPromptFocused: Bool
    @State private var prompt = ""
    @State private var isSending = false
    @State private var sendError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("告诉 Codex 接下来做什么…")
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $prompt)
                        .scrollContentBackground(.hidden)
                        .focused($isPromptFocused)
                        .frame(height: 62)
                        .disabled(isSending)
                }
                .font(.system(size: 13))
                Button(action: send) {
                    Group {
                        if isSending { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.up").font(.system(size: 17, weight: .semibold)) }
                    }
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())
                .help("发送到当前会话")
                .accessibilityLabel("发送")
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isSending || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.10)))
            if let sendError {
                Text(sendError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { isPromptFocused = true }
    }

    private func send() {
        let message = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, !message.isEmpty else { return }
        isSending = true
        sendError = nil
        Task {
            let error = await XPCHelperClient.shared.sendCodexInstruction(threadID: task.id, prompt: message)
            isSending = false
            if let error {
                sendError = error
            } else {
                prompt = ""
                await CodexPinnedTasksService.shared.refreshSelectedTask()
                isPromptFocused = true
            }
        }
    }
}

extension CodexDisplayStatus {
    var displayTitle: String {
        switch self {
        case .running: return String(localized: "Working")
        case .waiting: return String(localized: "Waiting")
        case .completed: return String(localized: "Completed")
        case .interrupted: return String(localized: "Interrupted")
        case .idle: return String(localized: "Idle")
        }
    }
}

struct MusicSliderView: View {
    @Binding var sliderValue: Double
    @Binding var duration: Double
    @Binding var lastDragged: Date
    var color: NSColor
    @Binding var dragging: Bool
    let currentDate: Date
    let timestampDate: Date
    let elapsedTime: Double
    let playbackRate: Double
    let isPlaying: Bool
    var onValueChange: (Double) -> Void


    var body: some View {
        VStack {
            CustomSlider(
                value: $sliderValue,
                range: 0...duration,
                color: Defaults[.sliderColor] == SliderColorEnum.albumArt
                    ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.8)
                    : Defaults[.sliderColor] == SliderColorEnum.accent ? .effectiveAccent : .white,
                dragging: $dragging,
                lastDragged: $lastDragged,
                onValueChange: onValueChange
            )
            .frame(height: 10, alignment: .center)

            HStack {
                Text(timeString(from: sliderValue))
                Spacer()
                Text(timeString(from: duration))
            }
            .fontWeight(.medium)
            .foregroundColor(
                Defaults[.playerColorTinting]
                    ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.6) : .gray
            )
            .font(.caption)
        }
        .onChange(of: currentDate) {
           guard !dragging, timestampDate.timeIntervalSince(lastDragged) > -1 else { return }
            sliderValue = MusicManager.shared.estimatedPlaybackPosition(at: currentDate)
        }
    }

    func timeString(from seconds: Double) -> String {
        let totalMinutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        } else {
            return String(format: "%d:%02d", minutes, remainingSeconds)
        }
    }
}

struct CustomSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var color: Color = .white
    @Binding var dragging: Bool
    @Binding var lastDragged: Date
    var onValueChange: ((Double) -> Void)?
    var onDragChange: ((Double) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = CGFloat(dragging ? 9 : 5)
            let rangeSpan = range.upperBound - range.lowerBound

            let progress = rangeSpan == .zero ? 0 : (value - range.lowerBound) / rangeSpan
            let filledTrackWidth = min(max(progress, 0), 1) * width

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.gray.opacity(0.3))
                    .frame(height: height)

                Rectangle()
                    .fill(color)
                    .frame(width: filledTrackWidth, height: height)
            }
            .cornerRadius(height / 2)
            .frame(height: 10)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        withAnimation {
                            dragging = true
                        }
                        let newValue = range.lowerBound + Double(gesture.location.x / width) * rangeSpan
                        value = min(max(newValue, range.lowerBound), range.upperBound)
                        onDragChange?(value)
                    }
                    .onEnded { _ in
                        onValueChange?(value)
                        dragging = false
                        lastDragged = Date()
                    }
            )
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: dragging)
        }
    }
}
