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

import Foundation

/// Tool definitions for the AI agent to control phone calls
public enum PhoneTools {

    public static let allTools: [LLMToolDefinition] = [
        dialNumberTool,
        acceptCallTool,
        endCallTool,
        sendDTMFTool,
        getCallStatusTool,
        getPhoneStatusTool,
        sayToCallerTool,
    ]

    public static let dialNumberTool = LLMToolDefinition(
        name: "dial_number",
        description: "Dial a phone number to make an outgoing call. The number should be in a valid format (digits, optional + prefix, optional dashes/spaces).",
        parameters: LLMToolParameters(
            properties: [
                "number": LLMToolProperty(
                    type: "string",
                    description: "The phone number to dial, e.g. '+15551234567' or '555-123-4567'"
                ),
            ],
            required: ["number"]
        )
    )

    public static let acceptCallTool = LLMToolDefinition(
        name: "accept_call",
        description: "Accept/answer an incoming phone call.",
        parameters: LLMToolParameters(properties: [:])
    )

    public static let endCallTool = LLMToolDefinition(
        name: "end_call",
        description: "End/hang up the current active call.",
        parameters: LLMToolParameters(properties: [:])
    )

    public static let sendDTMFTool = LLMToolDefinition(
        name: "send_dtmf",
        description: "Send a DTMF tone (touch-tone digit) during an active call. Used for navigating phone menus (IVR systems).",
        parameters: LLMToolParameters(
            properties: [
                "digit": LLMToolProperty(
                    type: "string",
                    description: "A single DTMF digit: 0-9, *, or #"
                ),
            ],
            required: ["digit"]
        )
    )

    public static let getCallStatusTool = LLMToolDefinition(
        name: "get_call_status",
        description: "Get the current call status including call state, direction, duration, and phone number.",
        parameters: LLMToolParameters(properties: [:])
    )

    public static let getPhoneStatusTool = LLMToolDefinition(
        name: "get_phone_status",
        description: "Get the phone's status including signal strength, battery level, service availability, operator name, and roaming status.",
        parameters: LLMToolParameters(properties: [:])
    )

    public static let sayToCallerTool = LLMToolDefinition(
        name: "say_to_caller",
        description: "Speak text to the caller during an active phone call using text-to-speech. The caller will hear your spoken words through the phone.",
        parameters: LLMToolParameters(
            properties: [
                "text": LLMToolProperty(
                    type: "string",
                    description: "The text to speak to the caller"
                ),
            ],
            required: ["text"]
        )
    )
}
