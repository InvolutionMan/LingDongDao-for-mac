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

final class CodexSessionMonitorTests: XCTestCase {

    private func event(_ type: String, timestamp: String = "2026-04-03T09:02:26.915Z", extra: String = "") -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"\(type)"\(extra)}}
        """
    }

    private func responseItem(_ type: String, extra: String = "") -> String {
        """
        {"timestamp":"2026-04-03T09:04:11.398Z","type":"response_item","payload":{"type":"\(type)"\(extra)}}
        """
    }

    private func taskStarted(timestamp: String = "2026-04-03T09:02:26.915Z") -> String {
        event("task_started", timestamp: timestamp, extra: ",\"turn_id\":\"t1\"")
    }

    private func taskComplete() -> String {
        event("task_complete", timestamp: "2026-04-03T09:06:42.410Z", extra: ",\"turn_id\":\"t1\"")
    }

    private func turnContextLine(model: String, reasoning: String? = nil) -> String {
        let collaboration = reasoning.map {
            ",\"collaboration_mode\":{\"mode\":\"default\",\"settings\":{\"reasoning_effort\":\"\($0)\"}}"
        } ?? ""
        return """
        {"timestamp":"2026-04-03T09:02:26.915Z","type":"turn_context","payload":{"turn_id":"t1","model":"\(model)"\(collaboration)}}
        """
    }

    private let sessionMeta = """
    {"timestamp":"2026-04-03T09:02:26.907Z","type":"session_meta","payload":{"id":"019d5291"}}
    """

    private let turnContext = """
    {"timestamp":"2026-04-03T09:02:26.910Z","type":"turn_context","payload":{"cwd":"/tmp"}}
    """

    func testTaskCompleteTailIsIdle() {
        let tail = taskStarted() + "\n" + taskComplete() + "\n"
        XCTAssertEqual(CodexSessionTail.state(fromTail: tail), .idle)
    }

    func testTurnAbortedTailIsIdle() {
        let tail = taskStarted() + "\n"
            + responseItem("message") + "\n"
            + event("turn_aborted", timestamp: "2026-04-21T02:24:58.516Z", extra: ",\"turn_id\":\"t1\",\"reason\":\"interrupted\"") + "\n"
        XCTAssertEqual(CodexSessionTail.state(fromTail: tail), .idle)
    }

    func testThreadRolledBackTailIsIdle() {
        let tail = taskStarted() + "\n" + event("thread_rolled_back") + "\n"
        XCTAssertEqual(CodexSessionTail.state(fromTail: tail), .idle)
    }

    func testTaskStartedTailIsBusy() {
        let tail = taskStarted() + "\n"
        XCTAssertEqual(CodexSessionTail.state(fromTail: tail), .busy)
    }

    func testUserMessageTailIsBusy() {
        let tail = taskStarted() + "\n" + event("user_message") + "\n"
        XCTAssertEqual(CodexSessionTail.state(fromTail: tail), .busy)
    }

    func testAgentMessageTailIsBusy() {
        let tail = taskStarted() + "\n" + event("agent_message") + "\n"
        XCTAssertEqual(CodexSessionTail.state(fromTail: tail), .busy)
    }

    func testAgentReasoningTailIsBusy() {
        let tail = taskStarted() + "\n" + event("agent_reasoning") + "\n"
        XCTAssertEqual(CodexSessionTail.state(fromTail: tail), .busy)
    }

    func testToolEndEventTailIsBusy() {
        let tail = taskStarted() + "\n" + event("exec_command_end") + "\n"
        XCTAssertEqual(CodexSessionTail.state(fromTail: tail), .busy)

        let patchTail = taskStarted() + "\n" + event("patch_apply_end") + "\n"
        XCTAssertEqual(CodexSessionTail.state(fromTail: patchTail), .busy)
    }

    func testItemCompletedTailIsBusy() {
        let tail = taskStarted() + "\n" + event("item_completed") + "\n"
        XCTAssertEqual(CodexSessionTail.state(fromTail: tail), .busy)
    }

    func testWorldStateIsNeutral() {
        // world_state after task_complete must not resurrect earlier busy state.
        let tail = taskStarted() + "\n" + taskComplete() + "\n"
            + "{\"timestamp\":\"2026-09-08T13:21:31.340Z\",\"ordinal\":0,\"type\":\"world_state\",\"payload\":{\"full\":true}}\n"
        XCTAssertEqual(CodexSessionTail.state(fromTail: tail), .idle)
    }

    func testFunctionCallTailIsBusy() {
        let tail = taskStarted() + "\n" + responseItem("function_call", extra: ",\"name\":\"exec_command\"") + "\n"
        XCTAssertEqual(CodexSessionTail.state(fromTail: tail), .busy)
    }

    func testFunctionCallOutputTailIsBusy() {
        let tail = taskStarted() + "\n" + responseItem("function_call_output", extra: ",\"call_id\":\"c1\"") + "\n"
        XCTAssertEqual(CodexSessionTail.state(fromTail: tail), .busy)
    }

    func testReasoningTailIsBusy() {
        let tail = taskStarted() + "\n" + responseItem("reasoning") + "\n"
        XCTAssertEqual(CodexSessionTail.state(fromTail: tail), .busy)
    }

    func testMessageTailIsBusy() {
        let tail = taskStarted() + "\n" + responseItem("message") + "\n"
        XCTAssertEqual(CodexSessionTail.state(fromTail: tail), .busy)
    }

    func testNeutralTrailingRecordsDoNotResurrectBusy() {
        // token_count / turn_context / session_meta after task_complete must
        // not resurrect busy state from the earlier records.
        let tail = taskStarted() + "\n"
            + responseItem("function_call", extra: ",\"name\":\"exec_command\"") + "\n"
            + taskComplete() + "\n"
            + event("token_count") + "\n"
            + turnContext + "\n"
            + sessionMeta + "\n"
        XCTAssertEqual(CodexSessionTail.state(fromTail: tail), .idle)
    }

    func testTokenCountBetweenBusyRecordsKeepsBusy() {
        let tail = taskStarted() + "\n"
            + event("user_message") + "\n"
            + event("token_count") + "\n"
        XCTAssertEqual(CodexSessionTail.state(fromTail: tail), .busy)
    }

    func testPartialTrailingLineFallsBackToPreviousRecord() {
        let complete = taskComplete() + "\n"
        let truncated = "{\"timestamp\":\"2026-04-03T09:26:36.78"
        XCTAssertEqual(CodexSessionTail.state(fromTail: complete + truncated), .idle)

        let busyComplete = taskStarted() + "\n"
        XCTAssertEqual(CodexSessionTail.state(fromTail: busyComplete + truncated), .busy)
    }

    func testEmptyAndGarbageTailsAreUnknown() {
        XCTAssertEqual(CodexSessionTail.state(fromTail: ""), .unknown)
        XCTAssertEqual(CodexSessionTail.state(fromTail: "not json\nstill not json"), .unknown)
    }

    func testSinceReturnsLastTaskStartedTimestamp() {
        let tail = taskStarted(timestamp: "2026-04-03T09:02:26.915Z") + "\n"
            + event("user_message", timestamp: "2026-04-03T09:02:26.927Z") + "\n"
            + taskComplete() + "\n"
            + taskStarted(timestamp: "2026-04-03T09:25:06.342Z") + "\n"
        let since = CodexSessionTail.since(fromTail: tail)
        XCTAssertNotNil(since)
        XCTAssertEqual(since!.timeIntervalSince1970, 1_775_208_306.342, accuracy: 0.001)
    }

    func testSinceNilWhenNoTaskStartedRecord() {
        XCTAssertNil(CodexSessionTail.since(fromTail: taskComplete() + "\n"))
    }

    func testModelFromTurnContext() {
        let tail = taskStarted() + "\n" + turnContextLine(model: "gpt-5.4", reasoning: "medium") + "\n"
        XCTAssertEqual(CodexSessionTail.model(fromTail: tail), "gpt-5.4")
    }

    func testModelPrefersLatestTurnContext() {
        let tail = turnContextLine(model: "gpt-5.4") + "\n" + turnContextLine(model: "gpt-5.5") + "\n"
        XCTAssertEqual(CodexSessionTail.model(fromTail: tail), "gpt-5.5")
    }

    func testThinkingLevelFromCollaborationSettings() {
        let tail = taskStarted() + "\n" + turnContextLine(model: "gpt-5.4", reasoning: "xhigh") + "\n"
        XCTAssertEqual(CodexSessionTail.thinkingLevel(fromTail: tail), "xhigh")
    }

    func testThinkingLevelPrefersLatestTurnContext() {
        let tail = turnContextLine(model: "gpt-5.4", reasoning: "low") + "\n"
            + turnContextLine(model: "gpt-5.4", reasoning: "high") + "\n"
        XCTAssertEqual(CodexSessionTail.thinkingLevel(fromTail: tail), "high")
    }

    func testDetailsNilWhenRecordsUnavailable() {
        XCTAssertNil(CodexSessionTail.model(fromTail: ""))
        XCTAssertNil(CodexSessionTail.model(fromTail: taskComplete() + "\n"))
        XCTAssertNil(CodexSessionTail.thinkingLevel(fromTail: taskComplete() + "\n"))
        XCTAssertNil(CodexSessionTail.thinkingLevel(fromTail: "not json"))
    }

    // MARK: - Token usage (cache hit rate)

    private func tokenCountLine(
        cached: Int,
        input: Int,
        output: Int,
        total: Int,
        infoNull: Bool = false
    ) -> String {
        let info = infoNull
            ? "null"
            : """
            {"total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output),"total_tokens":\(total)},"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output),"total_tokens":\(total)}}
            """
        return """
        {"timestamp":"2026-04-03T09:06:42.000Z","type":"event_msg","payload":{"type":"token_count","info":\(info)}}
        """
    }

    func testUsageNormalisesCodexInputToUncachedTokens() {
        let tail = taskStarted() + "\n" + tokenCountLine(cached: 35584, input: 51787, output: 323, total: 52110) + "\n"
        let usage = CodexSessionTail.usage(fromTail: tail)

        XCTAssertEqual(usage?.cacheReadTokens, 35584)
        // Codex's input_tokens includes the cached part; the monitor subtracts it
        // so the hit rate matches pi/Claude semantics.
        XCTAssertEqual(usage?.inputTokens, 51787 - 35584)
        XCTAssertEqual(usage?.outputTokens, 323)
        XCTAssertEqual(usage?.reportedTotalTokens, 52110)
        XCTAssertEqual(usage?.totalTokens, 52110)
        XCTAssertEqual(usage?.cacheHitRate ?? 0, 35584.0 / 51787.0, accuracy: 0.0001)
        XCTAssertEqual(CLIUsage.percentText(usage?.cacheHitRate ?? 0), "69%")
    }

    func testUsagePrefersLatestTokenCount() {
        let tail = taskStarted() + "\n"
            + tokenCountLine(cached: 2304, input: 17153, output: 175, total: 17328) + "\n"
            + tokenCountLine(cached: 35584, input: 51787, output: 323, total: 52110) + "\n"
        XCTAssertEqual(CodexSessionTail.usage(fromTail: tail)?.cacheReadTokens, 35584)
    }

    func testUsageNilWithoutTokenCountOrInfo() {
        XCTAssertNil(CodexSessionTail.usage(fromTail: taskStarted() + "\n"))
        XCTAssertNil(CodexSessionTail.usage(fromTail: taskStarted() + "\n" + tokenCountLine(cached: 0, input: 0, output: 0, total: 0, infoNull: true) + "\n"))
        XCTAssertNil(CodexSessionTail.usage(fromTail: ""))
    }

    func testUsageHitRateNilWhenNothingCached() {
        let tail = taskStarted() + "\n" + tokenCountLine(cached: 0, input: 17153, output: 175, total: 17328) + "\n"
        let usage = CodexSessionTail.usage(fromTail: tail)
        XCTAssertNil(usage?.cacheHitRate)
        XCTAssertEqual(usage?.inputTokens, 17153)
    }

    func testFormatElapsed() {
        XCTAssertEqual(CodexLiveActivity.formatElapsed(0), "00:00")
        XCTAssertEqual(CodexLiveActivity.formatElapsed(65), "01:05")
        XCTAssertEqual(CodexLiveActivity.formatElapsed(600), "10:00")
        XCTAssertEqual(CodexLiveActivity.formatElapsed(3671), "1:01:11")
        XCTAssertEqual(CodexLiveActivity.formatElapsed(-5), "00:00")
    }
}
