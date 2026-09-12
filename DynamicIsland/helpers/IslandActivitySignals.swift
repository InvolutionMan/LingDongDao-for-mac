import Foundation

/// Everything the closed island can show on its own. The auto-hide setting only
/// applies when *all* of these are quiet: an island with something to say stays
/// on screen, whatever the user asked for the idle case.
struct IslandActivitySignals: Equatable {
    /// A pi / Codex / Claude / DSH agent is running.
    var cliAgent: Bool = false
    /// Media worth showing (playing, or paused with metadata).
    var media: Bool = false
    var timer: Bool = false
    var reminder: Bool = false
    var recording: Bool = false
    var download: Bool = false
    var focus: Bool = false
    var privacyIndicator: Bool = false
    var sneakPeek: Bool = false
    var shelf: Bool = false
    var capsLock: Bool = false
}

/// True when any of the island's own live activities wants the closed pill.
func islandHasSomethingToShow(_ signals: IslandActivitySignals) -> Bool {
    signals.cliAgent
        || signals.media
        || signals.timer
        || signals.reminder
        || signals.recording
        || signals.download
        || signals.focus
        || signals.privacyIndicator
        || signals.sneakPeek
        || signals.shelf
        || signals.capsLock
}

/// Whether the island should step aside right now.
///
/// `hideOnClosed` is the existing rule (a fullscreen app covering the menu bar);
/// `autoHideWhenIdle` is the user's setting. With the setting on the island is
/// only hidden while nothing above is happening, so any activity brings it back
/// without the user having to touch the setting again.
func islandShouldHide(
    hideOnClosed: Bool,
    autoHideWhenIdle: Bool,
    signals: IslandActivitySignals
) -> Bool {
    hideOnClosed || (autoHideWhenIdle && !islandHasSomethingToShow(signals))
}
