import SwiftUI
import Defaults
#if canImport(AppKit)
import AppKit
#endif

/// Shown when two or more CLI agents (pi, Codex, Claude Code) are executing
/// tasks at once: their activities stack vertically inside one island whose
/// length matches the single-activity expanded length, but thicker.
struct CLIStackActivityView: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject var piMonitor = PiSessionMonitor.shared
    @ObservedObject var codexMonitor = CodexSessionMonitor.shared
    @ObservedObject var claudeMonitor = ClaudeSessionMonitor.shared

    @State private var isHovering: Bool = false
    @State private var expanded: Bool = false
    @State private var piSpinning = false
    @State private var piCheckProgress: CGFloat = 0
    @State private var codexSpinning = false
    @State private var codexCheckProgress: CGFloat = 0
    @State private var claudeSpinning = false
    @State private var claudeCheckProgress: CGFloat = 0

    private var showsPi: Bool { piMonitor.isActive && Defaults[.enablePiLiveActivity] }
    private var showsCodex: Bool { codexMonitor.isActive && Defaults[.enableCodexLiveActivity] }
    private var showsClaude: Bool { claudeMonitor.isActive && Defaults[.enableClaudeLiveActivity] }

    private var rowCount: Int {
        (showsPi ? 1 : 0) + (showsCodex ? 1 : 0) + (showsClaude ? 1 : 0)
    }

    private var notchContentHeight: CGFloat {
        max(0, vm.effectiveClosedNotchHeight - (isHovering ? 0 : 12))
    }

    private var rowHeight: CGFloat { notchContentHeight + 4 }
    private var rowSpacing: CGFloat { 4 }

    private var ringDiameter: CGFloat { min(rowHeight, 22) }
    private var ringStrokeWidth: CGFloat { 2.5 }
    private var modelFrameWidth: CGFloat { 240 }
    private var elapsedTextWidth: CGFloat { 56 }
    private var hitRateColumnWidth: CGFloat { 46 }
    /// Every row reserves the column so the elapsed counters stay aligned; the
    /// column appears as soon as any of the three agents reports usage.
    private var showsHitRateColumn: Bool {
        piMonitor.detail?.cacheHitRate != nil
            || codexMonitor.usage?.cacheHitRate != nil
            || claudeMonitor.usage?.cacheHitRate != nil
    }
    private var checkmarkSize: CGFloat { 16 }
    private var pillWidth: CGFloat { vm.closedNotchSize.width + (isHovering ? 8 : 0) }

    /// Keeps the rings clear of the island's rounded corners: the closed pill
    /// is a capsule whose corner radius is `max(pillHeight/2, 16)`, so a ring
    /// must sit further right than that or its arc gets clipped.
    private var ringLeadingInset: CGFloat {
        max(vm.closedNotchSize.height / 2 + 6, 24)
    }

    private var thinkingMeasureFont: NSFont { .systemFont(ofSize: 13, weight: .regular) }

    private func measureTextWidth(_ text: String, font: NSFont) -> CGFloat {
        CGFloat(ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width))
    }

    private func thinkingWidth(_ level: String?) -> CGFloat {
        guard let level else { return 0 }
        return measureTextWidth(level, font: thinkingMeasureFont)
    }

    /// Widest thinking-degree column so every row aligns its columns.
    private var thinkingColumnWidth: CGFloat {
        max(thinkingWidth(piMonitor.thinkingLevel),
            max(thinkingWidth(codexMonitor.thinkingLevel), thinkingWidth(claudeMonitor.thinkingLevel)))
    }

    /// One activity's expanded length; the stacked island keeps this same
    /// length and only grows vertically (thicker) for extra rows.
    private var contentWidth: CGFloat {
        ringLeadingInset + ringDiameter
            + 14 + modelFrameWidth + 8
            + 6 + thinkingColumnWidth
            + (showsHitRateColumn ? 8 + hitRateColumnWidth : 0)
            + 4 + elapsedTextWidth
            + 3 + checkmarkSize
            + 8
    }

    private var displayWidth: CGFloat {
        expanded ? max(pillWidth, contentWidth) : pillWidth
    }

    /// Inner top/bottom breathing room inside the island. The island's top
    /// edge can sit a few points above the visible screen (`notchTopScreenBleed`),
    /// so a ring flush with the edge loses its top arc; 6pt keeps the outer
    /// rings clear of the island's top and bottom edges.
    private var islandVerticalPadding: CGFloat { 6 }

    private var displayHeight: CGFloat {
        CGFloat(rowCount) * rowHeight
            + CGFloat(max(0, rowCount - 1)) * rowSpacing
            + islandVerticalPadding * 2
    }

    var body: some View {
        VStack(spacing: rowSpacing) {
            if showsPi {
                piRow
                    .frame(width: displayWidth, alignment: .leading)
            }
            if showsCodex {
                codexRow
                    .frame(width: displayWidth, alignment: .leading)
            }
            if showsClaude {
                claudeRow
                    .frame(width: displayWidth, alignment: .leading)
            }
        }
        .padding(.vertical, islandVerticalPadding)
        .frame(width: displayWidth, height: displayHeight, alignment: .center)
        .background(Rectangle().fill(.black))
        .frame(height: displayHeight, alignment: .center)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.18)) {
                isHovering = hovering
            }
        }
        .onAppear {
            syncPi(piMonitor.phase)
            syncCodex(codexMonitor.phase)
            syncClaude(claudeMonitor.phase)
            withAnimation(.smooth(duration: 0.35)) {
                expanded = true
            }
        }
        .onChange(of: piMonitor.phase) { _, newPhase in
            syncPi(newPhase)
        }
        .onChange(of: codexMonitor.phase) { _, newPhase in
            syncCodex(newPhase)
        }
        .onChange(of: claudeMonitor.phase) { _, newPhase in
            syncClaude(newPhase)
        }
        .animation(.smooth(duration: 0.35), value: displayWidth)
    }

    // MARK: - Row state

    private func syncPi(_ newPhase: PiActivityPhase) {
        switch newPhase {
        case .running:
            withAnimation(.smooth(duration: 0.3)) { piSpinning = true }
            piCheckProgress = 0
        case .completed:
            withAnimation(.smooth(duration: 0.3)) { piSpinning = false }
            piCheckProgress = 0
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                piCheckProgress = 1
            }
        case .idle:
            break
        }
    }

    private func syncCodex(_ newPhase: CodexActivityPhase) {
        switch newPhase {
        case .running:
            withAnimation(.smooth(duration: 0.3)) { codexSpinning = true }
            codexCheckProgress = 0
        case .completed:
            withAnimation(.smooth(duration: 0.3)) { codexSpinning = false }
            codexCheckProgress = 0
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                codexCheckProgress = 1
            }
        case .idle:
            break
        }
    }

    private func syncClaude(_ newPhase: ClaudeActivityPhase) {
        switch newPhase {
        case .running:
            withAnimation(.smooth(duration: 0.3)) { claudeSpinning = true }
            claudeCheckProgress = 0
        case .completed:
            withAnimation(.smooth(duration: 0.3)) { claudeSpinning = false }
            claudeCheckProgress = 0
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                claudeCheckProgress = 1
            }
        case .idle:
            break
        }
    }

    // MARK: - Rows

    private var piRow: some View {
        HStack(spacing: 0) {
            ringView(
                isCompleted: piIsCompleted,
                spinning: piSpinning,
                iconSize: piIconSize,
                icon: Image("PiText")
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(.white)
                    .aspectRatio(contentMode: .fit)
            )
            .padding(.leading, ringLeadingInset)

            rowModel(model: piMonitor.model, color: .white.opacity(0.85))
                .padding(.leading, 14)

            rowThinking(level: piMonitor.thinkingLevel, color: piThinkingColor(piMonitor.thinkingLevel))
                .padding(.leading, 6)

            rowHitRate(piMonitor.detail?.cacheHitRate)

            elapsedOrCheckmark(
                started: piStarted,
                frozenTime: piFrozenTime,
                showCheck: piIsCompleted,
                checkProgress: piCheckProgress
            )
            .padding(.leading, 4)
        }
        .frame(height: rowHeight, alignment: .center)
    }

    private var codexRow: some View {
        HStack(spacing: 0) {
            ringView(
                isCompleted: codexIsCompleted,
                spinning: codexSpinning,
                iconSize: codexIconSize,
                icon: Image("CodexIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            )
            .padding(.leading, ringLeadingInset)

            rowModel(model: codexMonitor.model, color: .white.opacity(0.85))
                .padding(.leading, 14)

            rowThinking(level: codexMonitor.thinkingLevel, color: codexThinkingColor(codexMonitor.thinkingLevel))
                .padding(.leading, 6)

            rowHitRate(codexMonitor.usage?.cacheHitRate)

            elapsedOrCheckmark(
                started: codexStarted,
                frozenTime: codexFrozenTime,
                showCheck: codexIsCompleted,
                checkProgress: codexCheckProgress
            )
            .padding(.leading, 4)
        }
        .frame(height: rowHeight, alignment: .center)
    }

    private var claudeRow: some View {
        HStack(spacing: 0) {
            ringView(
                isCompleted: claudeIsCompleted,
                spinning: claudeSpinning,
                iconSize: claudeIconSize,
                icon: Image("ClaudeIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            )
            .padding(.leading, ringLeadingInset)

            rowModel(model: claudeMonitor.model, color: .white.opacity(0.85))
                .padding(.leading, 14)

            rowThinking(level: claudeMonitor.thinkingLevel, color: claudeThinkingColor(claudeMonitor.thinkingLevel))
                .padding(.leading, 6)

            rowHitRate(claudeMonitor.usage?.cacheHitRate)

            elapsedOrCheckmark(
                started: claudeStarted,
                frozenTime: claudeFrozenTime,
                showCheck: claudeIsCompleted,
                checkProgress: claudeCheckProgress
            )
            .padding(.leading, 4)
        }
        .frame(height: rowHeight, alignment: .center)
    }

    // MARK: - Shared row pieces

    @ViewBuilder
    private func ringView<Icon: View>(isCompleted: Bool, spinning: Bool, iconSize: CGFloat, icon: Icon) -> some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.55), lineWidth: ringStrokeWidth)
                .frame(width: ringDiameter, height: ringDiameter)

            if isCompleted {
                Circle()
                    .trim(from: 0, to: 1)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: ringStrokeWidth, lineCap: .round))
                    .frame(width: ringDiameter, height: ringDiameter)
                    .transition(.opacity)
            } else {
                Circle()
                    .stroke(Color.white, lineWidth: ringStrokeWidth)
                    .frame(width: ringDiameter, height: ringDiameter)
                    // Breathing, not a gap: the circle stays complete at every frame.
                    .opacity(spinning ? 0.35 : 1.0)
                    .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: spinning)
                    .transition(.opacity)
            }

            icon
                .frame(width: iconSize, height: iconSize)
        }
        .animation(.smooth(duration: 0.3), value: isCompleted)
        .frame(width: ringDiameter, height: ringDiameter)
    }

    private var piIconSize: CGFloat {
        let inner = ringDiameter - ringStrokeWidth * 2
        return max((inner / 2 - 1) * 2 * 0.7071, 4)
    }

    /// The codex cloud artwork fills ~70% of its canvas vs. the pi glyph's
    /// ~92%, so its box needs a 1.31x compensation to render the same visual
    /// size.
    private var codexIconSize: CGFloat {
        piIconSize * 1.31
    }

    private var claudeIconSize: CGFloat {
        piIconSize
    }

    @ViewBuilder
    private func rowModel(model: String?, color: Color) -> some View {
        if let model {
            MarqueeText(
                .constant(model),
                textColor: color,
                minDuration: 0.4,
                frameWidth: modelFrameWidth
            )
            .frame(width: modelFrameWidth, alignment: .leading)
            .clipped()
            .help(model)
        }
    }

    @ViewBuilder
    private func rowThinking(level: String?, color: Color) -> some View {
        if let level {
            Text(level)
                .font(.body)
                .foregroundStyle(color)
                .lineLimit(1)
                .frame(width: thinkingColumnWidth, alignment: .leading)
                .help("Thinking level: \(level)")
        }
    }

    /// Cache hit rate cell (pi only; other rows keep it blank for alignment).
    @ViewBuilder
    private func rowHitRate(_ hit: Double?) -> some View {
        if showsHitRateColumn {
            Group {
                if let hit {
                    Text(CLIUsage.percentText(hit))
                        .foregroundStyle(.white.opacity(0.8))
                        .help("Cache hit rate")
                } else {
                    Color.clear
                }
            }
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .frame(width: hitRateColumnWidth, alignment: .trailing)
            .padding(.leading, 8)
        }
    }

    @ViewBuilder
    private func elapsedOrCheckmark(started: Date?, frozenTime: String?, showCheck: Bool, checkProgress: CGFloat) -> some View {
        if let started {
            TimelineView(.periodic(from: started, by: 1)) { context in
                Text(PiLiveActivity.formatElapsed(context.date.timeIntervalSince(started)))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: elapsedTextWidth, alignment: .leading)
            }
        } else if let frozenTime {
            Text(frozenTime)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: elapsedTextWidth, alignment: .leading)
        }

        if showCheck {
            ZStack {
                Circle()
                    .stroke(Color.green, lineWidth: 2)
                CheckmarkShape()
                    .trim(from: 0, to: checkProgress)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            .frame(width: checkmarkSize, height: checkmarkSize)
            .padding(.leading, 3)
        }
    }

    // MARK: - pi accessors

    private var piIsCompleted: Bool {
        if case .completed = piMonitor.phase { return true }
        return false
    }

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

    // MARK: - codex accessors

    private var codexIsCompleted: Bool {
        if case .completed = codexMonitor.phase { return true }
        return false
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

    // MARK: - claude accessors

    private var claudeIsCompleted: Bool {
        if case .completed = claudeMonitor.phase { return true }
        return false
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

    // MARK: - Palettes (mirror the single-activity views)

    private func piThinkingColor(_ level: String?) -> Color {
        switch level {
        case "minimal":
            return Color(red: 0x64 / 255.0, green: 0xD2 / 255.0, blue: 0xFF / 255.0)
        case "low":
            return Color(red: 0x5E / 255.0, green: 0x5C / 255.0, blue: 0xE6 / 255.0)
        case "medium":
            return Color(red: 0xBF / 255.0, green: 0x5A / 255.0, blue: 0xF2 / 255.0)
        case "high", "max":
            return Color(red: 0xFF / 255.0, green: 0x9F / 255.0, blue: 0x0A / 255.0)
        default:
            return Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0)
        }
    }

    private func codexThinkingColor(_ level: String?) -> Color {
        switch level {
        case "medium":
            return Color(red: 0x64 / 255.0, green: 0xD2 / 255.0, blue: 0xFF / 255.0)
        case "high":
            return Color(red: 0x5E / 255.0, green: 0x5C / 255.0, blue: 0xE6 / 255.0)
        case "xhigh":
            return Color(red: 0xFF / 255.0, green: 0x9F / 255.0, blue: 0x0A / 255.0)
        default:
            return Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0)
        }
    }

    private func claudeThinkingColor(_ level: String?) -> Color {
        switch level {
        case "medium":
            return Color(red: 0x64 / 255.0, green: 0xD2 / 255.0, blue: 0xFF / 255.0)
        case "high":
            return Color(red: 0x5E / 255.0, green: 0x5C / 255.0, blue: 0xE6 / 255.0)
        case "max", "xhigh":
            return Color(red: 0xFF / 255.0, green: 0x9F / 255.0, blue: 0x0A / 255.0)
        default:
            return Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0)
        }
    }
}
