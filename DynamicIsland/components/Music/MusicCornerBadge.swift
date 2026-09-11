import AppKit
import SwiftUI

/// The media, shrunk into the closed island's trailing corner: a hairline
/// divider, then the album art in a circle — the running task keeps the main
/// slot, exactly like the iPhone's Dynamic Island puts a call on the left and
/// the playing track on the right.
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

    /// Total width the badge adds to a pill.
    static func width(diameter: CGFloat, leadingGap: CGFloat = 8, dividerGap: CGFloat = 8) -> CGFloat {
        leadingGap + 1 + dividerGap + diameter
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: max(8, diameter * 0.7))
                .padding(.leading, leadingGap)
                .padding(.trailing, dividerGap)

            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        }
        .frame(width: Self.width(diameter: diameter, leadingGap: leadingGap, dividerGap: dividerGap))
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
