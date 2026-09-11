import SwiftUI
import Defaults
#if canImport(AppKit)
import AppKit
#endif

/// Closed-notch live activity shown while the Claude Code CLI is executing a
/// task. While running, the island stretches from the closed pill width to fit
/// the model marquee, the effort-level text and the elapsed time. When the task
/// finishes, the elapsed counter swaps for a stroke-drawn checkmark for a beat
/// before the activity fades out.
struct ClaudeLiveActivity: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject var claudeMonitor = ClaudeSessionMonitor.shared
    @State private var isHovering: Bool = false
    @State private var expanded: Bool = false
    @State private var spinning: Bool = false
    @State private var checkProgress: CGFloat = 0
    @State private var fadingOut: Bool = false

    private var phase: ClaudeActivityPhase { claudeMonitor.phase }
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

    /// Claude sunburst glyph box: a square inscribed in the ring's inner circle.
    private var iconSize: CGFloat {
        let inner = ringDiameter - ringStrokeWidth * 2
        return max((inner / 2 - 1) * 2 * 0.7071, 4)
    }

    /// Keeps the ring clear of the island's rounded corners: the closed pill is
    /// a capsule whose corner radius is `max(pillHeight/2, 16)`, so the ring
    /// must sit further right than that or its arc gets clipped.
    private var ringLeadingInset: CGFloat {
        max(vm.closedNotchSize.height / 2 + 6, 24)
    }

    private var elapsedTextWidth: CGFloat { 56 }
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
    private var hasHitRate: Bool { claudeMonitor.usage?.cacheHitRate != nil }

    private var thinkingMeasureFont: NSFont { .systemFont(ofSize: 13, weight: .regular) }

    private func measureTextWidth(_ text: String, font: NSFont) -> CGFloat {
        CGFloat(ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width))
    }

    private var hasModel: Bool { claudeMonitor.model != nil }

    private var thinkingTextWidth: CGFloat {
        guard let level = claudeMonitor.thinkingLevel else { return 0 }
        return measureTextWidth(level, font: thinkingMeasureFont)
    }

    private var fullContentWidth: CGFloat {
        ringLeadingInset + ringDiameter
            + (hasModel ? 14 + modelFrameWidth + 8 : 0)
            + (thinkingTextWidth > 0 ? 6 + thinkingTextWidth : 0)
            + (hasHitRate ? 8 + hitRateWidth : 0)
            + 8 + elapsedTextWidth
            + (isCompleted ? 3 + checkmarkSize : 0)
            + 8
    }

    private var displayWidth: CGFloat {
        let base = vm.closedNotchSize.width + (isHovering ? 8 : 0)
        return expanded ? max(base, fullContentWidth) : base
    }

    var body: some View {
        Rectangle()
            .fill(.black)
            .frame(width: displayWidth, height: notchContentHeight)
            .overlay(alignment: .leading) {
                HStack(spacing: 0) {
                    leadingRingView

                    if let model = claudeMonitor.model {
                        // Music-island marquee: scrolls when the model id is
                        // longer than its frame; clipped so the scrolling copy
                        // never covers the ring/logo.
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

                    if let level = claudeMonitor.thinkingLevel {
                        Text(level)
                            .font(thinkingFont)
                            .foregroundStyle(thinkingColor(for: level))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.leading, 6)
                            .help("Effort level: \(level)")
                            .transition(.opacity)
                    }

                    if let hit = claudeMonitor.usage?.cacheHitRate {
                        Text(CLIUsage.percentText(hit))
                            .font(hitRateFont)
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: hitRateWidth, alignment: .center)
                            .padding(.leading, 8)
                            .contentTransition(.numericText())
                            .help("Cache hit rate")
                            .transition(.opacity)
                    }

                    switch phase {
                    case .running(let started):
                        TimelineView(.periodic(from: started, by: 1)) { context in
                            Text(ClaudeLiveActivity.formatElapsed(context.date.timeIntervalSince(started)))
                                .font(elapsedFont)
                                .foregroundStyle(.white)
                                .frame(width: elapsedTextWidth, alignment: .leading)
                                .contentTransition(.numericText())
                        }
                        .padding(.leading, 8)
                        .transition(.opacity)
                    case .completed(let at, let startedAt):
                        if let startedAt {
                            Text(ClaudeLiveActivity.formatElapsed(at.timeIntervalSince(startedAt)))
                                .font(elapsedFont)
                                .foregroundStyle(.white)
                                .frame(width: elapsedTextWidth, alignment: .leading)
                                .padding(.leading, 8)
                                .transition(.opacity)
                        }

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
                    case .idle:
                        EmptyView()
                    }
                }
                .frame(height: notchContentHeight, alignment: .center)
                .animation(.smooth(duration: 0.3), value: phase)
            }
            .animation(.smooth(duration: 0.35), value: displayWidth)
            .frame(height: vm.effectiveClosedNotchHeight + (isHovering ? 8 : 0), alignment: .center)
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

    /// Ring + Claude sunburst, clear of the pill's rounded corners.
    private var leadingRingView: some View {
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

            Image("ClaudeIcon")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)
        }
        .animation(.smooth(duration: 0.3), value: isCompleted)
        .frame(height: notchContentHeight, alignment: .center)
        .padding(.leading, ringLeadingInset)
    }

    /// Effort level (Claude Code's thinking degree) as text — low / medium /
    /// high / max — tinted by strength so the current level reads at a glance.
    private func thinkingColor(for level: String) -> Color {
        switch level {
        case "medium":
            return Color(red: 0x64 / 255.0, green: 0xD2 / 255.0, blue: 0xFF / 255.0)
        case "high":
            return Color(red: 0x5E / 255.0, green: 0x5C / 255.0, blue: 0xE6 / 255.0)
        case "max", "xhigh":
            return Color(red: 0xFF / 255.0, green: 0x9F / 255.0, blue: 0x0A / 255.0)
        default: // low / unknown
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

/// Compact right-wing supplement shown beside the music live activity while
/// Claude Code is executing a task (mirrors `PiMusicSupplementView`).
struct ClaudeMusicSupplementView: View {
    @ObservedObject var monitor: ClaudeSessionMonitor
    let notchHeight: CGFloat

    @State private var spinning = false
    @State private var checkProgress: CGFloat = 0

    private var phase: ClaudeActivityPhase { monitor.phase }
    private var isCompleted: Bool {
        if case .completed = phase { return true }
        return false
    }

    private var ringDiameter: CGFloat {
        max(min(notchHeight - 8, 20), 16)
    }

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 2.5)
                    .frame(width: ringDiameter, height: ringDiameter)

                if isCompleted {
                    Circle()
                        .trim(from: 0, to: 1)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: ringDiameter, height: ringDiameter)
                        .transition(.opacity)
                } else {
                    Circle()
                        .stroke(Color.white, lineWidth: 2.5)
                        .frame(width: ringDiameter, height: ringDiameter)
                        .opacity(spinning ? 0.35 : 1.0)
                        .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: spinning)
                        .transition(.opacity)
                }

                Image("ClaudeIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: max(ringDiameter * 0.55, 8), height: max(ringDiameter * 0.55, 8))
            }
            .animation(.smooth(duration: 0.3), value: isCompleted)

            Text("Claude")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)

            switch phase {
            case .running(let started):
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text(ClaudeLiveActivity.formatElapsed(context.date.timeIntervalSince(started)))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .contentTransition(.numericText())
                }
                .transition(.opacity)
            case .completed:
                ZStack {
                    Circle()
                        .stroke(Color.green, lineWidth: 2.5)
                    CheckmarkShape()
                        .trim(from: 0, to: checkProgress)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
                .frame(width: 18, height: 18)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            case .idle:
                EmptyView()
            }
        }
        .padding(.trailing, 2)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onAppear { spinning = !isCompleted }
        .onChange(of: phase) { _, newPhase in
            switch newPhase {
            case .running:
                withAnimation(.smooth(duration: 0.3)) { spinning = true }
                checkProgress = 0
            case .completed:
                withAnimation(.smooth(duration: 0.3)) { spinning = false }
                checkProgress = 0
                withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                    checkProgress = 1
                }
            case .idle:
                break
            }
        }
    }
}
