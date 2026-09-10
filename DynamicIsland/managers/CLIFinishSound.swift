import AppKit
import Defaults

/// Finish chime for a CLI agent: the success sound when a turn ends cleanly and
/// the failure sound when the provider reported an error — connection failure,
/// request timeout, output failure, rate limiting, … all of which pi surfaces
/// as `stopReason: "error"` and the hook writes to the status file.
///
/// Both paths are configurable in Settings. An empty or unreadable path falls
/// back to the stock system sounds, so the feature still says *something*
/// instead of silently doing nothing.
enum CLIFinishSound {
    /// NSSound stops as soon as it deallocates, so in-flight sounds are held
    /// here until they finish.
    private static var inFlight: [NSSound] = []

    static func play(success: Bool) {
        guard Defaults[.enableCLIFinishSound] else { return }

        let configured = (success ? Defaults[.cliSuccessSoundPath] : Defaults[.cliFailureSoundPath])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let sound = sound(atPath: configured) {
            start(sound)
            CLIActivityDebugLog.record("finish sound: \(success ? "success" : "failure") → \(configured)")
            return
        }

        if let fallback = NSSound(named: success ? "Glass" : "Basso") {
            start(fallback)
            CLIActivityDebugLog.record("finish sound: \(success ? "success" : "failure") → system fallback")
        }
    }

    /// Used by the Settings preview buttons.
    static func preview(success: Bool) {
        let configured = (success ? Defaults[.cliSuccessSoundPath] : Defaults[.cliFailureSoundPath])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let sound = sound(atPath: configured) {
            start(sound)
        } else if let fallback = NSSound(named: success ? "Glass" : "Basso") {
            start(fallback)
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

    private static func sound(atPath path: String) -> NSSound? {
        guard fileExists(path) else {
            if !path.isEmpty {
                CLIActivityDebugLog.record("finish sound missing: \(resolvedPath(path))")
            }
            return nil
        }
        return NSSound(contentsOfFile: resolvedPath(path), byReference: true)
    }

    private static func start(_ sound: NSSound) {
        inFlight.removeAll { !$0.isPlaying }
        inFlight.append(sound)
        sound.play()
    }
}
