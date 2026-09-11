import AppKit
import SwiftUI

/// The media, shrunk into the closed island's trailing corner: a hairline
/// divider, then the album art turning slowly in a circle — the running task
/// keeps the main slot, exactly like the iPhone's Dynamic Island puts a call on
/// the left and the playing track on the right.
///
/// The badge owns its own spacing (the gap before the divider and after it), so
/// callers only reserve `MusicCornerBadge.width(...)` and append the view.
struct MusicCornerBadge: View {
    let artwork: NSImage
    /// Diameter of the album-art circle; the caller sizes it to the pill height.
    let diameter: CGFloat
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

    /// Total width the badge adds to a pill.
    static func width(diameter: CGFloat, leadingGap: CGFloat = 8, dividerGap: CGFloat = 8) -> CGFloat {
        leadingGap + 1 + dividerGap + diameter
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

    @State private var spinBase = Date()
    @State private var pauseBegan: Date?

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: max(8, diameter * 0.7))
                .padding(.leading, leadingGap)
                .padding(.trailing, dividerGap)

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
        }
        .frame(width: Self.width(diameter: diameter, leadingGap: leadingGap, dividerGap: dividerGap))
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
