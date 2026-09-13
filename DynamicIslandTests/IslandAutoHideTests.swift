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

import XCTest
@testable import Atoll

/// The "hide the island when it has nothing to show" setting: quiet island steps
/// aside, anything the island supports brings it straight back.
final class IslandAutoHideTests: XCTestCase {

    private func signals(
        cliAgent: Bool = false,
        media: Bool = false,
        timer: Bool = false,
        reminder: Bool = false,
        recording: Bool = false,
        download: Bool = false,
        focus: Bool = false,
        privacyIndicator: Bool = false,
        sneakPeek: Bool = false,
        shelf: Bool = false,
        capsLock: Bool = false,
        extensionActivity: Bool = false
    ) -> IslandActivitySignals {
        IslandActivitySignals(
            cliAgent: cliAgent, media: media, timer: timer, reminder: reminder,
            recording: recording, download: download, focus: focus,
            privacyIndicator: privacyIndicator, sneakPeek: sneakPeek,
            shelf: shelf, capsLock: capsLock, extensionActivity: extensionActivity
        )
    }

    func testQuietIslandHasNothingToShow() {
        XCTAssertFalse(islandHasSomethingToShow(signals()))
    }

    /// Every supported activity counts on its own.
    func testEachActivityKeepsTheIsland() {
        let cases: [(String, IslandActivitySignals)] = [
            ("cli agent", signals(cliAgent: true)),
            ("media", signals(media: true)),
            ("timer", signals(timer: true)),
            ("reminder", signals(reminder: true)),
            ("recording", signals(recording: true)),
            ("download", signals(download: true)),
            ("focus", signals(focus: true)),
            ("privacy indicator", signals(privacyIndicator: true)),
            ("sneak peek", signals(sneakPeek: true)),
            ("shelf", signals(shelf: true)),
            ("caps lock", signals(capsLock: true)),
            ("extension activity (a chat message)", signals(extensionActivity: true)),
        ]
        for (name, value) in cases {
            XCTAssertTrue(islandHasSomethingToShow(value), "\(name) should keep the island")
        }
    }

    func testAutoHideOnlyAppliesToAQuietIsland() {
        // setting off → never hidden for being idle
        XCTAssertFalse(islandShouldHide(hideOnClosed: false, autoHideWhenIdle: false, signals: signals()))
        // setting on → hidden while quiet…
        XCTAssertTrue(islandShouldHide(hideOnClosed: false, autoHideWhenIdle: true, signals: signals()))
        // …and back on screen as soon as something is happening
        XCTAssertFalse(
            islandShouldHide(hideOnClosed: false, autoHideWhenIdle: true, signals: signals(cliAgent: true))
        )
        XCTAssertFalse(
            islandShouldHide(hideOnClosed: false, autoHideWhenIdle: true, signals: signals(timer: true))
        )
    }

    /// The bug this guards: with the auto-hide setting on, a WeChat / QQ message
    /// arriving through the bridge used to be suppressed because the island had
    /// already stepped aside and the message did not count as an activity.
    func testExtensionActivityBringsTheIslandBack() {
        let message = signals(extensionActivity: true)
        XCTAssertTrue(islandHasSomethingToShow(message))
        XCTAssertFalse(islandShouldHide(hideOnClosed: false, autoHideWhenIdle: true, signals: message))
    }

    /// A fullscreen app covering the menu bar still wins over any activity.
    func testFullscreenCoverageHidesRegardless() {
        XCTAssertTrue(islandShouldHide(hideOnClosed: true, autoHideWhenIdle: false, signals: signals(media: true)))
        XCTAssertTrue(islandShouldHide(hideOnClosed: true, autoHideWhenIdle: true, signals: signals(cliAgent: true)))
    }
}
