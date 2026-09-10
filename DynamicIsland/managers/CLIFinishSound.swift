import AppKit
import AVFoundation
import Defaults

/// Finish / attention chime for a CLI agent.
///
/// - `success`: the turn ended cleanly.
/// - `failure`: it died on a provider error (connection, timeout, output,
///   rate limit) or its last tool failed.
/// - `confirmation`: the agent is blocked waiting for the user — a permission
///   prompt, an approval dialog, or "waiting for your input".
///
/// Paths are configurable in Settings and live in Atoll's Application Support
/// folder by default. Playback prefers `AVAudioPlayer`: unlike `NSSound` it is
/// not scaled by the system *alert* volume, which is often 0 on machines whose
/// output volume is fine.
enum CLIFinishSound {
    enum Kind {
        case success
        case failure
        case confirmation

        var path: String {
            switch self {
            case .success: return Defaults[.cliSuccessSoundPath]
            case .failure: return Defaults[.cliFailureSoundPath]
            case .confirmation: return Defaults[.cliConfirmSoundPath]
            }
        }

        var systemFallbackName: String {
            switch self {
            case .success: return "Glass"
            case .failure: return "Basso"
            case .confirmation: return "Ping"
            }
        }

        var label: String {
            switch self {
            case .success: return "success"
            case .failure: return "failure"
            case .confirmation: return "confirmation"
            }
        }
    }

    /// NSSound/AVAudioPlayer stop when deallocated, so in-flight audio is held
    /// here until it finishes.
    private static var sounds: [NSSound] = []
    private static var players: [AVAudioPlayer] = []

    static func play(_ kind: Kind, reason: String? = nil) {
        guard Defaults[.enableCLIFinishSound] else {
            CLIActivityDebugLog.record("sound skipped (\(kind.label)): disabled in Settings")
            return
        }

        let configured = kind.path.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = reason.map { " (\($0))" } ?? ""

        switch playFile(atPath: configured) {
        case .some(true):
            CLIActivityDebugLog.record("sound: \(kind.label) → \(configured)\(suffix)")
        case .some(false):
            CLIActivityDebugLog.record("sound: \(kind.label) → \(configured) failed to start, using system sound\(suffix)")
            playSystemFallback(kind)
        case .none:
            if !configured.isEmpty {
                CLIActivityDebugLog.record("sound: \(kind.label) → \(resolvedPath(configured)) not found, using system sound\(suffix)")
            } else {
                CLIActivityDebugLog.record("sound: \(kind.label) → system sound (no path configured)\(suffix)")
            }
            playSystemFallback(kind)
        }
    }

    /// Used by the Settings preview buttons.
    static func preview(_ kind: Kind) {
        if playFile(atPath: kind.path.trimmingCharacters(in: .whitespacesAndNewlines)) != true {
            playSystemFallback(kind)
        }
    }

    static func resolvedPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    static func fileExists(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: resolvedPath(trimmed))
    }

    /// Returns nil when there is no file to play, true/false when playback was
    /// attempted (`AVAudioPlayer.play()` reports failure, which used to look
    /// like a silent success).
    private static func playFile(atPath path: String) -> Bool? {
        guard fileExists(path) else { return nil }

        let url = URL(fileURLWithPath: resolvedPath(path))
        if let player = try? AVAudioPlayer(contentsOf: url) {
            players.removeAll { !$0.isPlaying }
            players.append(player)
            return player.play()
        }
        if let sound = NSSound(contentsOf: url, byReference: false) {
            sounds.removeAll { !$0.isPlaying }
            sounds.append(sound)
            return sound.play()
        }
        return false
    }

    private static func playSystemFallback(_ kind: Kind) {
        guard let sound = NSSound(named: kind.systemFallbackName) else { return }
        sounds.removeAll { !$0.isPlaying }
        sounds.append(sound)
        sound.play()
    }
}
