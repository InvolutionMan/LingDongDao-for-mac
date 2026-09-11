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

/// Whether a closed-notch activity should carry the small album-art badge of
/// whatever media is playing behind it.
///
/// This is the mirror image of `isClosedMusicPairingEligible`. There the music
/// keeps the main slot (big artwork in the left wing) and its companion is a
/// tiny icon badge; here a task — a CLI agent, which outranks the media island —
/// keeps the main slot, so the media shrinks into a circle on its right, the way
/// the iPhone's Dynamic Island splits a call from a playing track.
///
/// The conditions are the same ones the music pairing uses, so the badge cannot
/// appear in a state where the full music activity would have been suppressed
/// (`hideOnClosed`, lock screen, the post-unlock deferral, the user's setting).
/// The activity views that call this only ever render while the notch is closed,
/// so `notchState` is not repeated here.
func isClosedMusicBadgeEligible(
    hasActiveMusicSnapshot: Bool,
    musicLiveActivityEnabled: Bool,
    closedMusicContentEnabled: Bool,
    hideOnClosed: Bool,
    isLocked: Bool,
    isDeferredAfterUnlock: Bool
) -> Bool {
    hasActiveMusicSnapshot
        && musicLiveActivityEnabled
        && closedMusicContentEnabled
        && !hideOnClosed
        && !isLocked
        && !isDeferredAfterUnlock
}
