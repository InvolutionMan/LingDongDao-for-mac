import SwiftUI
import Defaults
#if canImport(AppKit)
import AppKit
#endif

/// Closed-notch live activity shown while the DSH CLI (`dst`) is executing a
/// task — the pi layout fed by `DshSessionMonitor`, which tails DSH's zstd
/// session file instead of a hook.
/// While running, the island stretches from the closed pill width to fit the
/// full model id, the thinking degree text and the elapsed time. When the task
/// finishes, the elapsed counter swaps for a stroke-drawn checkmark for a beat
/// before the activity fades out.
struct DshLiveActivity: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject var dshMonitor = DshSessionMonitor.shared
    @State private var isHovering: Bool = false
    @State private var expanded: Bool = false
    @State private var spinning: Bool = false
    @State private var checkProgress: CGFloat = 0
    @State private var fadingOut: Bool = false

    private var phase: PiActivityPhase { dshMonitor.phase }
    private var isCompleted: Bool {
        if case .completed = phase { return true }
        return false
    }

    private var notchContentHeight: CGFloat {
        max(0, vm.effectiveClosedNotchHeight - (isHovering ? 0 : 12))
    }

    /// Compact ring that fits inside the pill's height (no protrusion).
    private var ringDiameter: CGFloat {
        min(notchContentHeight, 20)
    }

    private var ringStrokeWidth: CGFloat { 2.5 }

    /// π glyph box: a square inscribed in the ring's inner circle, so the
    /// glyph's diagonal stays clear of the stroke inside the compact ring.
    private var iconSize: CGFloat {
        let inner = ringDiameter - ringStrokeWidth * 2
        return max((inner / 2 - 1) * 2 * 0.7071, 4)
    }

    private var elapsedTextWidth: CGFloat { 56 }

    /// Keeps the ring clear of the island's rounded corners: the closed
    /// pill is a capsule whose corner radius is `max(pillHeight/2, 16)`, so
    /// the ring must sit further right than that or its arc gets clipped.
    private var ringLeadingInset: CGFloat {
        max(vm.closedNotchSize.height / 2 + 6, 24)
    }
    private var checkmarkSize: CGFloat { 16 }

    private var modelFrameWidth: CGFloat { 240 }

    /// Typography mirrors the music live activity: the model marquee uses
    /// `.body` (13pt) like the song title; the timer-supplement countdown uses
    /// 13pt monospaced semibold.
    private var thinkingFont: Font { .body }
    private var elapsedFont: Font { .system(size: 13, weight: .semibold, design: .monospaced) }
    private var hitRateFont: Font { .system(size: 13, weight: .semibold, design: .monospaced) }
    /// Fits `100.00%`: the shared readout is precise to two decimals.
    private var hitRateWidth: CGFloat { CLIUsage.percentTextWidth }
    private var hasHitRate: Bool { dshMonitor.detail?.cacheHitRate != nil }

    private var thinkingMeasureFont: NSFont { .systemFont(ofSize: 13, weight: .regular) }

    private func measureTextWidth(_ text: String, font: NSFont) -> CGFloat {
        CGFloat(ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width))
    }

    private var hasModel: Bool { dshMonitor.model != nil }

    private var thinkingTextWidth: CGFloat {
        guard let level = dshMonitor.thinkingLevel else { return 0 }
        return measureTextWidth(level, font: thinkingMeasureFont)
    }

    /// Running/completed width: closed pill, stretched to fit the bounded
    /// model marquee frame, the thinking-degree text and the elapsed counter
    /// (+ checkmark). A too-long model name scrolls inside its frame instead
    /// of stretching the island further.
    private var fullContentWidth: CGFloat {
        ringLeadingInset + ringDiameter
            + (hasModel ? 14 + modelFrameWidth + 8 : 0)
            + (thinkingTextWidth > 0 ? 6 + thinkingTextWidth : 0)
            + (hasHitRate ? 8 + hitRateWidth : 0)
            + 4 + elapsedTextWidth
            + (isCompleted ? 3 + checkmarkSize : 0)
            + 8
    }

    /// The hover detail lives in the open-notch panel (`CLIActivityDetailView`)
    /// now — hovering expands the whole island instead of a small inline card,
    /// so the closed-notch pill stays compact.
    private var showsDetail: Bool { false }
    private var detailPanelHeight: CGFloat { 0 }

    private var displayWidth: CGFloat {
        let base = vm.closedNotchSize.width + (isHovering ? 8 : 0)
        let resolved = expanded ? max(base, fullContentWidth) : base
        return showsDetail ? max(resolved, 430) : resolved
    }

    var body: some View {
        Rectangle()
            .fill(.black)
            .frame(width: displayWidth, height: notchContentHeight + detailPanelHeight)
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    topRowContent
                        .frame(width: displayWidth, height: notchContentHeight, alignment: .center)
                }
                .animation(.smooth(duration: 0.3), value: phase)
            }
            .animation(.smooth(duration: 0.25), value: showsDetail)
            .animation(.smooth(duration: 0.35), value: displayWidth)
            .frame(
                height: vm.effectiveClosedNotchHeight + (isHovering ? 8 : 0) + detailPanelHeight + (showsDetail ? 6 : 0),
                alignment: .center
            )
            .contentShape(Rectangle())
            .opacity(fadingOut ? 0 : 1)
            .onHover { hovering in
                withAnimation(.smooth(duration: 0.18)) {
                    isHovering = hovering
                }
            }
            .onAppear {
                spinning = !isCompleted
                // Stretch from the closed pill to the full content width.
                withAnimation(.smooth(duration: 0.35)) {
                    expanded = true
                }
            }
            .onChange(of: phase) { _, newPhase in
                switch newPhase {
                case .running:
                    withAnimation(.smooth(duration: 0.3)) {
                        spinning = true
                        fadingOut = false
                    }
                    checkProgress = 0
                case .completed:
                    withAnimation(.smooth(duration: 0.3)) {
                        spinning = false
                    }
                    drawCheckmark()
                case .idle:
                    break
                }
            }
    }

    /// The compact row: ring, model, thinking degree, elapsed / checkmark.
    private var topRowContent: some View {
        HStack(spacing: 0) {
                    leadingRingView

                    if let model = dshMonitor.model {
                        // Music-island marquee: scrolls when the model id is
                        // longer than its frame; static otherwise. Clipped so
                        // the scrolling copy never covers the ring/logo.
                        MarqueeText(
                            .constant(model),
                            textColor: .white.opacity(0.85),
                            minDuration: 0.4,
                            frameWidth: modelFrameWidth
                        )
                        .frame(width: modelFrameWidth, alignment: .leading)
                        .clipped()
                        .padding(.leading, 14)
                        .help(model)
                        .transition(.opacity)
                    }

                    if let level = dshMonitor.thinkingLevel {
                        Text(level)
                            .font(thinkingFont)
                            .foregroundStyle(thinkingColor(for: level))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.leading, 6)
                            .help("Thinking level: \(level)")
                            .transition(.opacity)
                    }

                    if let hit = dshMonitor.detail?.cacheHitRate {
                        Text(CLIUsage.percentText(hit))
                            .font(hitRateFont)
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: hitRateWidth, alignment: .trailing)
                            .padding(.leading, 8)
                            .contentTransition(.numericText())
                            .help("Cache hit rate")
                            .transition(.opacity)
                    }

                    switch phase {
                    case .running(let started):
                        TimelineView(.periodic(from: started, by: 1)) { context in
                            Text(PiLiveActivity.formatElapsed(context.date.timeIntervalSince(started)))
                                .font(elapsedFont)
                                .foregroundStyle(.white)
                                .frame(width: elapsedTextWidth, alignment: .leading)
                                .contentTransition(.numericText())
                        }
                        .padding(.leading, 4)
                        .transition(.opacity)
                    case .completed(let at, let startedAt):
                        if let startedAt {
                            Text(PiLiveActivity.formatElapsed(at.timeIntervalSince(startedAt)))
                                .font(elapsedFont)
                                .foregroundStyle(.white)
                                .frame(width: elapsedTextWidth, alignment: .leading)
                                .padding(.leading, 4)
                                .transition(.opacity)
                        }

                        if let error = dshMonitor.detail?.errorMessage {
                            // Provider failure: a red warning replaces the
                            // completion checkmark; the message itself shows in
                            // the expanded detail panel.
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color(red: 0xFF / 255.0, green: 0x45 / 255.0, blue: 0x3A / 255.0))
                                .frame(width: checkmarkSize, height: checkmarkSize)
                                .padding(.leading, 3)
                                .help(error)
                                .transition(.scale(scale: 0.5).combined(with: .opacity))
                        } else {
                            ZStack {
                                Circle()
                                    .stroke(Color.green, lineWidth: 2)
                                CheckmarkShape()
                                    .trim(from: 0, to: checkProgress)
                                    .stroke(Color.green, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            }
                            .frame(width: checkmarkSize, height: checkmarkSize)
                            .padding(.leading, 3)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                        }
                    case .idle:
                        EmptyView()
                    }
                }
        .frame(height: notchContentHeight, alignment: .center)
    }

    /// Hover panel: what pi is reading / running, cache hit rate and tokens.
    private func detailPanel(_ detail: PiLiveDetail) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let name = detail.toolName {
                    Text(name)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.16)))

                    if let target = detail.toolTarget {
                        Text(target)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(target)
                    }

                    if detail.toolIsPending {
                        Circle()
                            .fill(Color.green.opacity(0.9))
                            .frame(width: 5, height: 5)
                            .help("Running")
                    }
                } else {
                    Text(detail.toolIsPending ? "Working…" : "Idle")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            HStack(spacing: 12) {
                if let hit = detail.cacheHitRate {
                    detailStat("Cache", "\(Int((hit * 100).rounded()))%")
                }
                if let total = detail.totalTokens {
                    detailStat("Tokens", PiLiveActivity.formatTokens(total))
                }
                if let input = detail.inputTokens, let output = detail.outputTokens {
                    detailStat("in/out", "\(PiLiveActivity.formatTokens(input))/\(PiLiveActivity.formatTokens(output))")
                }
            }
        }
        .padding(.leading, ringLeadingInset)
        .padding(.trailing, 10)
        .padding(.bottom, 5)
    }

    private func detailStat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.white.opacity(0.45))
            Text(value).foregroundStyle(.white.opacity(0.9))
        }
        .font(.system(size: 11, weight: .medium))
    }

    static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return "\(count)"
    }

    private func drawCheckmark() {
        checkProgress = 0
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
            checkProgress = 1
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            withAnimation(.easeIn(duration: 0.5)) {
                fadingOut = true
            }
        }
    }

    /// Ring + π glyph, flush inside the pill's leading edge.
    private var leadingRingView: some View {
        ZStack {
            // Full ring visible enough to read as a complete circle
            // around the glyph while the bright arc below spins.
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

            Image("DshIcon")
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(.white)
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)
        }
        .animation(.smooth(duration: 0.3), value: isCompleted)
        .frame(height: notchContentHeight, alignment: .center)
        .padding(.leading, ringLeadingInset)
    }

    /// Thinking degree colors (music-island palette):
    /// off #8E8E93 · minimal #64D2FF · low #5E5CE6 · medium #BF5AF2 ·
    /// high/max #FF9F0A. `max` shares the top color; unknown falls back to gray.
    private func thinkingColor(for level: String) -> Color {
        switch level {
        case "minimal":
            return Color(red: 0x64 / 255.0, green: 0xD2 / 255.0, blue: 0xFF / 255.0)
        case "low":
            return Color(red: 0x5E / 255.0, green: 0x5C / 255.0, blue: 0xE6 / 255.0)
        case "medium":
            return Color(red: 0xBF / 255.0, green: 0x5A / 255.0, blue: 0xF2 / 255.0)
        case "high", "xhigh", "max":
            return Color(red: 0xFF / 255.0, green: 0x9F / 255.0, blue: 0x0A / 255.0)
        default: // off / unknown
            return Color(red: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0)
        }
    }

    static func formatElapsed(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}
