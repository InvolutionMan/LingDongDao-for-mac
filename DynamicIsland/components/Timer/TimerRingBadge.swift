import AppKit
import SwiftUI

/// A running timer, shrunk to a ring: the same trick the media circle plays with
/// album art, so a timer can sit in the closed island's trailing corner while a
/// CLI task keeps the main slot. No digits — at this size they would be
/// illegible; the name and the countdown are in the tooltip and in the timer
/// page that the ring's side of the island opens.
///
/// (`TimerProgressRing` in `NotchTimerView` is the 110pt one with the big
/// countdown, private to the timer page.)
struct TimerRingBadge: View {
    /// 0…1 while counting down, above 1 while overtime (the ring then stays full).
    let progress: Double
    let color: Color
    let diameter: CGFloat
    /// The countdown, drawn beside the ring — at 22pt there is no room for
    /// digits inside it, and the iPhone's timer shows them plainly too.
    var label: String? = nil
    var strokeWidth: CGFloat = 2.5

    private var clampedProgress: CGFloat { CGFloat(min(max(progress, 0), 1)) }

    var body: some View {
        // Side by side, horizontally: the digits are readable only if they sit
        // clear of the ring, never on top of it.
        HStack(spacing: label == nil ? 0 : Self.labelGap) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: strokeWidth)
                Circle()
                    .trim(from: 0, to: clampedProgress)
                    .stroke(color, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: diameter, height: diameter)
            .animation(.smooth(duration: 0.3), value: clampedProgress)

            if let label {
                Text(label)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.25), value: label)
            }
        }
    }

    /// Gap between the ring and its countdown.
    static let labelGap: CGFloat = 6

    /// Total width the ring plus its countdown occupies.
    static func width(diameter: CGFloat, label: String?) -> CGFloat {
        let text = labelWidth(label)
        return text > 0 ? diameter + labelGap + text : diameter
    }

    /// Measured width of a label, so callers can reserve it exactly.
    static func labelWidth(_ text: String?) -> CGFloat {
        guard let text, !text.isEmpty else { return 0 }
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        let width = NSAttributedString(string: text, attributes: [.font: font]).size().width
        return CGFloat(ceil(width))
    }
}
