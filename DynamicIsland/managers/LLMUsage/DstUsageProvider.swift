import Foundation

/// Token usage of the DSH CLI (`dst`).
///
/// DSH keeps its own ledger at `~/.dsh/dsh-usage/usage-ledger.json` — one entry
/// per day, provider and model, with token counts and the cost it computed — so
/// there is no need to decompress any session file (they are zstd, and can be
/// tens of megabytes each).
///
/// The ledger is bucketed per *day*, not per session, so the "session" figure is
/// the same as today's; `today` and `week` are exact.
struct DstUsageProvider: UsageProvider {
    let id: ProviderID = .dst
    let ledger: URL

    init(ledger: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".dsh/dsh-usage/usage-ledger.json")) {
        self.ledger = ledger
    }

    func fetchSnapshot(now: Date) async throws -> UsageSnapshot {
        guard FileManager.default.fileExists(atPath: ledger.path) else {
            throw UsageError.notFound("No ~/.dsh/dsh-usage/usage-ledger.json — DSH not detected")
        }
        let data = try Data(contentsOf: ledger)
        guard let snapshot = Self.snapshot(fromLedger: data, now: now) else {
            throw UsageError.notFound("DSH's usage ledger is empty")
        }
        return snapshot
    }

    /// Pure so the parsing can be tested without a live ledger.
    static func snapshot(fromLedger data: Data, now: Date) -> UsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let days = root["days"] as? [String: [String: [String: [String: Any]]]],
              !days.isEmpty else { return nil }

        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        let todayKey = formatter.string(from: now)
        let weekStart = calendar.startOfDay(for: now.addingTimeInterval(-6 * 86_400))

        var today = UsageTotals()
        var week = UsageTotals()
        var perModel: [String: UsageTotals] = [:]

        for (day, providers) in days {
            guard let date = formatter.date(from: day) else { continue }
            let isToday = day == todayKey
            let inWeek = date >= weekStart
            guard isToday || inWeek else { continue }

            for models in providers.values {
                for (model, totals) in models {
                    let entry = Self.totals(from: totals)
                    if isToday { Self.add(entry, to: &today) }
                    if inWeek {
                        Self.add(entry, to: &week)
                        var modelTotals = perModel[model] ?? UsageTotals()
                        Self.add(entry, to: &modelTotals)
                        perModel[model] = modelTotals
                    }
                }
            }
        }

        var snapshot = UsageSnapshot()
        snapshot.today = today
        // The ledger knows days, not sessions; today is the closest honest answer.
        snapshot.session = today
        snapshot.week = week
        snapshot.models = perModel
            .map { ModelUsage(model: $0.key, totals: $0.value) }
            .sorted { $0.totals.totalTokens > $1.totals.totalTokens }
        snapshot.lastUpdated = now
        return snapshot
    }

    private static func totals(from object: [String: Any]) -> UsageTotals {
        var totals = UsageTotals()
        totals.inputTokens = (object["inputTokens"] as? NSNumber)?.intValue ?? 0
        totals.outputTokens = (object["outputTokens"] as? NSNumber)?.intValue ?? 0
        totals.costUSD = (object["cost"] as? NSNumber)?.doubleValue ?? 0
        return totals
    }

    private static func add(_ entry: UsageTotals, to totals: inout UsageTotals) {
        totals.inputTokens += entry.inputTokens
        totals.outputTokens += entry.outputTokens
        totals.costUSD += entry.costUSD
        totals.hasUnpricedModel = totals.hasUnpricedModel || entry.hasUnpricedModel
    }
}
