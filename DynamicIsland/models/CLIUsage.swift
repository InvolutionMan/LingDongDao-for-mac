import Foundation

/// Token usage of a CLI agent's most recent model call.
///
/// Shared by the pi / Codex / Claude live activities so their cache-hit
/// readouts mean the same thing: the fraction of this call's prompt tokens that
/// the provider served from its prompt cache. Providers report the prompt
/// differently, so each monitor normalises into this shape first:
///
/// - pi: `input` already excludes `cacheRead`.
/// - Codex: `input_tokens` *includes* `cached_input_tokens`, so the monitor
///   subtracts it.
/// - Claude: `input_tokens` excludes `cache_read` / `cache_creation`.
struct CLIUsage: Equatable {
    /// Prompt tokens that were not served from cache.
    var inputTokens: Int?
    /// Prompt tokens served from the provider's prompt cache.
    var cacheReadTokens: Int?
    /// Prompt tokens written into the cache on this call (Claude only).
    var cacheWriteTokens: Int?
    var outputTokens: Int?
    /// Provider-reported total, when it reports one (Codex). Otherwise the
    /// components above are summed.
    var reportedTotalTokens: Int?

    var totalTokens: Int {
        if let reportedTotalTokens, reportedTotalTokens > 0 { return reportedTotalTokens }
        return [inputTokens, cacheReadTokens, cacheWriteTokens, outputTokens]
            .compactMap { $0 }
            .reduce(0, +)
    }

    /// Share of the prompt served from cache, `0...1`. Nil when the call had no
    /// prompt tokens or nothing was cached, so the pill can hide the field
    /// instead of showing a meaningless 0%.
    var cacheHitRate: Double? {
        let cached = cacheReadTokens ?? 0
        guard cached > 0 else { return nil }
        let prompt = cached + (inputTokens ?? 0) + (cacheWriteTokens ?? 0)
        guard prompt > 0 else { return nil }
        return Double(cached) / Double(prompt)
    }

    var isEmpty: Bool {
        inputTokens == nil && cacheReadTokens == nil && cacheWriteTokens == nil
            && outputTokens == nil && reportedTotalTokens == nil
    }

    /// `0.9888` → `"99%"` — one shared formatting rule for pill and panel.
    static func percentText(_ rate: Double) -> String {
        "\(Int((rate * 100).rounded()))%"
    }
}
