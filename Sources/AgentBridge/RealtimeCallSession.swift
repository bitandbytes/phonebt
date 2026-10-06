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

public final class RealtimeCallSession: @unchecked Sendable {
    public static let model = "gpt-realtime-2.1"
    // public static let model = "gpt-realtime-2.1-mini"

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
        self.audioDumper = RealtimeAudioDumper.fromEnvironment(logger: logger)
    }

    /// Connects and configures the model while the outgoing call is dialing.
    public func prepare() {
        stateQueue.async { [weak self] in
            guard let self, self.webSocket == nil, !self.isClosed else { return }
            guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=\(Self.model)") else { return }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(self.apiKey)", forHTTPHeaderField: "Authorization")
            let socket = URLSession.shared.webSocketTask(with: request)
            self.webSocket = socket
            self.report("Opening WebSocket for \(Self.model)")
            socket.resume()
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
        report("Audio capture connected to Realtime session")
    }

    public func close() {
        stateQueue.sync {
            guard !isClosed else { return }
            isClosed = true
            report("Closing Realtime session")
            audioBridge?.shutdown()
            audioBridge = nil
            pendingAudio.removeAll()
            webSocket?.cancel(with: .normalClosure, reason: nil)
            webSocket = nil
            receiveTask?.cancel()
            receiveTask = nil
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
                if type != "response.output_audio.delta" && type != "response.audio.delta" {
                    report("Server event: \(type)")
                }
                handleEvent(type: type, event: event)
            } catch {
                if !Task.isCancelled {
                    logger.error("Realtime connection ended: \(error.localizedDescription)")
                    report("Connection ended: \(error.localizedDescription)")
                }
                return
            }
        }
    }

    private func handleEvent(type: String, event: [String: Any]) {
        switch type {
        case "session.created":
            sendSessionConfiguration()
        case "session.updated":
            stateQueue.async { [weak self] in
                guard let self else { return }
                self.isReady = true
                let buffered = self.pendingAudio
                self.pendingAudio.removeAll()
                for data in buffered { self.sendAudioImmediately(data) }
                self.logger.info("Realtime session ready")
                self.report("Session configured and waiting for the callee to speak")
            }
        case "response.output_audio.delta":
            if let delta = event["delta"] as? String, let data = Data(base64Encoded: delta) {
                audioDumper?.appendOutput(data)
                stateQueue.async { [weak self] in
                    guard let self, !self.hasReceivedOutputAudio else { return }
                    self.hasReceivedOutputAudio = true
                    self.report("Received first output-audio chunk (\(data.count) bytes)")
                }
                stateQueue.sync { audioBridge }?.play(data)
            }
        case "input_audio_buffer.speech_started":
            // Keep capturing in parallel, but do not truncate queued phone output.
            break
        case "response.function_call_arguments.done":
            handleFunctionCall(event)
        case "error":
            let detail = (event["error"] as? [String: Any])?["message"] as? String ?? "Unknown Realtime API error"
            logger.error(detail)
            report("API error: \(detail)")
        default:
            break
        }
    }

    private func sendSessionConfiguration() {
        send([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": Self.model,
                "instructions": systemPrompt,
                "output_modalities": ["audio"],
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "turn_detection": [
                            "type": "server_vad",
                            "create_response": true,
                            "interrupt_response": false,
                        ],
                    ],
                    "output": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "voice": configuration.realtimeVoice,
                    ],
                ],
                "tools": [[
                        "type": "function",
                        "name": "end_call",
                        "description": "Record the outcome and end the call after the spoken goodbye has completed.",
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
                    ]],
                "tool_choice": "auto",
            ],
        ])
    }

    private func handleFunctionCall(_ event: [String: Any]) {
        guard let name = event["name"] as? String else { return }
        let callID = event["call_id"] as? String
        let arguments = functionArguments(from: event)

        guard name == "end_call" else { return }
        recordResult(arguments: arguments)
        let bridge = stateQueue.sync { audioBridge }
        if let bridge {
            report("Waiting for final audio playback before ending the call")
            bridge.whenPlaybackFinishes { [weak self] in
                self?.performEndCall(callID: callID)
            }
        } else {
            performEndCall(callID: callID)
        }
    }

    private func performEndCall(callID: String?) {
        do {
            try device.endCall()
            logger.info("Realtime agent ended the call after playback completed")
            if let callID {
                sendFunctionResult(callID: callID, result: "{\"success\":true}")
            }
        } catch {
            logger.error("Realtime agent could not end the call: \(error.localizedDescription)")
            if let callID {
                let result = "{\"success\":false,\"error\":\"\(escapeJSON(error.localizedDescription))\"}"
                sendFunctionResult(callID: callID, result: result)
            }
        }
    }

    private func sendFunctionResult(callID: String, result: String) {
        send([
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callID,
                "output": result,
            ],
        ])
    }

    private func functionArguments(from event: [String: Any]) -> [String: Any] {
        guard let text = event["arguments"] as? String,
              let data = text.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return arguments
    }

    private func recordResult(arguments: [String: Any]) {
        let status = arguments["status"] as? String ?? "unknown"
        let requestedDate = nonempty(arguments["appointment_date"] as? String)
        let result = AppointmentResult(
            status: status,
            appointmentDate: requestedDate,
            appointmentTime: nonempty(arguments["appointment_time"] as? String),
            practice: nonempty(arguments["practice"] as? String),
            notes: nonempty(arguments["notes"] as? String)
        )
        stateQueue.sync { pendingResult = result }
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
            guard let self, !self.isClosed else { return }
            if self.isReady {
                self.sendAudioImmediately(data)
            } else {
                self.pendingAudio.append(data)
            }
        }
    }

    private func sendAudioImmediately(_ data: Data) {
        audioDumper?.appendInput(data)
        send(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()])
    }

    private func send(_ event: [String: Any]) {
        guard let socket = webSocket,
              let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { [logger] error in
            if let error { logger.error("Realtime send failed: \(error.localizedDescription)") }
        }
    }

    private func report(_ message: String) {
        onDiagnostic(message)
    }

    private var systemPrompt: String {
        """
        You are conducting this phone call to make a doctor appointment. Use the caller information below. Introduce yourself as you are speaking onbehalf of the person configured in name. Never introduce yourself as ChatGPT, OpenAI, an AI model, or a virtual assistant. If the other person directly asks whether the call is automated or AI-assisted, answer honestly and briefly.

        Conduct the entire conversation in \(configuration.spokenLanguage). Use natural vocabulary, pronunciation, and the standard accent appropriate for that language. Continue using that language even if there is background speech in another language. Switch languages only if the callee explicitly asks you to.

        Never speak first. Remain completely silent until the other person has spoken and finished their initial greeting. A short greeting such as "hello" or "hi" is sufficient. A standard business greeting such as "ABC Medical Practice, how can I help you?" is also sufficient. Only after that greeting is complete, briefly introduce yourself using the configured name and say that you are calling to make an appointment. Do not react to ringing, line noise, silence, or other non-speech audio.

        The application has already dialed the call. Do not try to dial, answer, or manage call state. Speak directly and naturally to the person on the phone. Caller information:

        \(configurationJSON)

        Use passive, patient turn-taking. Try to maintain silence when the other person is speaking. After the initial greeting, speak only in response to something the other person has said. Make one short statement or ask one question at a time, then stop and wait for their reply. Never fill silence, repeat a prompt, answer your own question, deliver a monologue, or advance through several appointment details in one turn. Let the other person lead the pace.

        Provide the name, date of birth, insurance information, or additional details only when relevant or requested. Never invent missing personal information. Do not claim an appointment is booked unless the other person explicitly confirms it.

        If an appointment is offered, confirm the date and time naturally when needed. On the final note repeat the appointment in "month, date, time" format and get the confirmation. When calling end_call for a booked appointment, always populate appointment_date in MM-DD format using the confirmed date from the caller information or conversation, and populate appointment_time when it is known. Also preserve the date, time, practice, and any other useful outcome details in notes as a readable summary; do not omit them merely because they appear in structured fields. Do not mention calendar validation or challenge the callee's stated date unless they explicitly correct it themselves.

        If the objective is completed or cannot be completed, wait until the other person say goodbye, and then call end_call. Never call end_call before your spoken goodbye has finished. Always say have a nice day before calling end_call and wait for the other person to respond as well.
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

/// Writes the exact PCM16 byte streams crossing the Realtime API boundary when
/// `PHONEBT_AUDIO_DUMP_DIR` is set. Writes are serialized off the audio path.
private final class RealtimeAudioDumper: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.phonebt.realtime.audio-dump")
    private let inputHandle: FileHandle
    private let outputHandle: FileHandle
    private var isClosed = false

    static func fromEnvironment(logger: PhoneBTLogger) -> RealtimeAudioDumper? {
        guard let path = ProcessInfo.processInfo.environment["PHONEBT_AUDIO_DUMP_DIR"],
              !path.isEmpty else { return nil }

        do {
            let expandedPath = NSString(string: path).expandingTildeInPath
            let directory = URL(fileURLWithPath: expandedPath, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let inputURL = directory.appendingPathComponent("\(timestamp)-agent-input.pcm")
            let outputURL = directory.appendingPathComponent("\(timestamp)-agent-output.pcm")
            FileManager.default.createFile(atPath: inputURL.path, contents: nil)
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)

            let dumper = try RealtimeAudioDumper(inputURL: inputURL, outputURL: outputURL)
            logger.info("Realtime audio dump enabled: \(inputURL.path), \(outputURL.path)")
            return dumper
        } catch {
            logger.error("Could not enable Realtime audio dump: \(error.localizedDescription)")
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
