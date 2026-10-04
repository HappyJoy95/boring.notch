//
//  ContentView.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Richard Kunkli on 24/08/2024.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import SwiftUI
import SwiftUIIntrospect

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var webcamManager = WebcamManager.shared

    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject private var pinnedTaskService = CodexPinnedTasksService.shared
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var brightnessManager = BrightnessManager.shared
    @ObservedObject var volumeManager = VolumeManager.shared
    @State private var hoverTask: Task<Void, Never>?
    @State private var isHovering: Bool = false
    @State private var anyDropDebounceTask: Task<Void, Never>?

    @State private var gestureProgress: CGFloat = .zero

    @State private var haptics: Bool = false

    @Namespace var albumArtNamespace

    @Default(.useMusicVisualizer) var useMusicVisualizer
    @Default(.showCollapsedLyrics) private var showCollapsedLyrics

    @Default(.showNotHumanFace) var showNotHumanFace

    // Shared interactive spring for movement/resizing to avoid conflicting animations
    private let animationSpring = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    private let extendedHoverPadding: CGFloat = 30
    private let zeroHeightHoverPadding: CGFloat = 10
    // Caption row (26 pt) plus the header's 8 pt spacing.
    private let collapsedMusicCaptionHeight: CGFloat = 34

    private var topCornerRadius: CGFloat {
       ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.top
                : cornerRadiusInsets.closed.top
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: vm.notchState == .open && coordinator.currentView == .agent
                ? agentOuterCornerRadius
                : ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                    ? cornerRadiusInsets.opened.bottom : cornerRadiusInsets.closed.bottom
        )
    }

    private var computedChinWidth: CGFloat {
        var chinWidth: CGFloat = vm.closedNotchSize.width

        if coordinator.codexStatusEvent != nil && vm.notchState == .closed && !vm.hideOnClosed {
            chinWidth = min(420, vm.closedNotchSize.width + 180)
        } else if coordinator.expandingView.type == .battery && coordinator.expandingView.show
            && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
        {
            chinWidth = 640
        } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        } else if !coordinator.expandingView.show && vm.notchState == .closed
            && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace]
            && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        }

        return chinWidth
    }

    var body: some View {
        // Calculate scale based on gesture progress only
        let gestureScale: CGFloat = {
            guard gestureProgress != 0 else { return 1.0 }
            let scaleFactor = 1.0 + gestureProgress * 0.01
            return max(0.6, scaleFactor)
        }()
        
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                let mainLayout = NotchLayout()
                    .frame(alignment: .top)
                    .padding(
                        .horizontal,
                        vm.notchState == .open
                        ? Defaults[.cornerRadiusScaling]
                        ? (cornerRadiusInsets.opened.top) : (cornerRadiusInsets.opened.bottom)
                        : cornerRadiusInsets.closed.bottom
                    )
                    .padding(.horizontal, vm.notchState == .open ? 12 : 0)
                    .padding(.bottom, vm.notchState == .open ? (coordinator.currentView == .agent ? 6 : 12) : 0)
                    .background(alignment: .top) {
                        GeometryReader { geometry in
                            // Keep one opaque surface while playback expands or collapses.
                            currentNotchShape
                                .fill(.black)
                                .frame(
                                    width: geometry.size.width,
                                    height: geometry.size.height + (shouldShowCollapsedLyrics ? chinContentHeight : 0),
                                    alignment: .top
                                )
                        }
                    }
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .conditionalModifier(vm.notchState == .open) { view in
                        view.clipShape(currentNotchShape)
                    }
                    .padding(
                        .bottom,
                        vm.effectiveClosedNotchHeight == 0 ? 10 : 0
                    )
                
                mainLayout
                    .frame(height: vm.notchState == .open ? vm.notchSize.height : nil, alignment: .top)
                    .background {
                        CodexTaskPanelAnchor(isPresented:
                            vm.notchState == .open && coordinator.currentView == .agent
                                && pinnedTaskService.selectedTaskID != nil,
                            sideInset: topCornerRadius,
                            onOutsideClick: {
                                pinnedTaskService.selectedTaskID = nil
                                vm.close()
                                coordinator.currentView = .home
                                coordinator.openHomeAfterOutsideDismiss = true
                            })
                    }
                    .conditionalModifier(true) { view in
                        return view
                            .animation(.smooth, value: gestureProgress)
                    }
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .conditionalModifier(vm.notchState == .closed) { view in
                        view.onTapGesture { doOpen() }
                    }
                    .conditionalModifier(Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .down) { translation, phase in
                                handleDownGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(Defaults[.closeGestureEnabled] && Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .up) { translation, phase in
                                handleUpGesture(translation: translation, phase: phase)
                            }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .sharingDidFinish)) { _ in
                        if vm.notchState == .open && !isHovering && !vm.isBatteryPopoverActive {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if self.vm.notchState == .open && !self.isHovering && !self.vm.isBatteryPopoverActive && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: vm.notchState) { _, newState in
                        if newState == .closed && isHovering {
                            withAnimation {
                                isHovering = false
                            }
                        }
                    }
                    .onChange(of: coordinator.codexPinnedTasks) { _, tasks in
                        guard vm.notchState == .open else { return }
                        withAnimation(.smooth) {
                            if coordinator.currentView == .agent {
                                vm.notchSize = compactCodexNotchSize
                            } else {
                                vm.notchSize = expandedNotchSize(for: coordinator.currentView, hasPinnedTasks: !tasks.isEmpty)
                            }
                        }
                    }
                    .onChange(of: coordinator.codexCompletionReminder) { _, reminder in
                        guard reminder != nil, coordinator.codexTabEnabled,
                              !vm.hideOnClosed else { return }
                        hoverTask?.cancel()
                        coordinator.openHomeAfterOutsideDismiss = false
                        coordinator.currentView = .agent
                        doOpen()
                        // Keep the reminder visible long enough to read the cards.
                        hoverTask = Task {
                            try? await Task.sleep(for: .seconds(8))
                            guard !Task.isCancelled,
                                  coordinator.codexCompletionReminder == reminder,
                                  coordinator.currentView == .agent,
                                  pinnedTaskService.selectedTaskID == nil,
                                  !vm.isMouseHovering(), !SharingStateManager.shared.preventNotchClose else { return }
                            vm.close()
                        }
                    }
                    .onChange(of: coordinator.currentView) { _, newView in
                        guard vm.notchState == .open else { return }
                        withAnimation(.smooth) {
                            if newView == .agent {
                                vm.notchSize = compactCodexNotchSize
                            } else {
                                vm.notchSize = expandedNotchSize(for: newView, hasPinnedTasks: !coordinator.codexPinnedTasks.isEmpty)
                            }
                        }
                    }
                    .onChange(of: pinnedTaskService.tasks) { _, tasks in
                        guard vm.notchState == .open, coordinator.currentView == .agent else { return }
                        withAnimation(.smooth) {
                            vm.notchSize = tasks.isEmpty
                                ? expandedNotchSize(for: .agent, hasPinnedTasks: false)
                                : compactCodexNotchSize
                        }
                    }
                    .onChange(of: pinnedTaskService.selectedTaskID) { _, selectedID in
                        guard selectedID == nil,
                              vm.notchState == .open,
                              coordinator.currentView == .agent,
                              !vm.isMouseHovering() else { return }
                        hoverTask?.cancel()
                        hoverTask = Task {
                            try? await Task.sleep(for: .milliseconds(220))
                            guard !Task.isCancelled else { return }
                            await MainActor.run {
                                guard pinnedTaskService.selectedTaskID == nil,
                                      self.vm.notchState == .open,
                                      self.coordinator.currentView == .agent,
                                      !self.vm.isMouseHovering(),
                                      !SharingStateManager.shared.preventNotchClose else { return }
                                self.vm.close()
                            }
                        }
                    }
                    .onChange(of: vm.isBatteryPopoverActive) {
                        if !vm.isBatteryPopoverActive && !isHovering && vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if !self.vm.isBatteryPopoverActive && !self.isHovering && self.vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .sensoryFeedback(.alignment, trigger: haptics)
                    .contextMenu {
                        Button("Settings") {
                            DispatchQueue.main.async {
                                SettingsWindowController.shared.showWindow()
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
                        //                    Button("Edit") { // Doesnt work....
                        //                        let dn = DynamicNotch(content: EditPanelView())
                        //                        dn.toggle()
                        //                    }
                        //                    .keyboardShortcut("E", modifiers: .command)
                    }
                // Keep the row mounted so its height contracts instead of fading out.
                Rectangle()
                        .fill(shouldShowCollapsedLyrics ? Color.clear : Color.black.opacity(0.01))
                        .overlay {
                            if shouldShowCollapsedLyrics {
                                CollapsedLyricsView()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .transition(.identity)
                            }
                        }
                        .frame(width: chinContentWidth, height: chinContentHeight)
                        .conditionalModifier(!shouldShowCollapsedLyrics) { view in
                            view.clipShape(
                                UnevenRoundedRectangle(
                                    cornerRadii: RectangleCornerRadii(
                                        topLeading: 0,
                                        bottomLeading: 14,
                                        bottomTrailing: 14,
                                        topTrailing: 0
                                    ),
                                    style: .continuous
                                )
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .clipped()
            }
            .shadow(
                color: ((vm.notchState == .open || isHovering) && Defaults[.enableShadow])
                    ? .black.opacity(0.7) : .clear,
                radius: Defaults[.cornerRadiusScaling] ? 6 : 4
            )
            .animation(
                vm.notchState == .open
                    ? Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
                    : Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0),
                value: vm.notchState
            )
            .animation(.smooth, value: musicManager.isPlayerIdle)
            .animation(.smooth, value: shouldShowCollapsedLyrics)
            .animation(.smooth, value: coordinator.sneakPeek.show)
        }
        .padding(.bottom, 8)
        .frame(maxWidth: windowSize.width, maxHeight: windowSize.height, alignment: .top)
        .compositingGroup()
        .scaleEffect(
            x: gestureScale,
            y: gestureScale,
            anchor: .top
        )
        .animation(.smooth, value: gestureProgress)
        .background(dragDetector)
        .preferredColorScheme(.dark)
        .environmentObject(vm)
        .onChange(of: vm.anyDropZoneTargeting) { _, isTargeted in
            anyDropDebounceTask?.cancel()

            if isTargeted {
                if vm.notchState == .closed {
                    coordinator.currentView = .shelf
                    doOpen()
                }
                return
            }

            anyDropDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }

                if vm.dropEvent {
                    vm.dropEvent = false
                    return
                }

                vm.dropEvent = false
                if !SharingStateManager.shared.preventNotchClose {
                    vm.close()
                }
            }
        }
    }

    private var shouldShowCollapsedLyrics: Bool {
        guard showCollapsedLyrics,
              Defaults[.enableLyrics],
              musicManager.hasAvailableLyrics,
              vm.notchState == .closed,
              !vm.hideOnClosed,
              coordinator.musicLiveActivityEnabled,
              musicManager.isPlaying || !musicManager.isPlayerIdle,
              coordinator.codexStatusEvent == nil,
              !(coordinator.expandingView.show && coordinator.expandingView.type != .music),
              !coordinator.sneakPeek.show
        else { return false }
        return true
    }

    private var chinContentHeight: CGFloat {
        max(vm.chinHeight, shouldShowCollapsedLyrics ? collapsedMusicCaptionHeight : 0)
    }

    private var chinContentWidth: CGFloat {
        shouldShowCollapsedLyrics
            ? collapsedPlaybackWidth - 2 * cornerRadiusInsets.closed.top
            : computedChinWidth
    }

    private var musicCenterWidth: CGFloat {
        (coordinator.expandingView.show
            && coordinator.expandingView.type == .music
            && Defaults[.sneakPeekStyles] == .inline)
            ? 380 : vm.closedNotchSize.width - cornerRadiusInsets.closed.top
    }

    private var collapsedPlaybackWidth: CGFloat {
        // Match the playback row, including its two gaps and outer padding.
        musicCenterWidth + 2 * max(0, vm.effectiveClosedNotchHeight - 12)
            + 16 + 2 * cornerRadiusInsets.closed.bottom
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 8) {
                if coordinator.helloAnimationRunning {
                    Spacer()
                    HelloAnimation(onFinish: {
                        vm.closeHello()
                    }).frame(
                        width: getClosedNotchSize().width,
                        height: 80
                    )
                    .padding(.top, 40)
                    Spacer()
                } else {
                    if coordinator.expandingView.type == .battery && coordinator.expandingView.show
                        && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
                    {
                        HStack(spacing: 0) {
                            HStack {
                                Text(batteryModel.statusText)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                            }

                            Rectangle()
                                .fill(.black)
                                .frame(width: vm.closedNotchSize.width + 10)

                            HStack {
                                BoringBatteryView(
                                    batteryWidth: 30,
                                    isCharging: batteryModel.isCharging,
                                    isInLowPowerMode: batteryModel.isInLowPowerMode,
                                    isPluggedIn: batteryModel.isPluggedIn,
                                    levelBattery: batteryModel.levelBattery,
                                    isForNotification: true
                                )
                            }
                            .frame(width: 76, alignment: .trailing)
                        }
                        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
                      } else if let codexEvent = coordinator.codexStatusEvent, vm.notchState == .closed, !vm.hideOnClosed {
                          CodexStatusActivityView(event: codexEvent)
                              .frame(width: min(420, vm.closedNotchSize.width + 180), height: vm.effectiveClosedNotchHeight)
                              .transition(.opacity.combined(with: .move(edge: .top)))
                      } else if coordinator.sneakPeek.show && Defaults[.inlineHUD] && (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && vm.notchState == .closed {
                          InlineHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon, hoverAnimation: $isHovering, gestureProgress: $gestureProgress)
                              .transition(.opacity)
                      } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music) && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle) && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed {
                          MusicLiveActivity()
                              .frame(alignment: .center)
                              .transition(.identity)
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace] && !vm.hideOnClosed  {
                          BoringFaceAnimation()
                       } else if vm.notchState == .open {
                           BoringHeader()
                               .frame(height: max(24, vm.effectiveClosedNotchHeight))
                               .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
                       } else {
                           Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
                               .transition(.identity)
                       }

                      if coordinator.sneakPeek.show {
                          if (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && !Defaults[.inlineHUD] && vm.notchState == .closed {
                              SystemEventIndicatorModifier(
                                  eventType: $coordinator.sneakPeek.type,
                                  value: $coordinator.sneakPeek.value,
                                  icon: $coordinator.sneakPeek.icon,
                                  sendEventBack: { newVal in
                                      switch coordinator.sneakPeek.type {
                                      case .volume:
                                          VolumeManager.shared.setAbsolute(Float32(newVal))
                                      case .brightness:
                                          BrightnessManager.shared.setAbsolute(value: Float32(newVal))
                                      default:
                                          break
                                      }
                                  }
                              )
                              .padding(.bottom, 10)
                              .padding(.leading, 4)
                              .padding(.trailing, 8)
                          }
                          // Old sneak peek music
                          else if coordinator.sneakPeek.type == .music {
                              if vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard {
                                  HStack(alignment: .center) {
                                      Image(systemName: "music.note")
                                      GeometryReader { geo in
                                          MarqueeText(.constant(musicManager.songTitle + " - " + musicManager.artistName),  textColor: Defaults[.playerColorTinting] ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray, minDuration: 1, frameWidth: geo.size.width)
                                      }
                                  }
                                  .foregroundStyle(.gray)
                                  .frame(height: collapsedMusicCaptionHeight - 8)
                              }
                          }
                      }
                  }
              }
              .conditionalModifier((coordinator.sneakPeek.show && (coordinator.sneakPeek.type == .music) && vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard) || (coordinator.sneakPeek.show && (coordinator.sneakPeek.type != .music) && (vm.notchState == .closed))) { view in
                  view
                      .fixedSize()
              }
              .zIndex(2)
            if vm.notchState == .open {
                VStack {
                    switch coordinator.currentView {
                    case .home:
                        NotchHomeView(albumArtNamespace: albumArtNamespace)
                    case .shelf:
                        ShelfView()
                    case .agent:
                        AgentTasksView()
                    }
                }
                .transition(
                    .scale(scale: 0.8, anchor: .top)
                    .combined(with: .opacity)
                    .animation(.smooth(duration: 0.35))
                )
                .zIndex(1)
                .allowsHitTesting(vm.notchState == .open)
                .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
            }
        }
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], delegate: GeneralDropTargetDelegate(isTargeted: $vm.generalDropTargeting))
    }

    @ViewBuilder
    func BoringFaceAnimation() -> some View {
        HStack {
            HStack {
                Rectangle()
                    .fill(.clear)
                    .frame(
                        width: max(0, vm.effectiveClosedNotchHeight - 12),
                        height: max(0, vm.effectiveClosedNotchHeight - 12)
                    )
                Rectangle()
                    .fill(.black)
                    .frame(width: vm.closedNotchSize.width - 20)
                MinimalFaceFeatures()
            }
        }.frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    func MusicLiveActivity() -> some View {
        HStack(spacing: 8) {
            Image(nsImage: musicManager.albumArt)
                .resizable()
                .clipped()
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed)
                )
                .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                .frame(
                    width: max(0, vm.effectiveClosedNotchHeight - 12),
                    height: max(0, vm.effectiveClosedNotchHeight - 12)
                )

            Rectangle()
                .fill(.black)
                .overlay(
                    HStack(alignment: .top) {
                        if coordinator.expandingView.show
                            && coordinator.expandingView.type == .music
                        {
                            MarqueeText(
                                .constant(musicManager.songTitle),
                                textColor: Defaults[.coloredSpectrogram]
                                    ? Color(nsColor: musicManager.avgColor) : Color.gray,
                                minDuration: 0.4,
                                frameWidth: 100
                            )
                            .opacity(
                                (coordinator.expandingView.show
                                    && Defaults[.sneakPeekStyles] == .inline)
                                    ? 1 : 0
                            )
                            Spacer(minLength: vm.closedNotchSize.width)
                            // Song Artist
                            Text(musicManager.artistName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(
                                    Defaults[.coloredSpectrogram]
                                        ? Color(nsColor: musicManager.avgColor)
                                        : Color.gray
                                )
                                .opacity(
                                    (coordinator.expandingView.show
                                        && coordinator.expandingView.type == .music
                                        && Defaults[.sneakPeekStyles] == .inline)
                                        ? 1 : 0
                                )
                        }
                    }
                )
                .frame(
                    width: musicCenterWidth
                )

            HStack {
                if useMusicVisualizer {
                    Rectangle()
                        .fill(
                            Defaults[.coloredSpectrogram]
                                ? Color(nsColor: musicManager.avgColor).gradient
                                : Color.gray.gradient
                        )
                        .frame(width: 50, alignment: .center)
                        .matchedGeometryEffect(id: "spectrum", in: albumArtNamespace)
                        .mask {
                            AudioSpectrumView(isPlaying: $musicManager.isPlaying)
                                .frame(width: 16, height: 12)
                        }
                } else {
                    LottieAnimationContainer()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(
                width: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                        + gestureProgress / 2
                ),
                height: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                ),
                alignment: .center
            )
        }
        .frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    var dragDetector: some View {
        if Defaults[.boringShelf] && vm.notchState == .closed {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
            vm.dropEvent = true
            ShelfStateViewModel.shared.load(providers)
            return true
        }
        } else {
            EmptyView()
        }
    }

    private func doOpen() {
        withAnimation(animationSpring) {
            vm.open()
        }
    }

    // MARK: - Hover Management

    private func handleHover(_ hovering: Bool) {
        if coordinator.firstLaunch { return }
        hoverTask?.cancel()
        
        if hovering {
            withAnimation(animationSpring) {
                isHovering = true
            }
            
            if vm.notchState == .closed && Defaults[.enableHaptics] {
                haptics.toggle()
            }
            
            guard vm.notchState == .closed,
                  !coordinator.sneakPeek.show,
                  Defaults[.openNotchOnHover] else { return }
            
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.minimumHoverDuration]))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    guard self.vm.notchState == .closed,
                          self.isHovering,
                          !self.coordinator.sneakPeek.show else { return }
                    
                    self.doOpen()
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(240))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    if self.vm.isMouseHovering()
                        || (self.coordinator.currentView == .agent && CodexPinnedTasksService.shared.selectedTaskID != nil) {
                        self.isHovering = true
                        return
                    }
                    withAnimation(animationSpring) {
                        self.isHovering = false
                    }
                    
                    if self.vm.notchState == .open && !self.vm.isBatteryPopoverActive && !SharingStateManager.shared.preventNotchClose {
                        self.vm.close()
                    }
                }
            }
        }
    }

    // MARK: - Gesture Handling

    private func handleDownGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .closed else { return }

        if phase == .ended {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * 20
        }

        if translation > Defaults[.gestureSensitivity] {
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
            doOpen()
        }
    }

    private func handleUpGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .open && !vm.isHoveringCalendar else { return }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * -20
        }

        if phase == .ended {
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
        }

        if translation > Defaults[.gestureSensitivity] {
            if coordinator.currentView == .agent,
               CodexPinnedTasksService.shared.selectedTaskID != nil {
                CodexPinnedTasksService.shared.selectedTaskID = nil
                withAnimation(animationSpring) { gestureProgress = .zero }
                if Defaults[.enableHaptics] { haptics.toggle() }
                return
            }
            withAnimation(animationSpring) {
                isHovering = false
            }
            if !SharingStateManager.shared.preventNotchClose { 
                gestureProgress = .zero
                vm.close()
            }

            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }
}

struct FullScreenDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: () -> Void

    func dropEntered(info _: DropInfo) {
        isTargeted = true
    }

    func dropExited(info _: DropInfo) {
        isTargeted = false
    }

    func performDrop(info _: DropInfo) -> Bool {
        isTargeted = false
        onDrop()
        return true
    }

}

struct GeneralDropTargetDelegate: DropDelegate {
    @Binding var isTargeted: Bool

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        return false
    }
}

private struct CollapsedLyricsView: View {
    @ObservedObject private var musicManager = MusicManager.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25)) { timeline in
            let elapsed: Double = {
                guard musicManager.isPlaying else { return musicManager.elapsedTime }
                let delta = timeline.date.timeIntervalSince(musicManager.timestampDate)
                return min(max(musicManager.elapsedTime + delta * musicManager.playbackRate, 0), musicManager.songDuration)
            }()
            let hasSyncedLyrics = !musicManager.syncedLyrics.isEmpty
            let line: String = {
                if hasSyncedLyrics { return musicManager.lyricLine(at: elapsed) }
                return musicManager.currentLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
            }()
            Text(line)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(musicManager.lyricsColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel("Current lyrics")
    }
}

#Preview {
    let vm = BoringViewModel()
    vm.open()
    return ContentView()
        .environmentObject(vm)
        .frame(width: vm.notchSize.width, height: vm.notchSize.height)
}
