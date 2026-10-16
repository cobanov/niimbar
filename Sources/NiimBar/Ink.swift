import SwiftUI

// Design tokens and small controls, from GHBar (PanelView.swift) so the two apps look alike.

enum Ink {
    /// GHBar's graphite and green.
    static let panel = Color(red: 0.090, green: 0.098, blue: 0.118)
    static let raised = Color.white.opacity(0.055)
    static let hairline = Color.white.opacity(0.07)
    static let primary = Color(red: 0.925, green: 0.933, blue: 0.945)
    static let secondary = Color(red: 0.569, green: 0.596, blue: 0.631)
    /// 5.3:1 on the panel, 4.6:1 on a hovered row: WCAG AA for small text.
    static let tertiary = Color(red: 0.530, green: 0.550, blue: 0.590)
    static let green = Color(red: 0.200, green: 0.761, blue: 0.369)
    static let warning = Color(red: 0.95, green: 0.66, blue: 0.27)

    static let name = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
    static let meta = Font.system(size: 11.5)
    static let tab = Font.system(size: 12.5)
    static let tabActive = Font.system(size: 12.5, weight: .semibold)
}

struct IconButton: View {
    let symbol: String
    let help: String
    var spinning = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            // Driven by the clock rather than a repeating animation, which keeps running
            // (or winds backwards) after `spinning` turns false.
            TimelineView(.animation(paused: !spinning)) { context in
                Image(systemName: symbol)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(hover ? Ink.primary : Ink.secondary)
                    .rotationEffect(.degrees(spinning ? Self.angle(at: context.date) : 0))
            }
            .frame(width: 28, height: 28)
            .background(Circle().fill(hover ? Ink.raised : .clear))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }

    /// One turn every 0.9 seconds.
    private static func angle(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360
    }
}

struct QuietButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Ink.meta.weight(.medium))
            .foregroundStyle(prominent ? Color.black : Ink.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(prominent ? Ink.green : Ink.raised))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
