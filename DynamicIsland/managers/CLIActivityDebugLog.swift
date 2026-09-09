import Foundation
import Defaults

/// Rolling file log for the CLI activity monitors and the notch's CLI detail
/// panel, written only when `enableCLIActivityDebugLog` is on.
///
/// `NSLog` output from the installed app is not reliably visible in the unified
/// log, so this file is the support channel for reports like "the island isn't
/// showing my pi tasks": enable the flag, reproduce, then read
/// `~/.pi/agent/atoll-cli-debug.log`.
enum CLIActivityDebugLog {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".pi/agent/atoll-cli-debug.log")

    static func record(_ message: String) {
        NSLog("%@", "Atoll \(message)")
        guard Defaults[.enableCLIActivityDebugLog] else { return }

        let line = "\(timestamp()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static func reset() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
