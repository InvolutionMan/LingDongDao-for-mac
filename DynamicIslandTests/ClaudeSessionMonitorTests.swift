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

final class ClaudeSessionMonitorTests: XCTestCase {

    private func assistantLine(stopReason: String, model: String = "claude-sonnet-4-5") -> String {
        """
        {"type":"assistant","uuid":"a1","message":{"id":"m1","role":"assistant","model":"\(model)","content":[{"type":"text","text":"hi"}],"stop_reason":"\(stopReason)"}}
        """
    }

    private func promptLine(_ text: String = "fix the bug") -> String {
        """
        {"type":"user","uuid":"u1","message":{"role":"user","content":"\(text)"}}
        """
    }

    private func toolResultLine() -> String {
        """
        {"type":"user","uuid":"u2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}
        """
    }

    private func localCommandLine() -> String {
        """
        {"type":"user","uuid":"u3","message":{"role":"user","content":"<local-command-stdout>Set model to deepseek-v4-flash</local-command-stdout>"}}
        """
    }

    private func costStateLine() -> String {
        """
        {"type":"cost-state","sessionId":"s1","totalCostUSD":0,"modelUsage":{}}
        """
    }

    private func fileHistoryLine() -> String {
        """
        {"type":"file-history-snapshot","messageId":"m1","snapshot":{}}
        """
    }

    func testAssistantToolUseTailIsBusy() {
        let tail = promptLine() + "\n" + assistantLine(stopReason: "tool_use") + "\n"
        XCTAssertEqual(ClaudeSessionTail.state(fromTail: tail), .busy)
    }

    func testAssistantEndTurnTailIsIdle() {
        let tail = promptLine() + "\n" + assistantLine(stopReason: "end_turn") + "\n"
        XCTAssertEqual(ClaudeSessionTail.state(fromTail: tail), .idle)
    }

    func testPromptTailIsBusy() {
        let tail = assistantLine(stopReason: "end_turn") + "\n" + promptLine() + "\n"
        XCTAssertEqual(ClaudeSessionTail.state(fromTail: tail), .busy)
    }

    func testToolResultTailIsBusy() {
        let tail = assistantLine(stopReason: "tool_use") + "\n" + toolResultLine() + "\n"
        XCTAssertEqual(ClaudeSessionTail.state(fromTail: tail), .busy)
    }

    func testLocalCommandRecordsAreNeutral() {
        // `/model`-style local output is not a turn; classification falls back
        // to the previous assistant record.
        let tail = assistantLine(stopReason: "end_turn") + "\n" + localCommandLine() + "\n"
        XCTAssertEqual(ClaudeSessionTail.state(fromTail: tail), .idle)
    }

    func testNeutralTrailingRecordsDoNotResurrectBusy() {
        let tail = promptLine() + "\n"
            + assistantLine(stopReason: "tool_use") + "\n"
            + toolResultLine() + "\n"
            + assistantLine(stopReason: "end_turn") + "\n"
            + costStateLine() + "\n"
            + fileHistoryLine() + "\n"
        XCTAssertEqual(ClaudeSessionTail.state(fromTail: tail), .idle)
    }

    func testPartialTrailingLineFallsBackToPreviousRecord() {
        let complete = assistantLine(stopReason: "end_turn") + "\n"
        let truncated = "{\"type\":\"assistant\",\"uuid\":\"a9\",\"message\":{\"role\":\"assist"
        XCTAssertEqual(ClaudeSessionTail.state(fromTail: complete + truncated), .idle)

        let busyComplete = assistantLine(stopReason: "tool_use") + "\n"
        XCTAssertEqual(ClaudeSessionTail.state(fromTail: busyComplete + truncated), .busy)
    }

    func testEmptyAndGarbageTailsAreUnknown() {
        XCTAssertEqual(ClaudeSessionTail.state(fromTail: ""), .unknown)
        XCTAssertEqual(ClaudeSessionTail.state(fromTail: "not json\nstill not json"), .unknown)
    }

    func testModelFromAssistantRecord() {
        let tail = promptLine() + "\n" + assistantLine(stopReason: "end_turn", model: "claude-opus-4-6") + "\n"
        XCTAssertEqual(ClaudeSessionTail.model(fromTail: tail), "claude-opus-4-6")
    }

    func testModelPrefersLatestAssistantRecord() {
        let tail = assistantLine(stopReason: "end_turn", model: "claude-sonnet-4-5") + "\n"
            + assistantLine(stopReason: "end_turn", model: "claude-opus-4-6") + "\n"
        XCTAssertEqual(ClaudeSessionTail.model(fromTail: tail), "claude-opus-4-6")
    }

    func testModelNilWithoutAssistantRecords() {
        XCTAssertNil(ClaudeSessionTail.model(fromTail: ""))
        XCTAssertNil(ClaudeSessionTail.model(fromTail: promptLine() + "\n"))
    }

    // MARK: - Token usage (cache hit rate)

    private func assistantUsageLine(
        input: Int,
        cacheRead: Int,
        cacheCreation: Int,
        output: Int,
        model: String = "MiniMax-M2.7"
    ) -> String {
        """
        {"type":"assistant","uuid":"a9","message":{"id":"m9","role":"assistant","model":"\(model)","content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn","usage":{"input_tokens":\(input),"cache_creation_input_tokens":\(cacheCreation),"cache_read_input_tokens":\(cacheRead),"output_tokens":\(output)}}}
        """
    }

    func testUsageFromAssistantMessage() {
        let tail = promptLine() + "\n" + assistantUsageLine(input: 20474, cacheRead: 7808, cacheCreation: 1000, output: 276) + "\n"
        let usage = ClaudeSessionTail.usage(fromTail: tail)

        XCTAssertEqual(usage?.inputTokens, 20474)
        XCTAssertEqual(usage?.cacheReadTokens, 7808)
        XCTAssertEqual(usage?.cacheWriteTokens, 1000)
        XCTAssertEqual(usage?.outputTokens, 276)
        XCTAssertEqual(usage?.totalTokens, 20474 + 7808 + 1000 + 276)
        // Claude's input_tokens excludes the cached parts, so the prompt is the sum.
        XCTAssertEqual(usage?.cacheHitRate ?? 0, 7808.0 / (20474 + 7808 + 1000), accuracy: 0.0001)
        XCTAssertEqual(CLIUsage.percentText(usage?.cacheHitRate ?? 0), "27%")
    }

    func testUsagePrefersLatestAssistantMessage() {
        let tail = assistantUsageLine(input: 10, cacheRead: 100, cacheCreation: 0, output: 1) + "\n"
            + assistantUsageLine(input: 20474, cacheRead: 7808, cacheCreation: 0, output: 276) + "\n"
        XCTAssertEqual(ClaudeSessionTail.usage(fromTail: tail)?.inputTokens, 20474)
    }

    func testUsageNilWithoutAssistantRecords() {
        XCTAssertNil(ClaudeSessionTail.usage(fromTail: promptLine() + "\n"))
        XCTAssertNil(ClaudeSessionTail.usage(fromTail: assistantLine(stopReason: "end_turn") + "\n"))
        XCTAssertNil(ClaudeSessionTail.usage(fromTail: ""))
    }

    func testUsageHitRateNilWhenNothingCached() {
        let tail = assistantUsageLine(input: 20474, cacheRead: 0, cacheCreation: 0, output: 276) + "\n"
        XCTAssertNil(ClaudeSessionTail.usage(fromTail: tail)?.cacheHitRate)
    }

    // MARK: - Hook tool activity

    func testActivityFromHookStatusFile() {
        let obj: [String: Any] = [
            "busy": true,
            "since": 1_700_000_000_000,
            "tool": ["name": "read", "target": "Sources/main.swift", "pending": true],
            "tasks": [
                ["id": "t1", "name": "read", "target": "Sources/main.swift", "state": "running"],
                ["id": "t2", "name": "bash", "target": "swift test", "state": "completed"],
            ],
        ]
        let activity = CLIToolActivity.from(status: obj)

        XCTAssertEqual(activity?.toolName, "read")
        XCTAssertEqual(activity?.toolTarget, "Sources/main.swift")
        XCTAssertEqual(activity?.toolIsPending, true)
        XCTAssertEqual(activity?.tasks.count, 2)
        XCTAssertEqual(activity?.tasks.first?.state, .running)
        XCTAssertEqual(activity?.tasks.last?.state, .completed)
        XCTAssertEqual(activity?.current?.name, "read")
        XCTAssertEqual(activity?.current?.isRunning, true)
    }

    func testActivityPrefersRunningTaskOverLastTool() {
        let obj: [String: Any] = [
            "tool": ["name": "bash", "target": "swift test", "pending": false],
            "tasks": [
                ["id": "t1", "name": "grep", "target": "activityLabel", "state": "running"],
                ["id": "t2", "name": "bash", "target": "swift test", "state": "completed"],
            ],
        ]
        let activity = CLIToolActivity.from(status: obj)
        XCTAssertEqual(activity?.current?.name, "grep")
        XCTAssertEqual(activity?.current?.isRunning, true)
    }

    func testActivityFallsBackToToolWhenNothingRuns() {
        let obj: [String: Any] = [
            "tool": ["name": "todo", "target": "Testing the hook", "pending": false],
            "tasks": [["id": "t1", "name": "todo", "target": "Testing the hook", "state": "completed"]],
        ]
        let activity = CLIToolActivity.from(status: obj)
        XCTAssertEqual(activity?.current?.name, "todo")
        XCTAssertEqual(activity?.current?.target, "Testing the hook")
        XCTAssertEqual(activity?.current?.isRunning, false)
    }

    func testActivityNilWithoutToolData() {
        XCTAssertNil(CLIToolActivity.from(status: ["busy": false, "since": 1]))
        XCTAssertNil(CLIToolActivity.from(status: ["tasks": [["state": "running"]]]))
    }

    func testFormatElapsed() {
        XCTAssertEqual(ClaudeLiveActivity.formatElapsed(0), "00:00")
        XCTAssertEqual(ClaudeLiveActivity.formatElapsed(65), "01:05")
        XCTAssertEqual(ClaudeLiveActivity.formatElapsed(600), "10:00")
        XCTAssertEqual(ClaudeLiveActivity.formatElapsed(3671), "1:01:11")
        XCTAssertEqual(ClaudeLiveActivity.formatElapsed(-5), "00:00")
    }
}
