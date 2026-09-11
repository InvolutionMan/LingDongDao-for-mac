import CoreGraphics

/// What hovering a spot on the closed island opens.
///
/// The trailing corner of the pill can hold companions — the album-art circle of
/// whatever is playing, the ring of a running timer — and each one owns the
/// stretch to the right of its own divider. Everything before the first divider
/// belongs to the running task.
enum IslandHoverDestination: Equatable {
    case cliDetail
    case home
    case timer
}

/// Splits the pill for the hover. `windowX` and the dividers are all in the
/// island window's own coordinates (top-left origin), the space the badges report
/// their dividers in. With no companion on screen there is nothing to separate,
/// so the window's midpoint splits detail from home.
func islandHoverDestination(
    windowX: CGFloat,
    mediaDivider: CGFloat?,
    timerDivider: CGFloat?,
    windowWidth: CGFloat
) -> IslandHoverDestination {
    if let timerDivider, windowX >= timerDivider { return .timer }
    if let mediaDivider, windowX >= mediaDivider { return .home }
    if mediaDivider == nil && timerDivider == nil {
        return windowX < windowWidth / 2 ? .cliDetail : .home
    }
    return .cliDetail
}
