import SwiftUI

struct CodexQuotaStrip: View {
    @ObservedObject private var service = CodexQuotaService.shared

    var body: some View {
        VStack(alignment: .center, spacing: 5) {
            QuotaCircle(title: "5 hr", window: service.snapshot?.primary, tint: .green, isRefreshing: service.isRefreshing)
            QuotaCircle(title: "7 day", window: service.snapshot?.secondary, tint: .blue, isRefreshing: service.isRefreshing)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
        .task {
            await service.refresh()
        }
    }
}

private struct QuotaCircle: View {
    let title: String
    let window: CodexQuotaWindow?
    let tint: Color
    let isRefreshing: Bool

    private var progress: Double {
        Double(window?.remainingPercent ?? 0) / 100
    }

    var body: some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))

            ZStack {
                Circle()
                    .stroke(.white.opacity(0.12), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if let window {
                    Text("\(window.remainingPercent)%")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.94))
                        .minimumScaleFactor(0.8)
                } else if isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white.opacity(0.72))
                } else {
                    Text("—")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(width: 38, height: 38)

            Text(window.map { resetDateText($0.resetsAt) } ?? "—")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func resetDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}
