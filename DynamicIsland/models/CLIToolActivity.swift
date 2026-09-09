import Foundation

/// What a CLI agent is executing right now, as reported by its hook through the
/// `tool` / `tasks` objects of a status file.
///
/// Shared by the Claude Code monitor (and available to the others) so the panel
/// renders the same single line for every agent: the task running now, falling
/// back to the most recent tool while the model is between calls.
struct CLIToolActivity: Equatable {
    struct Task: Equatable, Identifiable {
        enum State: String {
            case completed
            case running
            case upcoming
        }

        let id: String
        let name: String
        let target: String?
        let state: State
    }

    var toolName: String?
    var toolTarget: String?
    var toolIsPending: Bool = false
    var tasks: [Task] = []

    /// The single task the panel shows.
    var current: (name: String, target: String?, isRunning: Bool)? {
        if let running = tasks.first(where: { $0.state == .running }) {
            return (running.name, running.target, true)
        }
        if let name = toolName {
            return (name, toolTarget, false)
        }
        return nil
    }

    var isEmpty: Bool { toolName == nil && tasks.isEmpty }

    /// Parses the `tool` / `tasks` objects of a hook status file. Returns nil
    /// when the hook reported neither.
    static func from(status obj: [String: Any]) -> CLIToolActivity? {
        var activity = CLIToolActivity()

        if let tool = obj["tool"] as? [String: Any] {
            activity.toolName = tool["name"] as? String
            activity.toolTarget = tool["target"] as? String
            activity.toolIsPending = (tool["pending"] as? Bool) ?? false
        }

        if let tasks = obj["tasks"] as? [[String: Any]] {
            activity.tasks = tasks.compactMap { task in
                guard let name = task["name"] as? String else { return nil }
                let state = Task.State(rawValue: task["state"] as? String ?? "") ?? .upcoming
                return Task(
                    id: task["id"] as? String ?? UUID().uuidString,
                    name: name,
                    target: task["target"] as? String,
                    state: state
                )
            }
        }

        return activity.isEmpty ? nil : activity
    }
}
