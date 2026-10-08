// Copyright 2026 ICOA Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

@testable import AgentBridge
import Foundation
import Testing

@Test func liveSessionStartContainsAudioAndDelegationConfiguration() throws {
    let event = LiveProtocol.sessionStart(
        voice: "cedar",
        liveInstructions: "Live instructions",
        backendInstructions: "Backend instructions",
        callerContext: "Trusted caller facts"
    )

    #expect(event["type"] as? String == "session.start")
    let session = try #require(event["session"] as? [String: Any])
    #expect(session["model"] as? String == "gpt-live-1")

    let input = try #require(session["input"] as? [[String: Any]])
    let callerFacts = try #require(input.first)
    #expect(callerFacts["role"] as? String == "developer")
    let callerFactContent = try #require(callerFacts["content"] as? [[String: Any]])
    #expect(callerFactContent.first?["type"] as? String == "input_text")
    #expect(callerFactContent.first?["text"] as? String == "Trusted caller facts")

    let audio = try #require(session["audio"] as? [String: Any])
    let format = try #require(audio["format"] as? [String: Any])
    #expect(format["type"] as? String == "audio/pcm")
    #expect(format["rate"] as? Int == 24_000)
    let output = try #require(audio["output"] as? [String: Any])
    #expect(output["voice"] as? String == "cedar")

    let delegation = try #require(session["delegation"] as? [String: Any])
    #expect(delegation["type"] as? String == "responses")
    let responses = try #require(delegation["responses"] as? [String: Any])
    #expect(responses["model"] as? String == "gpt-6.1-sol")
    #expect(responses["parallel_tool_calls"] as? Bool == false)
    let tools = try #require(responses["tools"] as? [[String: Any]])
    #expect(tools.count == 4)
    #expect(tools.contains { $0["name"] as? String == "record_appointment_outcome" })
    #expect(tools.contains { $0["name"] as? String == "set_input_volume" })
}

@Test func liveAudioAppendEncodesPCMBytes() {
    let event = LiveProtocol.audioAppend(Data([0x01, 0x02, 0x03, 0x04]))

    #expect(event["type"] as? String == "session.input_audio.append")
    #expect(event["audio"] as? String == "AQIDBA==")
}

@Test func replacementLiveSessionIncludesPriorTranscriptHistory() throws {
    let event = LiveProtocol.sessionStart(
        voice: "marin",
        liveInstructions: "Live instructions",
        backendInstructions: "Backend instructions",
        callerContext: "Trusted caller facts",
        history: [
            LiveHistoryMessage(role: "user", text: "Tuesday would work."),
            LiveHistoryMessage(role: "assistant", text: "What time is available?"),
        ]
    )

    let session = try #require(event["session"] as? [String: Any])
    let input = try #require(session["input"] as? [[String: Any]])
    #expect(input.count == 3)
    #expect(input[1]["role"] as? String == "user")
    #expect(input[2]["role"] as? String == "assistant")
    let assistantContent = try #require(input[2]["content"] as? [[String: Any]])
    #expect(assistantContent.first?["type"] as? String == "output_text")
    #expect(assistantContent.first?["text"] as? String == "What time is available?")
}

@Test func delegatedFunctionCallIsParsedFromNestedResponseEvent() throws {
    let envelope: [String: Any] = [
        "type": "response.event",
        "event": [
            "type": "response.output_item.done",
            "item": [
                "type": "function_call",
                "call_id": "call_123",
                "name": "send_dtmf",
                "arguments": #"{"tone":"7"}"#,
            ],
        ],
    ]

    let call = try #require(LiveProtocol.functionCall(from: envelope))
    #expect(call.name == "send_dtmf")
    #expect(call.callID == "call_123")
    #expect(call.arguments["tone"] as? String == "7")
}

@Test func incompleteDelegatedFunctionCallIsIgnored() {
    let envelope: [String: Any] = [
        "event": [
            "type": "response.output_item.added",
            "item": ["type": "function_call"],
        ],
    ]

    #expect(LiveProtocol.functionCall(from: envelope) == nil)
}

@Test func functionResultAndContinuationUseLiveResponsesEvents() throws {
    let result = LiveProtocol.functionResult(callID: "call_123", output: #"{"success":true}"#)
    #expect(result["type"] as? String == "response.item.create")
    let item = try #require(result["item"] as? [String: Any])
    #expect(item["type"] as? String == "function_call_output")
    #expect(item["call_id"] as? String == "call_123")

    #expect(LiveProtocol.responseCreate()["type"] as? String == "response.create")
}

@Test func backendFinalizationMessageUsesResponsesInput() throws {
    let event = LiveProtocol.backendMessage("Finalize the call result")

    #expect(event["type"] as? String == "response.item.create")
    let item = try #require(event["item"] as? [String: Any])
    #expect(item["type"] as? String == "message")
    #expect(item["role"] as? String == "user")
    let content = try #require(item["content"] as? [[String: Any]])
    #expect(content.first?["text"] as? String == "Finalize the call result")
}

@Test func liveEventsMapToTerminalActivityStatuses() {
    #expect(
        LiveProtocol.activity(for: "session.input_transcript.delta", event: [:]) ==
            .calleeSpeaking
    )
    #expect(
        LiveProtocol.activity(for: "session.output_transcript.delta", event: [:]) ==
            .assistantSpeaking
    )
    #expect(
        LiveProtocol.activity(for: "session.delegation.created", event: [:]) ==
            .waitingForAssistant
    )
    #expect(LiveProtocol.activity(for: "response.event", event: [
        "event": ["type": "response.created"],
    ]) == .assistantWorking)
    #expect(LiveProtocol.activity(for: "response.event", event: [
        "event": ["type": "response.completed"],
    ]) == .discussionOngoing)
}

@Test func dtmfValidationAcceptsOnlyOneTelephoneKey() {
    #expect(LiveProtocol.isValidDTMFTone("5"))
    #expect(LiveProtocol.isValidDTMFTone("#"))
    #expect(!LiveProtocol.isValidDTMFTone("12"))
    #expect(!LiveProtocol.isValidDTMFTone("A"))
    #expect(!LiveProtocol.isValidDTMFTone(""))
}

@Test func inputVolumeValidationAcceptsOnlySupportedDecibels() {
    #expect(LiveProtocol.inputVolumeDecibels(from: ["decibels": 1]) == 1)
    #expect(LiveProtocol.inputVolumeDecibels(from: ["decibels": 12.5]) == 12.5)
    #expect(LiveProtocol.inputVolumeDecibels(from: ["decibels": 29]) == 29)
    #expect(LiveProtocol.inputVolumeDecibels(from: ["decibels": 0]) == nil)
    #expect(LiveProtocol.inputVolumeDecibels(from: ["decibels": 30]) == nil)
    #expect(LiveProtocol.inputVolumeDecibels(from: ["decibels": "12"]) == nil)
}

@Test func audioDumpPathsAreCreatedBesideTheResultFile() {
    let resultURL = URL(
        fileURLWithPath: "/calls/appointment-2026-10-06T21-08-42+02-00-appointment-result.json"
    )
    let paths = AudioDumpPathResolver.paths(beside: resultURL)

    #expect(paths.inputURL.path == "/calls/appointment-2026-10-06T21-08-42+02-00-agent-input.pcm")
    #expect(paths.outputURL.path == "/calls/appointment-2026-10-06T21-08-42+02-00-agent-output.pcm")
}
