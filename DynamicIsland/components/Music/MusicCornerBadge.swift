import AppKit
import SwiftUI

/// The media, shrunk into the closed island's trailing corner: a hairline
/// divider, then the album art turning slowly in a circle — the running task
/// keeps the main slot, exactly like the iPhone's Dynamic Island puts a call on
/// the left and the playing track on the right.
///
/// The badge owns its own spacing (the gap before the divider and after it), so
/// callers only reserve `MusicCornerBadge.width(...)` and append the view.
/// What the badge shows in its circle. Media draws the album art, a running
/// timer draws its progress ring — both keep the same hairline divider, the same
/// gaps and the same reserved width.
enum IslandCornerBadgeContent {
    case artwork(NSImage)
    case timer(progress: Double, color: Color, label: String?)
}

/// Which divider slot the badge reports its position into, so a hover can tell
/// the task's half from the media half from the timer's.
enum IslandCornerBadgeSlot {
    case media
    case timer
}

struct MusicCornerBadge: View {
    let content: IslandCornerBadgeContent
    /// Diameter of the circle; the caller sizes it to the pill height.
    let diameter: CGFloat
    var slot: IslandCornerBadgeSlot = .media
    /// Space in front of the divider. Callers that already leave a trailing gap
    /// (the stacked rows) pass 0.
    var leadingGap: CGFloat = 8
    var dividerGap: CGFloat = 8
    /// True while the pointer rests on the island (or the track is paused): the
    /// record stops under the finger and picks up again where it left off.
    var isPaused: Bool = false

    /// One turn every eight seconds: fast enough to read as spinning, slow
    /// enough not to pull the eye away from the task.
    static let secondsPerTurn: Double = 8
    /// The artwork is drawn larger than the circle so the rotating square never
    /// uncovers the rim — its diagonal has to cover the disc (√2 ≈ 1.415).
    static let spinOverflow: CGFloat = 1.45

    /// Total width the badge adds to a pill. `labelWidth` is the countdown a
    /// timer badge draws beside its ring (0 for media, which is art only).
    static func width(
        diameter: CGFloat,
        leadingGap: CGFloat = 8,
        dividerGap: CGFloat = 8,
        labelWidth: CGFloat = 0
    ) -> CGFloat {
        leadingGap + 1 + dividerGap + diameter + (labelWidth > 0 ? TimerRingBadge.labelGap + labelWidth : 0)
    }

    /// The usual gap in front of the divider.
    static let defaultLeadingGap: CGFloat = 8

    /// Gap to use when the badge trails a fixed-width column (the elapsed
    /// counter) that is wider than the text inside it.
    ///
    /// The column's slack is empty space, so the badge is pulled back by exactly
    /// that much and the divider keeps the same visible gap to the digits
    /// whatever their length. When a completion mark follows the counter — the
    /// green checkmark, or the red warning triangle of a failed task — that mark
    /// already occupies the slack, so pulling back would drop the divider on top
    /// of it; the badge then keeps the plain gap.
    static func trailingGap(
        columnWidth: CGFloat,
        measuredTextWidth: CGFloat,
        hasCompletionMark: Bool
    ) -> CGFloat {
        guard !hasCompletionMark else { return defaultLeadingGap }
        return defaultLeadingGap - max(0, columnWidth - measuredTextWidth)
    }

    /// Angle of the record at `date`, measured from `base`. Pure, so it can be
    /// reasoned about (and tested): the view shifts `base` by every hover instead
    /// of letting the angle jump ahead while it was stopped.
    static func spinAngle(at date: Date, since base: Date) -> Double {
        let elapsed = date.timeIntervalSince(base)
        guard elapsed > 0 else { return 0 }
        let turns = elapsed / secondsPerTurn
        return (turns - turns.rounded(.down)) * 360
    }

    /// Width of the countdown a timer badge draws beside its ring.
    private var labelWidth: CGFloat {
        guard case .timer(_, _, let label) = content else { return 0 }
        return TimerRingBadge.labelWidth(label)
    }

    @State private var spinBase = Date()
    @State private var pauseBegan: Date?

    @ViewBuilder
    private var circle: some View {
        switch content {
        case .artwork(let artwork):
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: isPaused)) { context in
                SpinningAlbumArt(
                    artwork: artwork,
                    diameter: diameter,
                    angle: Self.spinAngle(at: context.date, since: spinBase)
                )
            }
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
            .overlay(
                Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
        case .timer(let progress, let color, let label):
            TimerRingBadge(
                progress: progress,
                color: color,
                diameter: diameter,
                label: label
            )
            .frame(width: TimerRingBadge.width(diameter: diameter, label: label), height: diameter)
        }
    }

    private func report(dividerX: CGFloat?) {
        switch slot {
        case .media: DynamicIslandViewCoordinator.shared.mediaDividerX = dividerX
        case .timer: DynamicIslandViewCoordinator.shared.timerDividerX = dividerX
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: max(8, diameter * 0.7))
                .padding(.leading, leadingGap)
                .padding(.trailing, dividerGap)
                .background(
                    GeometryReader { geometry in
                        let x = geometry.frame(in: .global).midX
                        Color.clear
                            .onAppear { report(dividerX: x) }
                            .onChange(of: x) { _, newX in report(dividerX: newX) }
                    }
                )

            circle
        }
        .frame(width: Self.width(
            diameter: diameter,
            leadingGap: leadingGap,
            dividerGap: dividerGap,
            labelWidth: labelWidth
        ))
        .onDisappear { report(dividerX: nil) }
        .onChange(of: isPaused) { _, paused in
            if paused {
                pauseBegan = Date()
            } else if let began = pauseBegan {
                // Stopped for `began…now`: move the origin forward by that much
                // so the record resumes at the angle it was left at.
                spinBase = spinBase.addingTimeInterval(Date().timeIntervalSince(began))
                pauseBegan = nil
            }
        }
    }
}

/// The record itself, at a given angle. Split out from the badge so it can be
/// rendered at a known angle (tests) instead of only from the clock.
struct SpinningAlbumArt: View {
    let artwork: NSImage
    let diameter: CGFloat
    let angle: Double

    var body: some View {
        Image(nsImage: artwork)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(
                width: diameter * MusicCornerBadge.spinOverflow,
                height: diameter * MusicCornerBadge.spinOverflow
            )
            .rotationEffect(.degrees(angle))
    }
}

extension MusicManager {
    /// Same "is there something worth showing" test the closed music pairing
    /// uses: playing, or paused with real metadata on screen.
    var hasActiveSnapshot: Bool {
        if isPlaying { return true }
        let hasMetadata = !songTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !artistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !isPlayerIdle && hasMetadata
    }
}
