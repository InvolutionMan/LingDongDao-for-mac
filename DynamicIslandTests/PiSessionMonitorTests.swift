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

final class PiSessionMonitorTests: XCTestCase {

    private func assistantLine(stopReason: String) -> String {
        """
        {"type":"message","id":"abc123","timestamp":"2026-09-06T10:00:00.000Z","message":{"role":"assistant","model":"deepseek-v4-flash","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0},"stopReason":"\(stopReason)"}}
        """
    }

    private func toolResultLine() -> String {
        """
        {"type":"message","id":"def456","timestamp":"2026-09-06T10:00:05.000Z","message":{"role":"toolResult","toolCallId":"call_1","toolName":"bash","content":[{"type":"text","text":"ok"}]}}
        """
    }

    /// A user prompt record; a new prompt starts a fresh task list.
    private let promptLine = """
    {"type":"message","id":"u1","timestamp":"2026-09-06T10:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}
    """

    private func userLine() -> String {
        """
        {"type":"message","id":"789","timestamp":"2026-09-06T10:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}
        """
    }

    private func bashExecutionLine() -> String {
        """
        {"type":"bashExecution","id":"b1","timestamp":"2026-09-06T10:00:09.000Z","content":"ls","cancelled":true}
        """
    }

    private func modelChangeLine() -> String {
        """
        {"type":"model_change","id":"mc1","parentId":null,"provider":"deepseek","modelId":"deepseek-v4-flash"}
        """
    }

    private func thinkingLevelLine(_ level: String) -> String {
        """
        {"type":"thinking_level_change","id":"tl1","parentId":null,"timestamp":"2026-09-06T10:00:10.000Z","thinkingLevel":"\(level)"}
        """
    }

    func testAssistantToolUseTailIsBusy() {
        let tail = userLine() + "\n" + assistantLine(stopReason: "toolUse") + "\n"
        XCTAssertEqual(PiSessionTail.state(fromTail: tail), .busy)
    }

    func testToolResultTailIsBusy() {
        // Tool finished but the follow-up model call hasn't been flushed yet.
        let tail = assistantLine(stopReason: "toolUse") + "\n" + toolResultLine() + "\n"
        XCTAssertEqual(PiSessionTail.state(fromTail: tail), .busy)
    }

    func testUserTailIsBusy() {
        // Submitted and not answered yet — the model is thinking.
        let tail = assistantLine(stopReason: "stop") + "\n" + userLine() + "\n"
        XCTAssertEqual(PiSessionTail.state(fromTail: tail), .busy)
    }

    func testAssistantStopTailIsIdle() {
        let tail = userLine() + "\n" + assistantLine(stopReason: "stop") + "\n"
        XCTAssertEqual(PiSessionTail.state(fromTail: tail), .idle)
    }

    func testAssistantAbortedTailIsIdle() {
        let tail = assistantLine(stopReason: "aborted") + "\n"
        XCTAssertEqual(PiSessionTail.state(fromTail: tail), .idle)
    }

    func testBashExecutionTailIsIdle() {
        let tail = assistantLine(stopReason: "stop") + "\n" + bashExecutionLine() + "\n"
        XCTAssertEqual(PiSessionTail.state(fromTail: tail), .idle)
    }

    func testSkipsUnrecognizedTrailingRecords() {
        // A `model_change` after the final answer must not resurrect busy state
        // from the earlier toolUse record further up.
        let tail = userLine() + "\n"
            + assistantLine(stopReason: "toolUse") + "\n"
            + toolResultLine() + "\n"
            + assistantLine(stopReason: "stop") + "\n"
            + "{\"type\":\"model_change\",\"id\":\"mc1\",\"provider\":\"deepseek\",\"modelId\":\"deepseek-v4-flash\"}\n"
        XCTAssertEqual(PiSessionTail.state(fromTail: tail), .idle)
    }

    func testPartialTrailingLineFallsBackToPreviousRecord() {
        // The poller may read a record mid-flush; the parser must skip the
        // incomplete trailing line and classify by the last complete one.
        let complete = assistantLine(stopReason: "stop") + "\n"
        let truncated = "{\"type\":\"message\",\"id\":\"999\",\"timestamp\":\"2026-09-06T10:00:2"
        XCTAssertEqual(PiSessionTail.state(fromTail: complete + truncated), .idle)

        let busyComplete = assistantLine(stopReason: "toolUse") + "\n"
        XCTAssertEqual(PiSessionTail.state(fromTail: busyComplete + truncated), .busy)
    }

    func testEmptyAndGarbageTailsAreUnknown() {
        XCTAssertEqual(PiSessionTail.state(fromTail: ""), .unknown)
        XCTAssertEqual(PiSessionTail.state(fromTail: "not json\nstill not json"), .unknown)
    }

    func testModelFromAssistantMessage() {
        let tail = userLine() + "\n" + assistantLine(stopReason: "toolUse") + "\n"
        XCTAssertEqual(PiSessionTail.model(fromTail: tail), "deepseek-v4-flash")
    }

    func testModelFromModelChangeRecord() {
        // A model switch with no assistant response after it yet.
        let tail = modelChangeLine() + "\n"
        XCTAssertEqual(PiSessionTail.model(fromTail: tail), "deepseek-v4-flash")
    }

    func testModelPrefersLatestRecord() {
        // The newer assistant response supersedes the session-level switch.
        let older = modelChangeLine() + "\n"
        let newerResponse = userLine() + "\n"
            + """
            {"type":"message","id":"nm1","timestamp":"2026-09-06T10:01:00.000Z","message":{"role":"assistant","model":"nvidia/nemotron-3.5-lightning:free","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"stopReason":"stop"}}
            """
            + "\n"
        XCTAssertEqual(PiSessionTail.model(fromTail: older + newerResponse), "nvidia/nemotron-3.5-lightning:free")
    }

    func testThinkingLevelFromTail() {
        let tail = modelChangeLine() + "\n" + thinkingLevelLine("high") + "\n"
        XCTAssertEqual(PiSessionTail.thinkingLevel(fromTail: tail), "high")
    }

    func testThinkingLevelPrefersLatestChange() {
        let tail = thinkingLevelLine("minimal") + "\n" + thinkingLevelLine("max") + "\n"
        XCTAssertEqual(PiSessionTail.thinkingLevel(fromTail: tail), "max")
    }

    func testDetailsNilWhenRecordsUnavailable() {
        XCTAssertNil(PiSessionTail.model(fromTail: ""))
        XCTAssertNil(PiSessionTail.model(fromTail: userLine() + "\n"))
        XCTAssertNil(PiSessionTail.thinkingLevel(fromTail: userLine() + "\n"))
        XCTAssertNil(PiSessionTail.thinkingLevel(fromTail: "not json"))
    }

    private func assistantToolCallLine(
        name: String,
        callId: String,
        arguments: String,
        input: Int,
        output: Int,
        cacheRead: Int,
        total: Int
    ) -> String {
        """
        {"type":"message","id":"tc1","timestamp":"2026-09-06T10:00:02.000Z","message":{"role":"assistant","model":"deepseek-v4-flash","usage":{"input":\(input),"output":\(output),"cacheRead":\(cacheRead),"cacheWrite":0,"reasoning":0,"totalTokens":\(total)},"stopReason":"toolUse","content":[{"type":"toolCall","id":"\(callId)","name":"\(name)","arguments":\(arguments)}]}}
        """
    }

    private func toolResultLine(callId: String) -> String {
        """
        {"type":"message","id":"tr1","timestamp":"2026-09-06T10:00:05.000Z","message":{"role":"toolResult","toolCallId":"\(callId)","toolName":"bash","content":[{"type":"text","text":"ok"}]}}
        """
    }

    func testDetailExtractsPendingTool() {
        let tail = userLine() + "\n"
            + assistantToolCallLine(name: "read", callId: "c1", arguments: #"{"path":"Sources/main.swift"}"#, input: 100, output: 20, cacheRead: 900, total: 1020) + "\n"
        let detail = PiSessionTail.detail(fromTail: tail)
        XCTAssertEqual(detail?.toolName, "read")
        XCTAssertEqual(detail?.toolTarget, "Sources/main.swift")
        XCTAssertEqual(detail?.toolIsPending, true)
    }

    func testDetailFallsBackToLastCompletedTool() {
        let tail = assistantToolCallLine(name: "bash", callId: "c1", arguments: #"{"command":"swift test"}"#, input: 10, output: 5, cacheRead: 0, total: 15) + "\n"
            + toolResultLine(callId: "c1") + "\n"
        let detail = PiSessionTail.detail(fromTail: tail)
        XCTAssertEqual(detail?.toolName, "bash")
        XCTAssertEqual(detail?.toolTarget, "swift test")
        XCTAssertEqual(detail?.toolIsPending, false)
    }

    func testDetailUsageAndCacheHitRate() {
        let tail = assistantToolCallLine(name: "bash", callId: "c1", arguments: #"{"command":"ls"}"#, input: 200, output: 50, cacheRead: 800, total: 1050) + "\n"
        let detail = PiSessionTail.detail(fromTail: tail)
        XCTAssertEqual(detail?.inputTokens, 200)
        XCTAssertEqual(detail?.outputTokens, 50)
        XCTAssertEqual(detail?.cacheReadTokens, 800)
        XCTAssertEqual(detail?.totalTokens, 1050)
        XCTAssertEqual(detail?.cacheHitRate ?? 0, 0.8, accuracy: 0.0001)
    }

    private func assistantTwoToolCallsLine() -> String {
        """
        {"type":"message","id":"tc2","timestamp":"2026-09-06T10:00:03.000Z","message":{"role":"assistant","model":"deepseek-v4-flash","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":15},"stopReason":"toolUse","content":[{"type":"toolCall","id":"c1","name":"read","arguments":{"path":"a.swift"}},{"type":"toolCall","id":"c2","name":"bash","arguments":{"command":"swift test"}}]}}
        """
    }

    func testDetailTaskStatesQueuedThenRunning() {
        let tail = promptLine + "\n" + assistantTwoToolCallsLine() + "\n"
        let detail = PiSessionTail.detail(fromTail: tail)
        XCTAssertEqual(detail?.tasks.map(\.name), ["read", "bash"])
        XCTAssertEqual(detail?.tasks.first?.state, .running)
        XCTAssertEqual(detail?.tasks.last?.state, .upcoming)
    }

    func testDetailTaskStatesCompletedAfterResult() {
        let tail = promptLine + "\n"
            + assistantTwoToolCallsLine() + "\n"
            + toolResultLine(callId: "c1") + "\n"
        let detail = PiSessionTail.detail(fromTail: tail)
        XCTAssertEqual(detail?.tasks.first?.state, .completed)
        XCTAssertEqual(detail?.tasks.last?.state, .running)
    }

    func testDetailTasksResetOnNewPrompt() {
        let firstTurn = promptLine + "\n" + assistantToolCallLine(name: "bash", callId: "c1", arguments: #"{"command":"ls"}"#, input: 1, output: 1, cacheRead: 0, total: 2) + "\n" + toolResultLine(callId: "c1") + "\n"
        let secondTurn = promptLine + "\n" + assistantToolCallLine(name: "read", callId: "c9", arguments: #"{"path":"b.swift"}"#, input: 1, output: 1, cacheRead: 0, total: 2) + "\n"
        let detail = PiSessionTail.detail(fromTail: firstTurn + secondTurn)
        XCTAssertEqual(detail?.tasks.map(\.name), ["read"])
        XCTAssertEqual(detail?.tasks.first?.state, .running)
    }

    func testDetailNilWhenNothingKnown() {
        XCTAssertNil(PiSessionTail.detail(fromTail: ""))
        XCTAssertNil(PiSessionTail.detail(fromTail: userLine() + "\n"))
    }

    func testFormatTokens() {
        XCTAssertEqual(PiLiveActivity.formatTokens(0), "0")
        XCTAssertEqual(PiLiveActivity.formatTokens(999), "999")
        XCTAssertEqual(PiLiveActivity.formatTokens(1_500), "1.5k")
        XCTAssertEqual(PiLiveActivity.formatTokens(12_345), "12.3k")
        XCTAssertEqual(PiLiveActivity.formatTokens(2_400_000), "2.4M")
    }

    func testFormatElapsed() {
        XCTAssertEqual(PiLiveActivity.formatElapsed(0), "00:00")
        XCTAssertEqual(PiLiveActivity.formatElapsed(65), "01:05")
        XCTAssertEqual(PiLiveActivity.formatElapsed(600), "10:00")
        XCTAssertEqual(PiLiveActivity.formatElapsed(3671), "1:01:11")
        XCTAssertEqual(PiLiveActivity.formatElapsed(-5), "00:00")
    }

    func testPiProcessPIDsReturnsConsistentResults() {
        // Two consecutive reads of the kernel process table must agree on
        // whether pi is running (guards against ENOMEM/parsing flakiness in
        // the sysctl implementation).
        let first = PiSessionMonitor.piProcessPIDs()
        let second = PiSessionMonitor.piProcessPIDs()
        XCTAssertEqual(first.isEmpty, second.isEmpty)
        if !first.isEmpty {
            XCTAssertEqual(Set(first), Set(second))
            XCTAssertTrue(first.allSatisfy { $0 > 0 })
        }
    }
}
