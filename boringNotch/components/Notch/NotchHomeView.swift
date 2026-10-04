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
            if Defaults[.enableLyrics] && musicManager.hasAvailableLyrics {
                TimelineView(.animation(minimumInterval: 0.25)) { timeline in
                    let currentElapsed: Double = {
                        guard musicManager.isPlaying else { return musicManager.elapsedTime }
                        let delta = timeline.date.timeIntervalSince(musicManager.timestampDate)
                        let progressed = musicManager.elapsedTime + (delta * musicManager.playbackRate)
                        return min(max(progressed, 0), musicManager.songDuration)
                    }()
                    let line: String = {
                        if !musicManager.syncedLyrics.isEmpty {
                            return musicManager.lyricLine(at: currentElapsed)
                        }
                        let trimmed = musicManager.currentLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.replacingOccurrences(of: "\n", with: " ")
                    }()
                    let isPersian = line.unicodeScalars.contains { scalar in
                        let v = scalar.value
                        return v >= 0x0600 && v <= 0x06FF
                    }
                    MarqueeText(
                        .constant(line),
                        font: .subheadline,
                        nsFont: .subheadline,
                        textColor: musicManager.lyricsColor,
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
            .help(musicManager.isShuffled ? "随机播放" : musicManager.repeatMode == .one ? "单曲循环" : "列表播放")
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
        if musicManager.isShuffled { return "shuffle" }
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
        if musicManager.isShuffled { return .red }
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
    @AppStorage(AgentSourcePreferences.codexKey) private var codexAgentEnabled = true
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

            if codexAgentEnabled {
                CodexQuotaStrip()
                    .frame(width: 124)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
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
    @ObservedObject private var coordinator = BoringViewCoordinator.shared
    let tasks: [CodexPinnedTask]
    @Binding var selectedTaskID: String?
    let pageWidth: CGFloat
    let sortOrder: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 9) {
                    ForEach(tasks) { task in
                        taskTile(task).id(task.id)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 3)
            }
            .scrollIndicators(.hidden)
            .onAppear { scrollToReminder(proxy) }
            .onChange(of: coordinator.codexCompletionReminder) { _, _ in scrollToReminder(proxy) }
            .onChange(of: sortOrder) { _, _ in
                guard let firstTask = tasks.first else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(firstTask.id, anchor: .leading)
                }
            }
            }
        }
        .padding(.vertical, 8)
        .onChange(of: tasks) { _, updatedTasks in
            if let selectedTaskID, !updatedTasks.contains(where: { $0.id == selectedTaskID }) {
                self.selectedTaskID = nil
            }
        }
    }

    private func scrollToReminder(_ proxy: ScrollViewProxy) {
        if let task = tasks.first(where: {
            coordinator.codexHighlightedTaskIDs.contains($0.id)
                && coordinator.codexUnreadTaskIDs.contains($0.id)
        }) {
            let index = tasks.firstIndex(where: { $0.id == task.id }) ?? 0
            let anchor: UnitPoint = index == 0 ? .leading : (index == tasks.count - 1 ? .trailing : .center)
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(task.id, anchor: anchor) }
        }
    }

    private func taskTile(_ task: CodexPinnedTask) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.28)) {
                selectedTaskID = selectedTaskID == task.id ? nil : task.id
                if selectedTaskID == task.id { coordinator.markCodexTaskRead(task.id) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    AgentProviderIcon(source: task.source)
                    Text(task.providerName)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    Circle()
                        .fill(coordinator.codexUnreadTaskIDs.contains(task.id) ? Color.orange : (task.status == .running ? Color.blue : Color.white.opacity(0.36)))
                        .frame(width: 7, height: 7)
                }
                Text(task.title.isEmpty ? String(localized: "Untitled task") : task.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    Image(systemName: task.status == .running ? "waveform" : "terminal")
                        .font(.system(size: 10, weight: .semibold))
                    Text(coordinator.codexUnreadTaskIDs.contains(task.id) ? "未读" : task.status.displayTitle)
                        .font(.system(size: 10, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(coordinator.codexUnreadTaskIDs.contains(task.id) ? Color.orange : (task.status == .running ? Color.blue : Color.white.opacity(0.62)))
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(12)
            .frame(width: max(1, (pageWidth - 4 - 18) / 3), height: 108, alignment: .topLeading)
            .background(
                LinearGradient(colors: [Color.white.opacity(0.12), Color.white.opacity(0.045)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: agentCardCornerRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: agentCardCornerRadius)
                    .stroke(selectedTaskID == task.id ? Color.blue.opacity(0.8) : Color.white.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("Show task details")
        .modifier(AgentCardReminderHighlight(
            reminder: coordinator.codexCompletionReminder,
            enabled: coordinator.codexHighlightedTaskIDs.contains(task.id)
                && coordinator.codexUnreadTaskIDs.contains(task.id)))

    }
}

private struct AgentProviderIcon: View {
    let source: AgentTaskSource

    @ViewBuilder
    var body: some View {
        switch source {
        case .mimo:
            // Official Xiaomi Auto mark from its global website.
            Image("MiMoLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
        case .dsh:
            Image("DeepSeekFishMark")
                .resizable()
                .scaledToFit()
                .frame(width: 15, height: 12)
                .accessibilityHidden(true)
        default:
            Image(systemName: source.icon)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
        }
    }
}

private struct AgentCardReminderHighlight: ViewModifier {
    let reminder: UUID?
    let enabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: agentCardCornerRadius)
                .fill(Color.orange.opacity(bright ? 0.14 : 0))
                .overlay {
                    RoundedRectangle(cornerRadius: agentCardCornerRadius)
                        .stroke(Color.orange.opacity(bright ? 0.95 : 0), lineWidth: 2)
                }
                .allowsHitTesting(false)
        }
        .task(id: enabled ? reminder : nil) {
            bright = false
            guard enabled, reminder != nil else { return }
            do {
                if reduceMotion {
                    bright = true
                    try await Task.sleep(for: .seconds(4))
                } else {
                    for _ in 0..<4 {
                        withAnimation(.easeInOut(duration: 0.3)) { bright = true }
                        try await Task.sleep(for: .milliseconds(450))
                        withAnimation(.easeInOut(duration: 0.3)) { bright = false }
                        try await Task.sleep(for: .milliseconds(450))
                    }
                }
            } catch { }
            bright = false
        }
    }
}

// The notch itself cannot become key. A nonactivating child panel allows editing
// without changing focus behavior for music, shelf and other notch controls.
struct CodexTaskPanelAnchor: NSViewRepresentable {
    let isPresented: Bool
    let sideInset: CGFloat
    let onOutsideClick: () -> Void

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
        context.coordinator.sideInset = sideInset
        context.coordinator.onOutsideClick = onOutsideClick
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
        var sideInset: CGFloat = 0
        private var panel: DetailWindow?
        private var mouseMonitor: Any?
        private var globalMouseMonitor: Any?
        private var notchRect = NSRect.zero
        var onOutsideClick: (() -> Void)?

        private func handleOutsideClick() {
            guard let panel, panel.isVisible else { return }
            let point = NSEvent.mouseLocation
            guard !notchRect.contains(point), !panel.frame.contains(point) else { return }
            onOutsideClick?()
            dismiss()
        }

        func update(from anchor: NSView) {
            guard isPresented, let parent = anchor.window, anchor.bounds.width > 0 else {
                dismiss()
                return
            }
            let rect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            notchRect = rect.insetBy(dx: sideInset, dy: 0)
            let screen = parent.screen ?? NSScreen.main
            let bottom = screen?.visibleFrame.minY ?? 0
            let availableHeight = rect.minY - 8 - bottom
            guard availableHeight >= 180 else { dismiss(); return }
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
                    self?.handleOutsideClick()
                    return event
                }
                globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                    DispatchQueue.main.async { self?.handleOutsideClick() }
                }
            }
            // The notch's vertical sides are inset by its top corner radius.
            // Keep this editable conversation panel independently capturable.
            panel.sharingType = .readWrite
            let taskService = CodexPinnedTasksService.shared
            let messageCount = taskService.tasks.first { $0.id == taskService.selectedTaskID }.map { task in
                AgentMessageTimeline.merge(taskService.histories[task.id]?.messages ?? [], task.messages ?? []).count
            } ?? 0
            let preferredHeight = min(440, max(260, 180 + CGFloat(min(messageCount, 6)) * 46))
            let height = min(preferredHeight, availableHeight)
            panel.setFrame(NSRect(x: rect.minX + sideInset, y: rect.minY - 8 - height,
                                  width: max(1, rect.width - 2 * sideInset), height: height), display: true)
            if !panel.isVisible { panel.makeKeyAndOrderFront(nil) }
        }

        func dismiss() {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            mouseMonitor = nil
            if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
            globalMouseMonitor = nil
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
    @Default(.agentConversationFontSize) private var conversationFontSize
    private var fontIncrease: CGFloat { CGFloat(min(2, max(0, conversationFontSize)) * 2) }
    let task: CodexPinnedTask
    let close: () -> Void
    @ObservedObject private var service = CodexPinnedTasksService.shared
    @State private var isAtBottom = true
    @State private var isOpening = true
    private let bottomAnchor = "conversation-bottom"
    private var messages: [CodexTaskMessage] {
        AgentMessageTimeline.merge(service.histories[task.id]?.messages ?? [], task.messages ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(task.title.isEmpty ? String(localized: "Untitled task") : task.title)
                    .font(.system(size: 13 + fontIncrease, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("在 \(task.providerName) 中打开") {
                    guard let url = task.openURL else { return }
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10 + fontIncrease, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .disabled(task.openURL == nil)
                Text(task.status.displayTitle)
                    .font(.system(size: 10 + fontIncrease, weight: .medium))
                    .foregroundStyle(task.status == .running ? Color.blue : Color.white.opacity(0.62))
            }
            HStack {
                Text("最近对话").font(.system(size: 10 + fontIncrease, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("关闭会话详情")
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        if let history = service.histories[task.id], history.loading {
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                        } else if service.capabilities(for: task).history && (service.histories[task.id]?.loaded != true
                            || service.histories[task.id]?.cursor != nil) {
                            Button(service.histories[task.id]?.failed == true ? "加载失败，点击重试" : "加载更早对话") {
                                Task {
                                    let anchor = messages.first?.id
                                    await service.loadHistory(task.id)
                                    if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10 + fontIncrease))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .onAppear {
                                guard !isOpening, !isAtBottom,
                                      service.histories[task.id]?.loaded == true,
                                      service.histories[task.id]?.failed != true else { return }
                                Task {
                                    let anchor = messages.first?.id
                                    await service.loadHistory(task.id)
                                    if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                                }
                            }
                        }
                        if !messages.isEmpty {
                            ForEach(messages) { message in
                                messageRow(message)
                                    .id(message.id)
                            }
                        } else if !task.latestReply.isEmpty {
                            Text(task.latestReply)
                                .font(.system(size: 11 + fontIncrease))
                                .foregroundStyle(.white.opacity(0.82))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("暂无对话内容")
                                .font(.system(size: 11 + fontIncrease))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        Color.clear.frame(height: 1)
                            .id(bottomAnchor)
                            .onAppear { isAtBottom = true }
                            .onDisappear { isAtBottom = false }
                    }
                    .padding(.trailing, 4)
                }
                .defaultScrollAnchor(.top)
                .scrollIndicators(.hidden)
                .task {
                    if service.histories[task.id]?.loaded != true { await service.loadHistory(task.id) }
                    await Task.yield()
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                    isOpening = false
                }
                .onChange(of: task.messages?.last?.id) { _, lastID in
                    if isAtBottom, let lastID { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(lastID, anchor: .bottom) } }
                }
                .onChange(of: service.histories[task.id]?.messages.last) { _, lastMessage in
                    if isAtBottom, let lastMessage { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(lastMessage.id, anchor: .bottom) } }
                }
            }
            .frame(maxHeight: .infinity)
            if service.capabilities(for: task).composer == .workBuddyBridge {
                WorkBuddyTaskReplyComposer(task: task).id(task.id)
            } else if service.capabilities(for: task).send || service.capabilities(for: task).stop {
                CodexTaskReplyComposer(task: task)
            } else if let url = task.openURL {
                Button("在 \(task.providerName) 中继续对话") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 32))
        .overlay(RoundedRectangle(cornerRadius: 32).stroke(.white.opacity(0.10)))
        .preferredColorScheme(.dark)
    }

    private func messageText(_ source: String) -> Text {
        let attributed = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(source)
        return Text(attributed)
    }

    private func messageRow(_ message: CodexTaskMessage) -> some View {
        let isUser = message.role == .user
        return HStack {
            if isUser { Spacer(minLength: 34) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: isUser ? "person.fill" : "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 9 + fontIncrease, weight: .semibold))
                    Text(isUser ? "你" : (message.phase == "commentary" ? task.providerName + " · 实时进度" : task.providerName))
                        .font(.system(size: 9 + fontIncrease, weight: .semibold))
                }
                .foregroundStyle(isUser ? Color.white.opacity(0.52) : Color.blue.opacity(0.95))
                messageText(message.text)
                    .font(.system(size: 11 + fontIncrease))
                    .foregroundStyle(.white.opacity(0.88))
                    .tint(.cyan)
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        if url.isFileURL {
                            NSWorkspace.shared.open(url)
                        } else if url.scheme == nil, url.path.hasPrefix("/") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: url.path))
                        } else {
                            NSWorkspace.shared.open(url)
                        }
                        return .handled
                    })
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

private struct WorkBuddyTaskReplyComposer: View {
    @Default(.agentConversationFontSize) private var conversationFontSize
    private var fontIncrease: CGFloat { CGFloat(min(2, max(0, conversationFontSize)) * 2) }
    let task: CodexPinnedTask
    @State private var prompt = ""
    @State private var state = "checking"
    @State private var isSending = false
    @State private var isInstalling = false
    @State private var notice: String?
    @State private var deliveryUnknown = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state == "ready" {
                HStack(spacing: 8) {
                    TextField("告诉 WorkBuddy 接下来做什么…", text: $prompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13 + fontIncrease))
                        .lineLimit(2...6)
                        .focused($focused)
                        .disabled(isSending || deliveryUnknown)
                        .onKeyPress(.return, phases: .down) { key in
                            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                               editor.hasMarkedText() { return .ignored }
                            if key.modifiers.contains(.shift) { return .ignored }
                            send()
                            return .handled
                        }
                    Button(action: send) {
                        Group {
                            if isSending { ProgressView().controlSize(.small) }
                            else { Image(systemName: "arrow.up").font(.system(size: 17, weight: .semibold)) }
                        }.frame(width: 36, height: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Circle())
                    .help("发送到当前 WorkBuddy 会话")
                    .accessibilityLabel("发送到 WorkBuddy")
                    .disabled(isSending || deliveryUnknown || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(10)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            } else if state == "missing" {
                Button(isInstalling ? "正在安装…" : "安装 WorkBuddy 发送组件") {
                    isInstalling = true
                    Task {
                        let result = await XPCHelperClient.shared.installWorkBuddyBridge()
                        isInstalling = false
                        if result == "installed" {
                            state = "unavailable"
                            notice = "组件已安装，请重启 WorkBuddy 后点击重新连接。"
                        } else { notice = "安装失败，请确认 WorkBuddy 已安装且目录可写。" }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isInstalling)
            } else if state == "checking" {
                ProgressView().controlSize(.small)
            } else {
                Text("WorkBuddy 发送组件未连接")
                    .font(.system(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize + fontIncrease)).foregroundStyle(.secondary)
                Button("重新连接") { Task { await probe() } }
                    .buttonStyle(.bordered)
            }
            if let notice {
                Text(notice).font(.system(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize + fontIncrease)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if deliveryUnknown {
                Button("已在 WorkBuddy 核对，允许发送下一条") {
                    deliveryUnknown = false
                    prompt = ""
                    notice = nil
                }.font(.system(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize + fontIncrease)).buttonStyle(.bordered)
            }
        }
        .task(id: task.id) { await probe() }
    }

    private func probe() async {
        state = "checking"
        state = await XPCHelperClient.shared.probeWorkBuddyBridge(taskID: task.id)
        if state == "ready" { notice = nil }
    }

    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard state == "ready", !isSending, !deliveryUnknown, !text.isEmpty else { return }
        isSending = true
        notice = nil
        Task {
            let result = await CodexPinnedTasksService.shared.sendResult(task.id, prompt: text)
            isSending = false
            switch result {
            case .submitted, .queued:
                prompt = ""
                notice = result == .queued ? "已排队，WorkBuddy 会接续处理。" : nil
                await CodexPinnedTasksService.shared.refreshSelectedTask()
                focused = true
            case .unavailable:
                state = "unavailable"
                notice = "组件未连接，请重启 WorkBuddy 后重新连接。"
            case .notPinned:
                notice = "该会话已取消置顶，请先在 WorkBuddy 中重新置顶。"
            case .invalid:
                notice = "消息为空或过长，请缩短后再发送。"
            case .failure, .busy:
                notice = "WorkBuddy 未接收消息，请在应用中查看后再试。"
            default:
                deliveryUnknown = true
                notice = "发送结果未确认，请先在 WorkBuddy 核对，避免重复发送。"
            }
        }
    }
}

private struct CodexTaskReplyComposer: View {
    @Default(.agentConversationFontSize) private var conversationFontSize
    private var fontIncrease: CGFloat { CGFloat(min(2, max(0, conversationFontSize)) * 2) }
    let task: CodexPinnedTask
    @FocusState private var isPromptFocused: Bool
    @State private var prompt = ""
    @State private var isSending = false
    @State private var sendError: String?
    @State private var isStopping = false
    @State private var awaitingRun = false
    @AppStorage("mimoUnconfirmedSendIDs") private var unconfirmedSendIDs = "[]"
    private var pendingIDs: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: Data(unconfirmedSendIDs.utf8))) ?? [])
    }
    private var needsSendReview: Bool { task.source == .mimo && pendingIDs.contains(task.id) }
    private func setSendReview(_ pending: Bool) {
        var ids = pendingIDs
        if pending { ids.insert(task.id) } else { ids.remove(task.id) }
        if let data = try? JSONEncoder().encode(ids.sorted()), let text = String(data: data, encoding: .utf8) { unconfirmedSendIDs = text }
    }
    private var isRunning: Bool { task.status == .running || task.status == .waiting || awaitingRun }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                TextField("告诉 \(task.providerName) 接下来做什么…", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13 + fontIncrease))
                    .lineLimit(2...6)
                    .focused($isPromptFocused)
                    .disabled(isSending || needsSendReview)
                    .onKeyPress(.return, phases: .down) { key in
                        // Let the input method confirm marked Chinese text first.
                        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                           editor.hasMarkedText() { return .ignored }
                        if key.modifiers.contains(.shift) {
                            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                                editor.insertNewlineIgnoringFieldEditor(nil)
                            } else {
                                prompt.append("\n")
                            }
                        } else {
                            send()
                        }
                        return .handled
                    }
                Button(action: { if isRunning { stop() } else { send() } }) {
                    Group {
                        if isSending || isStopping { ProgressView().controlSize(.small) }
                        else { Image(systemName: isRunning ? "stop.fill" : "arrow.up").font(.system(size: 17, weight: .semibold)) }
                    }
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())
                .help(isRunning ? "中止当前会话" : "发送到当前会话")
                .accessibilityLabel(isRunning ? "中止" : "发送")
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isSending || isStopping || (!isRunning && needsSendReview) || (isRunning
                    ? !CodexPinnedTasksService.shared.capabilities(for: task).stop
                    : !CodexPinnedTasksService.shared.capabilities(for: task).send || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
            .padding(10)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.10)))
            if needsSendReview {
                Text("上次发送结果未确认，请先在 MiMo 中核对，避免重复发送。")
                    .font(.system(size: 10 + fontIncrease)).foregroundStyle(.secondary)
                Button("已在 MiMo 核对，允许发送下一条") { setSendReview(false); sendError = nil }
                    .buttonStyle(.plain).font(.system(size: 10 + fontIncrease)).foregroundStyle(.cyan)
            }
            if let sendError {
                Label {
                    Text(sendError)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                }
                .font(.system(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize + fontIncrease, weight: .medium))
                .foregroundStyle(.orange.opacity(0.9))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                .help(sendError)
            }
        }
        .onAppear { isPromptFocused = true }
        .onChange(of: task.status) { _, _ in awaitingRun = false }
        .onChange(of: CodexUnreadTracker.completionKey(task)) { _, _ in
            if task.status == .completed { awaitingRun = false }
        }
    }

    private func stop() {
        guard isRunning, CodexPinnedTasksService.shared.capabilities(for: task).stop, !isSending, !isStopping else { return }
        isStopping = true
        sendError = nil
        Task {
            let error = await CodexPinnedTasksService.shared.stop(task.id)
            isStopping = false
            if let error { sendError = error }
            else {
                awaitingRun = false
                await CodexPinnedTasksService.shared.refreshSelectedTask()
            }
        }
    }

    private func send() {
        let message = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CodexPinnedTasksService.shared.capabilities(for: task).send, !isSending, !isStopping, !isRunning, !needsSendReview, !message.isEmpty else { return }
        isSending = true
        sendError = nil
        Task {
            let result = await CodexPinnedTasksService.shared.sendResult(task.id, prompt: message)
            isSending = false
            if result == .unknown && task.source == .mimo { setSendReview(true) }
            if let error = result.errorMessage {
                sendError = error
            } else {
                awaitingRun = true
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
