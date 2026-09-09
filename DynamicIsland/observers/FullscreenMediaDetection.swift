/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
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
import Combine
import Defaults
import SwiftUI

class FullscreenMediaDetector: ObservableObject {
    static let shared = FullscreenMediaDetector()
    @ObservedObject private var musicManager = MusicManager.shared
    @MainActor @Published private(set) var fullscreenStatus: [String: Bool] = [:]
    private var notificationTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        setupNotificationObservers()
        Defaults.publisher(.enableFullscreenMediaDetection, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self else { return }
                if change.newValue {
                    self.startPolling()
                } else {
                    self.stopPolling()
                }
                self.updateFullScreenStatus()
            }
            .store(in: &cancellables)
        if Defaults[.enableFullscreenMediaDetection] {
            startPolling()
        }
        updateFullScreenStatus()
    }

    private func setupNotificationObservers() {
        notificationTask = Task { @Sendable [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    let activeSpaceNotifications = NSWorkspace.shared.notificationCenter.notifications(
                        named: NSWorkspace.activeSpaceDidChangeNotification
                    )

                    for await _ in activeSpaceNotifications {
                        await self?.handleChange()
                    }
                }

                group.addTask {
                    let screenParameterNotifications = NSWorkspace.shared.notificationCenter.notifications(
                        named: NSApplication.didChangeScreenParametersNotification
                    )

                    for await _ in screenParameterNotifications {
                        await self?.handleChange()
                    }
                }
            }
        }
    }

    private func handleChange() async {
        try? await Task.sleep(for: .milliseconds(500))
        self.updateFullScreenStatus()
    }

    /// Polls on-screen windows so video-element fullscreen is caught even when
    /// no Space or AX event fires. The active-space notifications above are
    /// the fast path; this tick is the net that also catches browser video
    /// players that fullscreen a *window* without changing Spaces.
    private var pollTask: Task<Void, Never>?
    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.updateFullScreenStatus()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func updateFullScreenStatus() {
        guard Defaults[.enableFullscreenMediaDetection] else {
            let reset = Dictionary(uniqueKeysWithValues: NSScreen.screens.map { ($0.localizedName, false) })
            if reset != fullscreenStatus {
                fullscreenStatus = reset
            }
            return
        }

        let screens = NSScreen.screens
        let hideOption = Defaults[.hideNotchOption]
        let selfPID = ProcessInfo.processInfo.processIdentifier

        // Windows that cover the whole screen — right up to the very top edge
        // where the menu bar sits. Native fullscreen Spaces present that way,
        // and so does *element* fullscreen in browsers (YouTube / Bilibili
        // video players) which never enters a Space and never sets AXFullScreen.
        // A plain maximized/zoomed window stops below the menu bar, so it is
        // excluded by the top-edge test.
        var fullBleedOwners: [String: [String?]] = [:]
        for window in onScreenWindows() {
            guard window.pid != selfPID,
                  window.owner != "com.apple.finder",
                  window.owner != "com.apple.dock",
                  let screen = screens.first(where: { $0.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY)) }),
                  isFullBleed(window.frame, on: screen) else { continue }
            fullBleedOwners[screen.localizedName, default: []].append(window.owner)
        }

        let playingBundle = musicManager.bundleIdentifier

        var newStatus: [String: Bool] = [:]
        for screen in screens {
            let owners = fullBleedOwners[screen.localizedName] ?? []
            let shouldHide: Bool
            switch hideOption {
            case .always:
                shouldHide = !owners.isEmpty
            case .nowPlayingOnly:
                if let playingBundle {
                    shouldHide = owners.contains { $0 == playingBundle }
                } else {
                    shouldHide = false
                }
            case .never:
                shouldHide = false
            }
            newStatus[screen.localizedName] = shouldHide
        }

        if newStatus != fullscreenStatus {
            fullscreenStatus = newStatus
            NSLog("✅ Fullscreen status: \(newStatus)")
        }
    }

    /// True when the window reaches all four edges of the screen: top flush
    /// with `screen.maxY` (past the menu-bar strip), bottom at the screen's
    /// bottom, and spanning the full width. Tolerances mirror the
    /// CGWindow/Quartz imprecision on scaled and multi-display setups.
    private func isFullBleed(_ frame: CGRect, on screen: NSScreen) -> Bool {
        let screenFrame = screen.frame
        let tolerance: CGFloat = 4
        return frame.width >= screenFrame.width - tolerance
            && frame.height >= screenFrame.height - tolerance
            && abs(frame.maxY - screenFrame.maxY) <= tolerance
            && abs(frame.minY - screenFrame.minY) <= tolerance
    }

    /// Snapshot of on-screen windows (AppKit coordinates, bottom-left origin).
    private struct WindowSnapshot {
        let pid: pid_t
        let owner: String?
        let frame: CGRect
    }

    private func onScreenWindows() -> [WindowSnapshot] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let mainScreenQuartzHeight = CGDisplayBounds(CGMainDisplayID()).height
        var windows: [WindowSnapshot] = []

        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let quartzFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  let alpha = info[kCGWindowAlpha as String] as? CGFloat, alpha > 0,
                  (info[kCGWindowLayer as String] as? Int ?? 0) == 0 else { continue }

            // Quartz's Y axis is top-down; flip to AppKit's bottom-up.
            let appKitY = mainScreenQuartzHeight - quartzFrame.origin.y - quartzFrame.height
            let frame = CGRect(x: quartzFrame.origin.x, y: appKitY, width: quartzFrame.width, height: quartzFrame.height)

            windows.append(
                WindowSnapshot(
                    pid: pid,
                    owner: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                    frame: frame
                )
            )
        }
        return windows
    }

    private func cleanupNotificationObservers() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
