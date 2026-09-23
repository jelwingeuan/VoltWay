import SwiftUI

extension Color {
    static let voltBlue = Color(red: 0.10, green: 0.34, blue: 0.95)
    static let voltMint = Color(red: 0.18, green: 0.78, blue: 0.59)
    static let voltInk = Color(red: 0.04, green: 0.08, blue: 0.16)
    static let voltBackground = Color(uiColor: .systemGroupedBackground)
    static let voltSurface = Color(uiColor: .secondarySystemGroupedBackground)
}

struct VoltSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .background(Color.voltSurface)
            .clipShape(.rect(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            }
    }
}

struct VoltPrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 18)
            .background(Color.voltBlue.opacity(configuration.isPressed ? 0.82 : 1))
            .clipShape(.rect(cornerRadius: 16))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct VoltGlassButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 46)
            .padding(.horizontal, 15)
            .voltGlassControl(isPressed: configuration.isPressed)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private extension View {
    @ViewBuilder
    func voltGlassControl(isPressed: Bool) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.tint(Color.voltBlue.opacity(0.15)).interactive(), in: .capsule)
        } else {
            background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay { Capsule().stroke(Color.primary.opacity(isPressed ? 0.16 : 0.09), lineWidth: 1) }
        }
    }
}

struct AvailabilityPill: View {
    let availability: Availability

    private var tint: Color {
        if availability.isStale() { return .secondary }
        return switch availability.state {
        case .available: .voltMint
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
                .foregroundStyle(isError ? Color.orange : Color.voltMint)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(14)
        .background(.thinMaterial, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }
}
