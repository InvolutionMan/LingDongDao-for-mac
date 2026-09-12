/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import XCTest
@testable import Atoll

/// DSH keeps its own ledger; the provider only has to bucket it by day.
final class DstUsageTests: XCTestCase {

    private let now = ISO8601DateFormatter().date(from: "2026-09-12T12:00:00Z")!

    private func ledger(_ days: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["version": 1, "days": days])
    }

    private func entry(input: Int, output: Int, cost: Double) -> [String: Any] {
        ["inputTokens": input, "outputTokens": output, "cacheReadTokens": 1000,
         "cacheWriteTokens": 0, "reasoningTokens": 10, "calls": 2, "cost": cost]
    }

    func testTodayAndWeekAreBucketedFromTheLedger() throws {
        let data = ledger([
            "2026-09-12": ["deepseek-official": ["deepseek-v4-flash": entry(input: 100, output: 50, cost: 1.5)]],
            "2026-09-10": ["deepseek-official": ["deepseek-v4-pro": entry(input: 200, output: 100, cost: 2.5)]],
            "2026-09-01": ["deepseek-official": ["deepseek-v4-pro": entry(input: 9999, output: 9999, cost: 99)]],
        ])

        let snapshot = try XCTUnwrap(DstUsageProvider.snapshot(fromLedger: data, now: now))
        XCTAssertEqual(snapshot.today.totalTokens, 150)
        XCTAssertEqual(snapshot.today.costUSD, 1.5, accuracy: 0.0001)
        // 12th + 10th are inside the seven-day window, the 1st is not.
        XCTAssertEqual(snapshot.week.totalTokens, 450)
        XCTAssertEqual(snapshot.week.costUSD, 4.0, accuracy: 0.0001)
        XCTAssertEqual(snapshot.session.totalTokens, snapshot.today.totalTokens,
                       "the ledger knows days, not sessions")
        XCTAssertEqual(snapshot.models.map(\.model).sorted(), ["deepseek-v4-flash", "deepseek-v4-pro"])
    }

    func testModelsAreSummedAcrossProvidersAndSortedBySize() throws {
        let data = ledger([
            "2026-09-12": [
                "deepseek-official": ["deepseek-v4-flash": entry(input: 10, output: 10, cost: 0.1)],
                "other": ["deepseek-v4-flash": entry(input: 90, output: 90, cost: 0.9)],
            ],
            "2026-09-11": ["deepseek-official": ["deepseek-v4-pro": entry(input: 1000, output: 1000, cost: 5)]],
        ])

        let snapshot = try XCTUnwrap(DstUsageProvider.snapshot(fromLedger: data, now: now))
        XCTAssertEqual(snapshot.models.first?.model, "deepseek-v4-pro", "biggest total first")
        let flash = snapshot.models.first { $0.model == "deepseek-v4-flash" }
        XCTAssertEqual(flash?.totals.totalTokens, 200, "the same model adds up across providers")
    }

    func testEmptyOrBrokenLedgerIsRejected() {
        XCTAssertNil(DstUsageProvider.snapshot(fromLedger: Data("{}".utf8), now: now))
        XCTAssertNil(DstUsageProvider.snapshot(fromLedger: Data("not json".utf8), now: now))
        XCTAssertNil(DstUsageProvider.snapshot(fromLedger: ledger([:]), now: now))
    }

    func testProviderReportsMissingLedgerAsNotFound() async {
        let provider = DstUsageProvider(ledger: URL(fileURLWithPath: "/tmp/atoll-no-such-ledger.json"))
        do {
            _ = try await provider.fetchSnapshot(now: now)
            XCTFail("expected a notFound failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not detected"), error.localizedDescription)
        }
    }

    func testProviderIDIsWiredIntoTheUsageTab() {
        XCTAssertTrue(ProviderID.allCases.contains(.dst))
        XCTAssertEqual(ProviderID.dst.displayName, "DSH (dst)")
        XCTAssertEqual(ProviderID.dst.enabledKey, .enableDstProvider)
    }
}
