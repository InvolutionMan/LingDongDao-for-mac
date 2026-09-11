import SwiftUI
import Defaults
#if canImport(AppKit)
import AppKit
#endif

/// The open-notch content shown when the user hovers the closed-notch CLI live
/// activity: instead of the Home tab, the island expands to its normal open
/// size and shows what the running CLI agent is doing right now — the tool and
/// target, cache hit rate, token usage, model and thinking degree.
/// Publishes the panel's rendered height so the island can size itself.
private struct CLIDetailContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct CLIActivityDetailView: View {
    /// Vertical rhythm between agent cards; also used for the height estimate.
    static let sectionSpacing: CGFloat = 12
    private var sectionSpacing: CGFloat { Self.sectionSpacing }

    @ObservedObject var piMonitor = PiSessionMonitor.shared
    @ObservedObject var codexMonitor = CodexSessionMonitor.shared
    @ObservedObject var claudeMonitor = ClaudeSessionMonitor.shared
    @ObservedObject var dshMonitor = DshSessionMonitor.shared

    var body: some View {
        // No ScrollView: the island grows to fit every card (see
        // `DynamicIslandViewModel.calculateDynamicNotchSize`), and the measured
        // height is what tells it how much room to take.
        VStack(alignment: .leading, spacing: sectionSpacing) {
            if piMonitor.isActive {
                piSection
            }
            if codexMonitor.isActive {
                codexSection
            }
            if claudeMonitor.isActive {
                claudeSection
            }
            if dshMonitor.isActive {
                dshSection
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: CLIDetailContentHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(CLIDetailContentHeightKey.self) { height in
            let measured = height.rounded()
            let coordinator = DynamicIslandViewCoordinator.shared
            if abs(coordinator.cliDetailContentHeight - measured) > 0.5 {
                coordinator.cliDetailContentHeight = measured
            }
        }
        .onAppear {
            CLIActivityDebugLog.record(
                "CLI detail view appeared: pi=\(piMonitor.isActive ? 1 : 0) codex=\(codexMonitor.isActive ? 1 : 0) claude=\(claudeMonitor.isActive ? 1 : 0) dsh=\(dshMonitor.isActive ? 1 : 0) piTasks=\(piMonitor.detail?.tasks.count ?? -1)"
            )
            logCurrentPiTask()
        }
        .onChange(of: piMonitor.detail) { _, _ in
            logCurrentPiTask()
        }
    }

    /// Debug-only breadcrumb: the single line the panel is rendering for pi.
    private func logCurrentPiTask() {
        guard Defaults[.enableCLIActivityDebugLog], let detail = piMonitor.detail else { return }
        let rendered: String
        if let error = detail.errorMessage {
            rendered = "error: \(shortError(error))"
        } else if let task = currentTask(detail) {
            rendered = "\(task.name) \(task.target ?? "-") \(task.isRunning ? "running" : "idle")"
        } else {
            rendered = "none"
        }
        CLIActivityDebugLog.record("panel line: \(rendered)")
    }

    // MARK: - Sections

    private var piSection: some View {
        section(
            title: "Pi",
            icon: AnyView(
                Image("PiText")
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(.white)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 15, height: 15)
            ),
            model: piMonitor.model,
            level: piMonitor.thinkingLevel,
            levelColor: piThinkingColor(piMonitor.thinkingLevel),
            started: piStarted,
            frozenTime: piFrozenTime
        ) {
            if let detail = piMonitor.detail {
                detailStats(detail)
            }
        }
    }

    private var codexSection: some View {
        section(
            title: "Codex",
            icon: AnyView(
                Image("CodexIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 15, height: 15)
            ),
            model: codexMonitor.model,
            level: codexMonitor.thinkingLevel,
            levelColor: codexThinkingColor(codexMonitor.thinkingLevel),
            started: codexStarted,
            frozenTime: codexFrozenTime
        ) {
            activityLine(codexMonitor.activity, isBusy: codexMonitor.isBusy)
            usageStats(codexMonitor.usage)
        }
    }

    private var claudeSection: some View {
        section(
            title: "Claude Code",
            icon: AnyView(
                Image("ClaudeIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 15, height: 15)
            ),
            model: claudeMonitor.model,
            level: claudeMonitor.thinkingLevel,
            levelColor: claudeThinkingColor(claudeMonitor.thinkingLevel),
            started: claudeStarted,
            frozenTime: claudeFrozenTime
        ) {
            activityLine(claudeMonitor.activity, isBusy: claudeMonitor.isBusy)
            usageStats(claudeMonitor.usage)
        }
    }

    /// DSH (`dst`) reports the same shape as pi (`PiLiveDetail`), so it reuses
    /// the pi card rendering — only the icon, title and palette differ.
    private var dshSection: some View {
        section(
            title: "DSH",
            icon: AnyView(
                // The DeepSeek whale keeps its own colours — no template tint.
                Image("DshIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 15, height: 15)
            ),
            model: dshMonitor.model,
            level: dshMonitor.thinkingLevel,
            levelColor: piThinkingColor(dshMonitor.thinkingLevel),
            started: dshStarted,
            frozenTime: dshFrozenTime
        ) {
            if let detail = dshMonitor.detail {
                detailStats(detail)
            }
        }
    }

    // MARK: - Shared section layout

    @ViewBuilder
    private func section<Extra: View>(
        title: String,
        icon: AnyView,
        model: String?,
        level: String?,
        levelColor: Color,
        started: Date?,
        frozenTime: String?,
        @ViewBuilder extra: () -> Extra
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                icon

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                if let model {
                    Text(model)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if let level {
                    Text(level)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(levelColor)
                }

                if let started {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(PiLiveActivity.formatElapsed(context.date.timeIntervalSince(started)))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                    }
                } else if let frozenTime {
                    Text(frozenTime)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }

            extra()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
    }

    @ViewBuilder
    private func detailStats(_ detail: PiLiveDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Only the task pi is executing right now — completed and queued
            // calls are deliberately not listed. A provider failure takes the
            // line instead, because that is why nothing is running.
            if let error = detail.errorMessage {
                errorRow(error)
            } else if let confirmation = detail.confirmation {
                confirmationRow(confirmation)
            } else if let task = currentTask(detail) {
                taskLine(name: task.name, target: task.target, isRunning: task.isRunning)
            } else {
                Text("No tool activity yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
            }

            HStack(spacing: 22) {
                if let hit = detail.cacheHitRate {
                    stat(label: "Cache hit", value: CLIUsage.percentText(hit))
                }
                if let total = detail.totalTokens {
                    stat(label: "Tokens", value: PiLiveActivity.formatTokens(total))
                }
                if let input = detail.inputTokens, let output = detail.outputTokens {
                    stat(
                        label: "in / out",
                        value: "\(PiLiveActivity.formatTokens(input)) / \(PiLiveActivity.formatTokens(output))"
                    )
                }
                if let cacheRead = detail.cacheReadTokens, cacheRead > 0 {
                    stat(label: "cached", value: PiLiveActivity.formatTokens(cacheRead))
                }
            }
        }
    }

    /// What a Codex / Claude card shows on its task line: the provider error
    /// when the turn died on one, otherwise the task running now, otherwise a
    /// status word.
    @ViewBuilder
    private func activityLine(_ activity: CLIToolActivity?, isBusy: Bool) -> some View {
        if let error = activity?.errorMessage {
            errorRow(error)
        } else if let confirmation = activity?.confirmation {
            confirmationRow(confirmation)
        } else if let current = activity?.current {
            taskLine(name: current.name, target: current.target, isRunning: current.isRunning)
        } else {
            Text(isBusy ? "Working…" : "No tool activity yet")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    /// The agent is blocked until the user answers: say what it wants.
    private func confirmationRow(_ confirmation: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(confirmationColor)

            Text("Waiting for confirmation")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(confirmationColor)

            Text(confirmation)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(confirmation)
        }
    }

    private var confirmationColor: Color {
        Color(red: 0xFF / 255.0, green: 0x9F / 255.0, blue: 0x0A / 255.0)
    }

    private func errorRow(_ error: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(errorColor)

            Text(shortError(error))
                .font(.system(size: 12))
                .foregroundStyle(errorColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(error)
        }
    }

    /// The one-line "what is it doing right now" row, shared by every CLI card.
    @ViewBuilder
    private func taskLine(name: String, target: String?, isRunning: Bool) -> some View {
        HStack(spacing: 8) {
            Text(activityLabel(for: name))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 58, alignment: .leading)

            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.white.opacity(0.16)))

            if let target {
                Text(target)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(isRunning ? 0.9 : 0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(target)
            }

            if isRunning {
                Circle()
                    .fill(Color.green.opacity(0.9))
                    .frame(width: 5, height: 5)
            }
        }
    }

    /// Token/cache readout shared by the Codex and Claude cards (pi keeps its
    /// own richer `PiLiveDetail`).
    @ViewBuilder
    private func usageStats(_ usage: CLIUsage?) -> some View {
        if let usage {
            HStack(spacing: 22) {
                if let hit = usage.cacheHitRate {
                    stat(label: "Cache hit", value: CLIUsage.percentText(hit))
                }
                if usage.totalTokens > 0 {
                    stat(label: "Tokens", value: PiLiveActivity.formatTokens(usage.totalTokens))
                }
                if let input = usage.inputTokens, let output = usage.outputTokens {
                    stat(
                        label: "in / out",
                        value: "\(PiLiveActivity.formatTokens(input)) / \(PiLiveActivity.formatTokens(output))"
                    )
                }
                if let cached = usage.cacheReadTokens, cached > 0 {
                    stat(label: "cached", value: PiLiveActivity.formatTokens(cached))
                }
            }
        }
    }

    private var errorColor: Color {
        Color(red: 0xFF / 255.0, green: 0x45 / 255.0, blue: 0x3A / 255.0)
    }

    /// Provider errors arrive as `429: {"message":"Rate limit exceeded…"}` —
    /// surface the human-readable part, keep the rest in the tooltip.
    private func shortError(_ message: String) -> String {
        if let range = message.range(of: "\"message\":\"") {
            let rest = message[range.upperBound...]
            if let end = rest.firstIndex(of: "\"") {
                return String(rest[..<end])
            }
        }
        let head = message.split(separator: "{", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? message
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.isEmpty ? message : trimmed
        return text.count > 70 ? String(text.prefix(70)) + "…" : text
    }

    /// The single task shown in the panel: the one executing now, falling back
    /// to the most recent tool while the model is between calls.
    private func currentTask(_ detail: PiLiveDetail) -> (name: String, target: String?, isRunning: Bool)? {
        if let running = detail.tasks.first(where: { $0.state == .running }) {
            return (running.name, running.target, true)
        }
        if let name = detail.toolName {
            return (name, detail.toolTarget, false)
        }
        return nil
    }

    private func stat(label: String, value: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    /// Reading / Editing / Running / Fetching — what the active tool is doing.
    private func activityLabel(for toolName: String) -> String {
        switch toolName {
        case "read": return "Reading"
        case "write", "edit", "multi_edit": return "Editing"
        case "bash", "shell": return "Running"
        case "grep", "glob", "search": return "Searching"
        case "fetch_content", "web_search", "get_search_content": return "Fetching"
        case "task", "agent": return "Agent"
        case "todo", "todowrite": return "Planning"
        default: return "Running"
        }
    }

    // MARK: - Phase accessors

    private var piStarted: Date? {
        if case .running(let started) = piMonitor.phase { return started }
        return nil
    }

    private var piFrozenTime: String? {
        if case .completed(let at, let startedAt) = piMonitor.phase {
            return PiLiveActivity.formatElapsed(at.timeIntervalSince(startedAt ?? at))
        }
        return nil
    }

    private var codexStarted: Date? {
        if case .running(let started) = codexMonitor.phase { return started }
        return nil
    }

    private var codexFrozenTime: String? {
        if case .completed(let at, let startedAt) = codexMonitor.phase {
            return PiLiveActivity.formatElapsed(at.timeIntervalSince(startedAt ?? at))
        }
        return nil
    }

    private var dshStarted: Date? {
        if case .running(let started) = dshMonitor.phase { return started }
        return nil
    }

    private var dshFrozenTime: String? {
        if case .completed(let at, let startedAt) = dshMonitor.phase {
            return PiLiveActivity.formatElapsed(at.timeIntervalSince(startedAt ?? at))
        }
        return nil
    }

    private var claudeStarted: Date? {
        if case .running(let started) = claudeMonitor.phase { return started }
        return nil
    }

    private var claudeFrozenTime: String? {
        if case .completed(let at, let startedAt) = claudeMonitor.phase {
            return ClaudeLiveActivity.formatElapsed(at.timeIntervalSince(startedAt ?? at))
        }
        return nil
    }

    // MARK: - Palettes

    private func piThinkingColor(_ level: String?) -> Color {
        switch level {
        case "minimal": return Color(red: 0x64 / 255.0, green: 0xD2 / 255.0, blue: 0xFF / 255.0)
        case "low": return Color(red: 0x5E / 255.0, green: 0x5C / 255.0, blue: 0xE6 / 255.0)
        case "medium": return Color(red: 0xBF / 255.0, green: 0x5A / 255.0, blue: 0xF2 / 255.0)
        case "high", "xhigh", "max": return Color(red: 0xFF / 255.0, green: 0x9F / 255.0, blue: 0x0A / 255.0)
        default: return Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0)
        }
    }

    private func codexThinkingColor(_ level: String?) -> Color {
        switch level {
        case "medium": return Color(red: 0x64 / 255.0, green: 0xD2 / 255.0, blue: 0xFF / 255.0)
        case "high": return Color(red: 0x5E / 255.0, green: 0x5C / 255.0, blue: 0xE6 / 255.0)
        case "xhigh": return Color(red: 0xFF / 255.0, green: 0x9F / 255.0, blue: 0x0A / 255.0)
        default: return Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0)
        }
    }

    private func claudeThinkingColor(_ level: String?) -> Color {
        switch level {
        case "medium": return Color(red: 0x64 / 255.0, green: 0xD2 / 255.0, blue: 0xFF / 255.0)
        case "high": return Color(red: 0x5E / 255.0, green: 0x5C / 255.0, blue: 0xE6 / 255.0)
        case "max", "xhigh": return Color(red: 0xFF / 255.0, green: 0x9F / 255.0, blue: 0x0A / 255.0)
        default: return Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0)
        }
    }
}
