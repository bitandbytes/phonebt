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

import AudioPipeline
import Foundation
import HFPCore
import Shared

struct LiveFunctionCall {
    let name: String
    let callID: String
    let arguments: [String: Any]
}

struct AudioDumpPaths {
    let inputURL: URL
    let outputURL: URL
}

enum AudioDumpPathResolver {
    static func paths(beside resultURL: URL) -> AudioDumpPaths {
        let directory = resultURL.deletingLastPathComponent()
        let resultStem = resultURL.deletingPathExtension().lastPathComponent
        let resultSuffix = "-appointment-result"
        let callStem = resultStem.hasSuffix(resultSuffix)
            ? String(resultStem.dropLast(resultSuffix.count))
            : resultStem
        return AudioDumpPaths(
            inputURL: directory.appendingPathComponent("\(callStem)-agent-input.pcm"),
            outputURL: directory.appendingPathComponent("\(callStem)-agent-output.pcm")
        )
    }
}

enum LiveProtocol {
    static func sessionStart(
        voice: String,
        liveInstructions: String,
        backendInstructions: String,
        callerContext: String
    ) -> [String: Any] {
        [
            "type": "session.start",
            "event_id": "phonebt_session_start",
            "session": [
                "model": CallSession.model,
                "instructions": liveInstructions,
                "input": [[
                    "type": "message",
                    "role": "developer",
                    "status": "completed",
                    "content": [[
                        "type": "input_text",
                        "text": callerContext,
                    ]],
                ]],
                "audio": [
                    "format": ["type": "audio/pcm", "rate": 24_000],
                    "output": ["voice": voice],
                ],
                "delegation": [
                    "type": "responses",
                    "responses": [
                        "model": CallSession.backendModel,
                        "instructions": backendInstructions,
                        "reasoning": ["effort": "low"],
                        "parallel_tool_calls": false,
                        "tools": toolDefinitions,
                        "tool_choice": "auto",
                    ],
                ],
            ],
        ]
    }

    static func audioAppend(_ data: Data) -> [String: Any] {
        [
            "type": "session.input_audio.append",
            "audio": data.base64EncodedString(),
        ]
    }

    static func functionCall(from envelope: [String: Any]) -> LiveFunctionCall? {
        guard let responseEvent = envelope["event"] as? [String: Any],
              responseEvent["type"] as? String == "response.output_item.done",
              let item = responseEvent["item"] as? [String: Any],
              item["type"] as? String == "function_call",
              let name = item["name"] as? String,
              let callID = item["call_id"] as? String,
              let argumentText = item["arguments"] as? String,
              let data = argumentText.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return LiveFunctionCall(name: name, callID: callID, arguments: arguments)
    }

    static func functionResult(callID: String, output: String) -> [String: Any] {
        [
            "type": "response.item.create",
            "event_id": "phonebt_tool_result_\(UUID().uuidString)",
            "item": [
                "type": "function_call_output",
                "call_id": callID,
                "output": output,
            ],
        ]
    }

    static func responseCreate() -> [String: Any] {
        [
            "type": "response.create",
            "event_id": "phonebt_continue_\(UUID().uuidString)",
        ]
    }

    static func backendMessage(_ text: String) -> [String: Any] {
        [
            "type": "response.item.create",
            "event_id": "phonebt_backend_message_\(UUID().uuidString)",
            "item": [
                "type": "message",
                "role": "user",
                "content": [[
                    "type": "input_text",
                    "text": text,
                ]],
            ],
        ]
    }

    static func isValidDTMFTone(_ tone: String) -> Bool {
        tone.count == 1 && tone.first.map { "0123456789*#".contains($0) } == true
    }

    private static let toolDefinitions: [[String: Any]] = [[
        "type": "function",
        "name": "end_call",
        "description": "End the telephone call after the spoken goodbye and after record_appointment_outcome has saved the latest outcome.",
        "parameters": [
            "type": "object",
            "properties": [:],
        ],
    ], [
        "type": "function",
        "name": "record_appointment_outcome",
        "description": "Checkpoint the latest appointment outcome without ending the telephone call. Call whenever confirmed outcome details become available and again if they change.",
        "parameters": [
            "type": "object",
            "properties": [
                "status": ["type": "string", "enum": ["booked", "not_booked", "unknown"]],
                "appointment_date": ["type": "string", "description": "Confirmed appointment date in MM-DD format, or an empty string only when no date was confirmed."],
                "appointment_time": ["type": "string", "description": "Confirmed local time in HH:mm format, or an empty string."],
                "practice": ["type": "string", "description": "Practice name, or an empty string."],
                "notes": ["type": "string", "description": "A useful human-readable summary of the outcome. For a booked appointment, repeat the confirmed date, time, practice, and other important details even though they also have structured fields."],
            ],
            "required": ["status", "appointment_date", "appointment_time", "practice", "notes"],
        ],
    ], [
        "type": "function",
        "name": "send_dtmf",
        "description": "Silently press one telephone keypad key for an automated IVR menu. Send multi-digit choices one tone at a time in order.",
        "parameters": [
            "type": "object",
            "properties": [
                "tone": [
                    "type": "string",
                    "enum": ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "#"],
                    "description": "The single keypad tone to send.",
                ],
            ],
            "required": ["tone"],
        ],
    ]]
}

public final class CallSession: @unchecked Sendable {
    public static let model = "gpt-live-1"
    public static let backendModel = "gpt-6.1-sol"

    private let apiKey: String
    private let configuration: CallConfiguration
    private let resultURL: URL
    private let device: HFPDevice
    private let onDiagnostic: @Sendable (String) -> Void
    private let logger = PhoneBTLogger(category: .agent)
    private let stateQueue = DispatchQueue(label: "com.phonebt.realtime.session")
    private let audioDumper: RealtimeAudioDumper?

    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var audioBridge: RealtimeAudioBridge?
    private var isReady = false
    private var isClosing = false
    private var isClosed = false
    private var hasReceivedOutputAudio = false
    private var pendingAudio: [Data] = []
    private var pendingResult: AppointmentResult?
    private var hasWrittenResult = false

    public init(
        apiKey: String,
        configuration: CallConfiguration,
        resultURL: URL,
        device: HFPDevice,
        onDiagnostic: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.apiKey = apiKey
        self.configuration = configuration
        self.resultURL = resultURL
        self.device = device
        self.onDiagnostic = onDiagnostic
        self.audioDumper = RealtimeAudioDumper.besideResultFile(resultURL, logger: logger)
    }

    /// Connects and configures the model while the outgoing call is dialing.
    public func prepare() {
        stateQueue.async { [weak self] in
            guard let self, self.webSocket == nil, !self.isClosed else { return }
            guard let url = URL(string: "wss://api.openai.com/v1/live/sessions") else { return }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(self.apiKey)", forHTTPHeaderField: "Authorization")
            let socket = URLSession.shared.webSocketTask(with: request)
            self.webSocket = socket
            self.report("Opening Live WebSocket for \(Self.model)")
            socket.resume()
            self.sendSessionStart()
            self.receiveTask = Task { [weak self] in await self?.receiveLoop() }
        }
    }

    /// Starts forwarding call audio after HFP reports that the call is active.
    public func startAudio(using sessionManager: AudioSessionManager) throws {
        let bridge = RealtimeAudioBridge(sessionManager: sessionManager)
        try bridge.startCapture { [weak self] data in
            self?.sendAudio(data)
        }
        stateQueue.sync {
            audioBridge = bridge
        }
        report("Audio capture connected to Live session")
    }

    public func close(finalizeOutcome: Bool = true) {
        let shouldRequestFinalOutcome: Bool? = stateQueue.sync {
            guard !isClosing, !isClosed else { return nil }
            isClosing = true
            audioBridge?.shutdown()
            audioBridge = nil
            pendingAudio.removeAll()
            return finalizeOutcome && pendingResult == nil && isReady && webSocket != nil
        }
        guard let shouldRequestFinalOutcome else { return }

        if shouldRequestFinalOutcome {
            report("Call ended before an outcome was recorded; requesting final appointment result")
            send(LiveProtocol.backendMessage(
                "The telephone call has ended. Review the complete conversation and call " +
                "record_appointment_outcome exactly once with the best supported final outcome. " +
                "Use unknown only if the conversation truly did not establish the outcome. " +
                "Do not call end_call because the telephone call is already over."
            ))
            send(LiveProtocol.responseCreate())
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [self] in
                completeClose()
            }
        } else {
            completeClose()
        }
    }

    private func completeClose() {
        let shouldClose: Bool = stateQueue.sync {
            guard !isClosed else { return false }
            isClosed = true
            return true
        }
        guard shouldClose else { return }

        report("Closing GPT-Live session")
        send([
            "type": "session.close",
            "event_id": "phonebt_session_close",
        ])
        stateQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.finishTransportClose()
        }
        writeFallbackResultIfNeeded()
        audioDumper?.close()
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            do {
                guard let socket = stateQueue.sync(execute: { webSocket }) else { return }
                let message = try await socket.receive()
                guard case .string(let text) = message,
                      let data = text.data(using: .utf8),
                      let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = event["type"] as? String else { continue }
                if type != "session.output_audio.delta" &&
                    type != "session.input_transcript.delta" &&
                    type != "session.output_transcript.delta" {
                    report("Server event: \(type)")
                }
                handleEvent(type: type, event: event)
            } catch {
                if !Task.isCancelled, !stateQueue.sync(execute: { isClosed }) {
                    logger.error("GPT-Live connection ended: \(error.localizedDescription)")
                    report("Connection ended: \(error.localizedDescription)")
                }
                return
            }
        }
    }

    private func handleEvent(type: String, event: [String: Any]) {
        switch type {
        case "session.started":
            stateQueue.async { [weak self] in
                guard let self else { return }
                self.isReady = true
                let buffered = self.pendingAudio
                self.pendingAudio.removeAll()
                for data in buffered { self.sendAudioImmediately(data) }
                self.logger.info("GPT-Live session ready")
                self.report("Session configured and waiting for the callee to speak")
            }
        case "session.output_audio.delta":
            if let delta = event["delta"] as? String, let data = Data(base64Encoded: delta) {
                audioDumper?.appendOutput(data)
                stateQueue.async { [weak self] in
                    guard let self, !self.hasReceivedOutputAudio else { return }
                    self.hasReceivedOutputAudio = true
                    self.report("Received first output-audio chunk (\(data.count) bytes)")
                }
                stateQueue.sync { audioBridge }?.play(data)
            }
        case "response.event":
            handleResponseEvent(event)
        case "session.closed":
            report("Live session closed")
            stateQueue.async { [weak self] in self?.finishTransportClose() }
        case "error":
            let detail = (event["error"] as? [String: Any])?["message"] as? String ?? "Unknown GPT-Live API error"
            logger.error(detail)
            report("API error: \(detail)")
        default:
            break
        }
    }

    private func sendSessionStart() {
        send(LiveProtocol.sessionStart(
            voice: configuration.liveVoice,
            liveInstructions: livePrompt,
            backendInstructions: backendPrompt,
            callerContext: callerContext
        ))
    }

    private func handleResponseEvent(_ envelope: [String: Any]) {
        guard let call = LiveProtocol.functionCall(from: envelope) else { return }
        handleFunctionCall(call)
    }

    private func handleFunctionCall(_ call: LiveFunctionCall) {
        if call.name == "send_dtmf" {
            performSendDTMF(arguments: call.arguments, callID: call.callID)
            return
        }

        if call.name == "record_appointment_outcome" {
            if let error = recordResult(arguments: call.arguments) {
                let result = "{\"success\":false,\"error\":\"\(escapeJSON(error))\"}"
                sendFunctionResult(callID: call.callID, result: result)
                return
            }

            report("Checkpointed the latest appointment outcome")
            sendFunctionResult(callID: call.callID, result: "{\"success\":true}")
            if stateQueue.sync(execute: { isClosing }) {
                completeClose()
            }
            return
        }

        guard call.name == "end_call" else { return }
        guard stateQueue.sync(execute: { pendingResult != nil }) else {
            sendFunctionResult(
                callID: call.callID,
                result: "{\"success\":false,\"error\":\"Record the appointment outcome before ending the call\"}"
            )
            return
        }
        let bridge = stateQueue.sync { audioBridge }
        if let bridge {
            report("Waiting for final audio playback before ending the call")
            bridge.whenPlaybackFinishes { [weak self] timedOut in
                if timedOut {
                    self?.report("Final playback drain timed out; ending the call safely")
                }
                self?.performEndCall(callID: call.callID)
            }
        } else {
            performEndCall(callID: call.callID)
        }
    }

    private func performSendDTMF(arguments: [String: Any], callID: String?) {
        guard let tone = arguments["tone"] as? String,
              LiveProtocol.isValidDTMFTone(tone) else {
            report("GPT-Live backend requested an invalid DTMF tone")
            if let callID {
                sendFunctionResult(callID: callID, result: "{\"success\":false,\"error\":\"Invalid DTMF tone\"}")
            }
            return
        }

        do {
            try device.sendDTMF(tone)
            logger.info("GPT-Live backend sent a DTMF tone")
            report("Sent DTMF tone \(tone) through Bluetooth HFP (not the audio stream)")
            if let callID {
                sendFunctionResult(callID: callID, result: "{\"success\":true}")
            }
        } catch {
            logger.error("GPT-Live backend could not send DTMF: \(error.localizedDescription)")
            report("Could not send DTMF tone: \(error.localizedDescription)")
            if let callID {
                let result = "{\"success\":false,\"error\":\"\(escapeJSON(error.localizedDescription))\"}"
                sendFunctionResult(callID: callID, result: result)
            }
        }
    }

    private func performEndCall(callID: String?) {
        do {
            try device.endCall()
            logger.info("GPT-Live backend ended the call after playback completed")
            if let callID {
                sendFunctionResult(callID: callID, result: "{\"success\":true}")
            }
        } catch {
            logger.error("GPT-Live backend could not end the call: \(error.localizedDescription)")
            if let callID {
                let result = "{\"success\":false,\"error\":\"\(escapeJSON(error.localizedDescription))\"}"
                sendFunctionResult(callID: callID, result: result)
            }
        }
    }

    private func sendFunctionResult(callID: String, result: String) {
        send(LiveProtocol.functionResult(callID: callID, output: result))
        send(LiveProtocol.responseCreate())
    }

    private func recordResult(arguments: [String: Any]) -> String? {
        let status = arguments["status"] as? String ?? "unknown"
        guard ["booked", "not_booked", "unknown"].contains(status) else {
            return "Invalid appointment status"
        }

        let appointmentDate = nonempty(arguments["appointment_date"] as? String)
        let appointmentTime = nonempty(arguments["appointment_time"] as? String)
        if status == "booked", appointmentDate == nil || appointmentTime == nil {
            return "A booked appointment requires a confirmed date and time"
        }

        let result = AppointmentResult(
            status: status,
            appointmentDate: appointmentDate,
            appointmentTime: appointmentTime,
            practice: nonempty(arguments["practice"] as? String),
            notes: nonempty(arguments["notes"] as? String)
        )
        stateQueue.sync { pendingResult = result }
        return nil
    }

    private func writeFallbackResultIfNeeded() {
        guard !hasWrittenResult else { return }
        if let pendingResult {
            persist(pendingResult)
            return
        }
        persist(AppointmentResult(
            status: "unknown",
            appointmentDate: nil,
            appointmentTime: nil,
            practice: nil,
            notes: "The call ended without a structured appointment outcome."
        ))
    }

    private func persist(_ result: AppointmentResult) {
        guard !hasWrittenResult else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(result).write(to: resultURL, options: .atomic)
            hasWrittenResult = true
            report("Appointment result written to \(resultURL.path)")
        } catch {
            logger.error("Could not write appointment result: \(error.localizedDescription)")
            report("Could not write appointment result: \(error.localizedDescription)")
        }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private func sendAudio(_ data: Data) {
        stateQueue.async { [weak self] in
            guard let self, !self.isClosing, !self.isClosed else { return }
            if self.isReady {
                self.sendAudioImmediately(data)
            } else {
                self.pendingAudio.append(data)
            }
        }
    }

    private func sendAudioImmediately(_ data: Data) {
        audioDumper?.appendInput(data)
        send(LiveProtocol.audioAppend(data))
    }

    private func send(_ event: [String: Any]) {
        guard let socket = webSocket,
              let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { [logger] error in
            if let error { logger.error("GPT-Live send failed: \(error.localizedDescription)") }
        }
    }

    private func finishTransportClose() {
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        receiveTask?.cancel()
        receiveTask = nil
    }

    private func report(_ message: String) {
        onDiagnostic(message)
    }

    private var livePrompt: String {
        """
        You are making a doctor appointment by phone on behalf of \(configuration.name). Speak in \(configuration.spokenLanguage) with natural vocabulary, pronunciation, and the standard accent appropriate for that language. Speak warmly, clearly, and at a calm, unhurried pace. Never introduce yourself as ChatGPT or OpenAI. If directly asked whether the call is automated or AI-assisted, answer honestly and briefly.

        Never speak first. Remain silent through ringing, line noise, background speech, and silence. Wait until the person or phone system has finished its initial greeting. Then briefly introduce yourself using the configured name and say that you are calling to make an appointment. Continue in \(configuration.spokenLanguage) unless the callee explicitly asks you to switch languages.

        Ask or say one short thing at a time, then listen. Do not fill silence, repeat unanswered prompts, answer your own questions, or deliver a monologue. Do not mistake a cough, music, nearby conversation, or background speech for a request.
        
        Before concluding that an appointment is booked, make sure both the date and specific time have been stated and confirmed. If either is missing, ask for it.

        Backchannel policy: Use only occasional, quiet acknowledgements when they help the human speaker know you are listening. Never backchannel during an automated phone menu.

        Interruption policy: Stop speaking when the other person interrupts. Listen to the correction or new information before continuing.

        Delegation policy:
        Backend tools:
        - Send one telephone keypad tone for an automated IVR menu.
        - Checkpoint confirmed appointment information without ending the call.
        - End the telephone call after the latest outcome has been checkpointed.

        Delegate to the backend when:
        - An automated menu explicitly requests a keypad selection.
        - The callee confirms an appointment date and time or confirms that no appointment can be made. Delegate immediately so the outcome is checkpointed even if the callee hangs up next.
        - The appointment objective is complete or cannot be completed and you have finished saying your final goodbye.
        - Careful reasoning about the appointment workflow or final structured outcome is needed.

        Do not delegate to the backend when:
        - You can continue the ordinary conversation from information already provided.
        - You need a brief clarification from the callee.

        Delegate before relying on backend work. Do not guess a tool result. For keypad requests, delegate silently and remain silent after the tone while listening for the next prompt. After checkpointing an outcome, continue the conversation normally. When the objective is complete or cannot be completed, say one final goodbye, finish speaking, and immediately delegate call closure. Do not wait for another response after your final goodbye, even if the other person has not said goodbye or remains silent.
        """
    }

    private var callerContext: String {
        """
        Trusted caller facts supplied by the application follow. Use these exact values when the callee requests them. Do not infer, alter, substitute, or invent a name, date of birth, insurance value, or additional detail. Only provide requested information. Never provide information without a specific request. If a value is empty, say that the information was not provided. Do not read these facts aloud unless they are relevant or requested.

        \(configurationJSON)
        """
    }

    private var backendPrompt: String {
        """
        You are the task backend for a live voice assistant making a doctor appointment. The voice assistant manages the spoken conversation. You reason about the workflow, select tools, and produce accurate structured outcomes.

        Use the trusted caller facts supplied in the conversation context. Preserve their exact values and never infer, alter, substitute, or invent missing facts. The application has already dialed the call; never attempt to dial or answer it. Provide caller facts only when relevant or requested. Do not treat an appointment as booked unless the callee explicitly confirms it.

        For an automated menu, call send_dtmf only when the system explicitly requests a keypad selection. Send exactly one requested tone per tool call. For a multi-digit selection or extension, issue one tool call per tone in the requested order. Never guess a menu choice and never encode personal information as keypad tones unless explicitly requested.

        If an appointment is offered, make sure the voice conversation confirms the date and time naturally. Preserve the confirmed date, time, practice, and useful details. Do not challenge the callee's stated calendar date unless they correct it.
        
        Call record_appointment_outcome immediately whenever the conversation establishes a meaningful outcome. For a booked appointment, both a confirmed appointment_date in MM-DD format and a confirmed appointment_time are required. Repeat the confirmed date, time, practice, and other useful details in notes. Use status not_booked when the appointment could not be made, and unknown only when the outcome genuinely cannot be determined. Call record_appointment_outcome again if later conversation changes or adds material details.
        
        Call end_call only after record_appointment_outcome has succeeded and the voice assistant has finished its goodbye. If the telephone call has already ended, record the best supported outcome but do not call end_call.
        """
    }

    private var configurationJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(configuration),
              let value = String(data: data, encoding: .utf8) else { return "{}" }
        return value
    }

    private func escapeJSON(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Writes the exact PCM16 byte streams crossing the GPT-Live API boundary.
/// Files are created beside the call configuration and result files.
private final class RealtimeAudioDumper: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.phonebt.realtime.audio-dump")
    private let inputHandle: FileHandle
    private let outputHandle: FileHandle
    private var isClosed = false

    static func besideResultFile(_ resultURL: URL, logger: PhoneBTLogger) -> RealtimeAudioDumper? {
        do {
            let paths = AudioDumpPathResolver.paths(beside: resultURL)
            try Data().write(to: paths.inputURL, options: .atomic)
            try Data().write(to: paths.outputURL, options: .atomic)

            let dumper = try RealtimeAudioDumper(
                inputURL: paths.inputURL,
                outputURL: paths.outputURL
            )
            logger.info(
                "GPT-Live audio dump enabled: \(paths.inputURL.path), \(paths.outputURL.path)"
            )
            return dumper
        } catch {
            logger.error("Could not enable GPT-Live audio dump: \(error.localizedDescription)")
            return nil
        }
    }

    private init(inputURL: URL, outputURL: URL) throws {
        inputHandle = try FileHandle(forWritingTo: inputURL)
        outputHandle = try FileHandle(forWritingTo: outputURL)
    }

    func appendInput(_ data: Data) {
        append(data, to: inputHandle)
    }

    func appendOutput(_ data: Data) {
        append(data, to: outputHandle)
    }

    func close() {
        queue.sync {
            guard !isClosed else { return }
            isClosed = true
            try? inputHandle.synchronize()
            try? outputHandle.synchronize()
            try? inputHandle.close()
            try? outputHandle.close()
        }
    }

    private func append(_ data: Data, to handle: FileHandle) {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            do {
                try handle.write(contentsOf: data)
            } catch {
                self.isClosed = true
                try? self.inputHandle.close()
                try? self.outputHandle.close()
            }
        }
    }
}
