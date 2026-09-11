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

    /// The bug this guards: a finished task shows a checkmark — or, when it
    /// failed, a red warning triangle — right after the counter. The badge used
    /// to be pulled back by the counter's slack regardless, so the divider landed
    /// on top of that mark.
    func testBadgeGapCompensatesTheCounterButNeverTheCompletionMark() {
        XCTAssertEqual(
            MusicCornerBadge.trailingGap(columnWidth: 56, measuredTextWidth: 39, hasCompletionMark: false),
            8 - 17, accuracy: 0.001,
            "a running task leaves the column slack empty, so the badge is pulled back"
        )
        XCTAssertEqual(
            MusicCornerBadge.trailingGap(columnWidth: 56, measuredTextWidth: 39, hasCompletionMark: true),
            8, accuracy: 0.001,
            "the checkmark / failure mark fills that slack — no pull-back"
        )
        XCTAssertEqual(
            MusicCornerBadge.trailingGap(columnWidth: 56, measuredTextWidth: 56, hasCompletionMark: false),
            8, accuracy: 0.001
        )
        XCTAssertEqual(
            MusicCornerBadge.trailingGap(columnWidth: 56, measuredTextWidth: 70, hasCompletionMark: false),
            8, accuracy: 0.001,
            "a counter longer than its column must not push the badge to the left"
        )
    }

    /// The badge must never be laid out over the mark: the row reserves the
    /// counter, the mark and then the badge, and every term is positive.
    func testReservedWidthKeepsTheMarkAndTheBadgeApart() {
        let column: CGFloat = 56
        let mark: CGFloat = 16
        let markGap: CGFloat = 3
        let gap = MusicCornerBadge.trailingGap(columnWidth: column, measuredTextWidth: 39, hasCompletionMark: true)
        let badge = MusicCornerBadge.width(diameter: 22, leadingGap: gap)

        // What the row draws, left to right, after the counter's column.
        XCTAssertGreaterThanOrEqual(gap, 8)
        XCTAssertEqual(badge, gap + 1 + 8 + 22, accuracy: 0.001)
        XCTAssertGreaterThan(markGap + mark + gap, mark, "the divider sits after the mark, not on it")
    }

    // MARK: - The record turns

    func testSpinAngleTurnsOnceEveryEightSeconds() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(MusicCornerBadge.spinAngle(at: base, since: base), 0, accuracy: 0.001)
        XCTAssertEqual(MusicCornerBadge.spinAngle(at: base.addingTimeInterval(2), since: base), 90, accuracy: 0.001)
        XCTAssertEqual(MusicCornerBadge.spinAngle(at: base.addingTimeInterval(6), since: base), 270, accuracy: 0.001)
        XCTAssertEqual(MusicCornerBadge.spinAngle(at: base.addingTimeInterval(8), since: base), 0, accuracy: 0.001)
        XCTAssertEqual(MusicCornerBadge.spinAngle(at: base.addingTimeInterval(9), since: base), 45, accuracy: 0.001)
        XCTAssertEqual(MusicCornerBadge.spinAngle(at: base.addingTimeInterval(-5), since: base), 0, "never negative")
    }

    /// A hovering pointer shifts the origin instead of the angle, so the record
    /// carries on from where it stopped.
    func testPauseKeepsTheAngleInsteadOfJumpingAhead() {
        let base = Date(timeIntervalSince1970: 2_000_000)
        let stoppedAt = base.addingTimeInterval(3)          // 135°
        let resumedAt = stoppedAt.addingTimeInterval(5)     // hovered five seconds
        let shiftedBase = base.addingTimeInterval(5)        // what the view does on resume

        XCTAssertEqual(MusicCornerBadge.spinAngle(at: stoppedAt, since: base), 135, accuracy: 0.001)
        XCTAssertEqual(
            MusicCornerBadge.spinAngle(at: resumedAt, since: shiftedBase), 135, accuracy: 0.001,
            "resuming must not skip the paused stretch"
        )
        XCTAssertEqual(
            MusicCornerBadge.spinAngle(at: resumedAt.addingTimeInterval(2), since: shiftedBase), 225, accuracy: 0.001
        )
    }

    /// Rotating the artwork must not open a gap at the rim: the drawing is
    /// larger than the circle for exactly that reason.
    @MainActor
    func testRotatedArtworkStillCoversTheWholeCircle() throws {
        let scale: CGFloat = 4
        let diameter: CGFloat = 22
        let bitmap = try Self.render(
            SpinningAlbumArt(artwork: Self.halfAndHalfArtwork(size: 64), diameter: diameter, angle: 45)
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .background(Color.black),
            scale: scale
        )

        // Sample a ring just inside the rim, every 15°: all of it must be painted.
        let centre = Double(bitmap.pixelsWide) / 2
        let radius = Double(diameter) / 2 * Double(scale) - 2
        for step in 0..<24 {
            let angle = Double(step) * 15 * .pi / 180
            let x = Int(centre + radius * cos(angle))
            let y = Int(centre + radius * sin(angle))
            let colour = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
            XCTAssertGreaterThan(
                colour.brightnessComponent, 0.2,
                "rim uncovered at \(step * 15)° — the rotating square is too small for the circle"
            )
        }
    }

    /// Rotation is really applied to the picture, not just to the frame.
    @MainActor
    func testRotationChangesWhatIsDrawn() throws {
        let diameter: CGFloat = 22
        let artwork = Self.halfAndHalfArtwork(size: 64)
        let straight = try Self.render(
            SpinningAlbumArt(artwork: artwork, diameter: diameter, angle: 0).frame(width: diameter, height: diameter),
            scale: 2
        )
        let turned = try Self.render(
            SpinningAlbumArt(artwork: artwork, diameter: diameter, angle: 45).frame(width: diameter, height: diameter),
            scale: 2
        )

        var differences = 0
        for x in 0..<min(straight.pixelsWide, turned.pixelsWide) {
            for y in 0..<min(straight.pixelsHigh, turned.pixelsHigh) {
                let a = try XCTUnwrap(straight.colorAt(x: x, y: y))
                let b = try XCTUnwrap(turned.colorAt(x: x, y: y))
                // White and green differ in red, not in brightness.
                if abs(a.redComponent - b.redComponent) > 0.5 { differences += 1 }
            }
        }
        XCTAssertGreaterThan(differences, 50, "a 45° turn should repaint a good part of the artwork")
    }

    @MainActor
    private static func render<V: View>(_ view: V, scale: CGFloat) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.cgImage)
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image))
    }

    /// White over green: both halves are bright (so an uncovered rim is
    /// unmistakable) yet a turn repaints the picture.
    private static func halfAndHalfArtwork(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: size / 2, width: size, height: size / 2).fill()
        NSColor.green.setFill()
        NSRect(x: 0, y: 0, width: size, height: size / 2).fill()
        image.unlockFocus()
        return image
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
