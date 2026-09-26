import SwiftUI

extension Color {
    static let voltBlue = Color(red: 0.10, green: 0.34, blue: 0.95)
    static let voltMint = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.29, green: 0.85, blue: 0.66, alpha: 1)
            : UIColor(red: 0.04, green: 0.43, blue: 0.32, alpha: 1)
    })
    static let voltBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.055, green: 0.09, blue: 0.15, alpha: 1)
            : UIColor(red: 0.95, green: 0.97, blue: 0.99, alpha: 1)
    })
    static let voltSurface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.10, green: 0.15, blue: 0.23, alpha: 1)
            : UIColor.white
    })
}

struct VoltSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .background(Color.voltSurface, in: .rect(cornerRadius: 18))
    }
}

struct DemoNotice: View {
    var body: some View {
        Label("Demo data, not live", systemImage: "info.circle")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

struct AvailabilityPill: View {
    let availability: Availability

    private var tint: Color {
        if availability.isStale() { return .secondary }
        return switch availability.state {
        case .available: availability.isReportedAvailable() ? .voltMint : .secondary
        case .occupied: .orange
        case .offline: .red
        case .unknown: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(availability.displayText())
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.11), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct MessageBanner: View {
    let message: String
    let isError: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.orange : Color.voltBlue)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(14)
        .background(Color.voltSurface, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }
}
