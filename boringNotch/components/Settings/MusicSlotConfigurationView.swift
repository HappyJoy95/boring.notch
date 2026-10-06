import SwiftUI

/// Read-only preview of the fixed playback controls.
struct MusicSlotConfigurationView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("布局预览")
                .font(.headline)
            HStack(spacing: 24) {
                ForEach(MusicControlButton.defaultLayout) { control in
                    Image(systemName: control.iconName)
                        .font(.system(size: control.prefersLargeScale ? 20 : 17, weight: .medium))
                        .frame(width: 32, height: 44)
                        .accessibilityLabel(control.label)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            Text("固定显示收藏、上一首、播放／暂停、下一首和循环模式。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
