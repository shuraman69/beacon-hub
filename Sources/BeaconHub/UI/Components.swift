import AppKit
import SwiftUI

/// Карточка-секция панели: заголовок с иконкой и содержимое.
struct SectionCard<Trailing: View, Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                trailing()
            }
            content()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
    }
}

/// Строка-кнопка с подсветкой при наведении.
struct HoverRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        .onHover { hovering = $0 }
    }
}

struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color)
                    .frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

struct Badge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

struct ErrorLine: View {
    let text: String

    var body: some View {
        Label {
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

enum PipelineStyle {
    static func symbol(_ status: String) -> String {
        switch status {
        case "success": return "checkmark.circle.fill"
        case "failed": return "xmark.circle.fill"
        case "running": return "arrow.triangle.2.circlepath.circle.fill"
        case "pending", "created", "waiting_for_resource", "preparing": return "clock.fill"
        case "canceled": return "slash.circle.fill"
        case "skipped": return "forward.circle.fill"
        case "manual": return "hand.raised.circle.fill"
        case "scheduled": return "calendar.circle.fill"
        default: return "questionmark.circle.fill"
        }
    }

    static func color(_ status: String) -> Color {
        switch status {
        case "success": return .green
        case "failed": return .red
        case "running": return .blue
        case "pending", "created", "waiting_for_resource", "preparing": return .orange
        case "manual": return .purple
        default: return .gray
        }
    }
}

func openURL(_ string: String) {
    if let url = URL(string: string) { NSWorkspace.shared.open(url) }
}
