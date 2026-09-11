/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import SwiftUI
import XCTest
@testable import Atoll

/// The media circle a closed-notch activity shows when a task shares the island
/// with music: album art only, behind a hairline divider, on the right.
final class MusicCornerBadgeTests: XCTestCase {

    private func eligible(
        hasActiveMusicSnapshot: Bool = true,
        musicLiveActivityEnabled: Bool = true,
        closedMusicContentEnabled: Bool = true,
        hideOnClosed: Bool = false,
        isLocked: Bool = false,
        isDeferredAfterUnlock: Bool = false
    ) -> Bool {
        isClosedMusicBadgeEligible(
            hasActiveMusicSnapshot: hasActiveMusicSnapshot,
            musicLiveActivityEnabled: musicLiveActivityEnabled,
            closedMusicContentEnabled: closedMusicContentEnabled,
            hideOnClosed: hideOnClosed,
            isLocked: isLocked,
            isDeferredAfterUnlock: isDeferredAfterUnlock
        )
    }

    func testBadgeShowsOnlyWhenMusicIsWorthShowing() {
        XCTAssertTrue(eligible())
        XCTAssertFalse(eligible(hasActiveMusicSnapshot: false), "nothing playing")
        XCTAssertFalse(eligible(musicLiveActivityEnabled: false), "user turned the media island off")
        XCTAssertFalse(eligible(closedMusicContentEnabled: false), "no closed media content")
        XCTAssertFalse(eligible(hideOnClosed: true), "island is hidden")
        XCTAssertFalse(eligible(isLocked: true), "lock screen owns the notch")
        XCTAssertFalse(eligible(isDeferredAfterUnlock: true), "music HUD deferred after unlock")
    }

    func testBadgeWidthIsGapsPlusDividerPlusCircle() {
        XCTAssertEqual(MusicCornerBadge.width(diameter: 22), 8 + 1 + 8 + 22, accuracy: 0.001)
        XCTAssertEqual(MusicCornerBadge.width(diameter: 22, leadingGap: 0), 1 + 8 + 22, accuracy: 0.001)
        XCTAssertEqual(MusicCornerBadge.width(diameter: 22, leadingGap: -9), -9 + 1 + 8 + 22, accuracy: 0.001)
    }

    /// Renders the badge and checks the geometry the eye would check: a hairline
    /// divider, an 8pt gap, then a clipped circle of the requested diameter.
    @MainActor
    func testRenderedBadgeIsADividerFollowedByACircle() throws {
        let scale: CGFloat = 4
        let diameter: CGFloat = 22
        let width = MusicCornerBadge.width(diameter: diameter)
        let artwork = Self.solidArtwork(size: 64)

        let renderer = ImageRenderer(
            content: MusicCornerBadge(artwork: artwork, diameter: diameter)
                .frame(width: width, height: diameter)
                .background(Color.black)
        )
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer produced nothing")

        XCTAssertEqual(CGFloat(image.width) / scale, width, accuracy: 1, "badge width")
        XCTAssertEqual(CGFloat(image.height) / scale, diameter, accuracy: 1, "badge height")

        let bitmap = try XCTUnwrap(NSBitmapImageRep(cgImage: image))
        /// Anything brighter than the black pill counts as drawn: the divider is
        /// a 18%-white hairline, the artwork is fully saturated.
        func isLit(_ x: CGFloat, _ y: CGFloat) -> Bool {
            guard let colour = bitmap.colorAt(x: Int(x * scale), y: Int(y * scale)) else { return false }
            return colour.brightnessComponent > 0.08
        }

        // The divider sits one leading gap in, and is one point wide.
        XCTAssertTrue(isLit(8.5, diameter / 2), "divider missing")
        XCTAssertFalse(isLit(5, diameter / 2), "nothing should be drawn before the divider")
        XCTAssertFalse(isLit(12, diameter / 2), "the divider must stay a hairline")

        // The circle starts after dividerGap and is round: its centre is lit, its
        // bounding-box corners are not.
        let centreX = 8 + 1 + 8 + diameter / 2
        XCTAssertTrue(isLit(centreX, diameter / 2), "album art missing")
        XCTAssertFalse(isLit(8 + 1 + 8 + 1, 1), "corner of the art box must be clipped away")
        XCTAssertFalse(isLit(8 + 1 + 8 + diameter - 1, diameter - 1), "corner of the art box must be clipped away")
    }

    private static func solidArtwork(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()
        return image
    }
}
