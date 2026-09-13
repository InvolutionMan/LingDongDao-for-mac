import Foundation

/// The payload macOS stores for one delivered notification: a binary plist whose
/// interesting strings sit under `req` (`titl`, `subt`, `body`, …).
///
/// The layout is not documented and varies a little per app and macOS release,
/// so this walks the plist for the first value of each key instead of trusting
/// one fixed path — the alternative is a helper that breaks silently.
struct NotificationPayload {
    let title: String
    let subtitle: String?
    let body: String?
    let appName: String?

    /// Who the message is from. WeChat and QQ announce the sender in the
    /// subtitle and use the app name as the title, but plenty of apps do the
    /// opposite, so prefer the subtitle only when it is not the app's own name.
    var sender: String {
        if let subtitle, !subtitle.isEmpty, subtitle != appName, subtitle != title {
            return subtitle
        }
        return title.isEmpty ? appName ?? "通知" : title
    }

    init?(data: Data) {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else { return nil }

        let values = Self.flatten(plist)
        func first(_ keys: [String]) -> String? {
            for key in keys {
                if let value = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty {
                    return value
                }
            }
            return nil
        }

        guard let title = first(["titl", "title"]) else { return nil }
        self.title = title
        self.subtitle = first(["subt", "subtitle"])
        self.body = first(["body", "message"])
        self.appName = first(["appn", "appName", "displayName"])
    }

    /// Flattens nested dictionaries, keeping the first value seen for a key.
    private static func flatten(_ object: Any) -> [String: String] {
        var found: [String: String] = [:]
        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                for (key, nested) in dictionary {
                    if let text = nested as? String, found[key] == nil {
                        found[key] = text
                    } else {
                        walk(nested)
                    }
                }
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        walk(object)
        return found
    }
}
