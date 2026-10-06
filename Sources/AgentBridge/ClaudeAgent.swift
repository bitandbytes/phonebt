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
import HFPCore
import Shared

private actor AgentRequestGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// AI agent that manages phone calls via tool-use conversation loop
public final class ClaudeAgent: @unchecked Sendable {
    private let llmService: any LLMService
    private let toolExecutor: ToolExecutor
    private let eventStream: HFPEventStream
    private let logger = PhoneBTLogger(category: .agent)
    private let requestGate = AgentRequestGate()

    private var conversationHistory: [LLMMessage] = []

    private let systemPrompt = """
        You are a phone call assistant responsible to make doctor appointments. \
        You can make phone calls through a Bluetooth-connected phone. \
        You have tools to dial numbers and end calls, check call/phone status, \
        and speak to callers.

        When a user asks you to call someone, use the dial_number tool. \
        When an incoming call arrives, inform the user and ask if they want to answer. \
        Provide helpful status updates about ongoing calls.

        During active calls, you will receive [CALLER SPEECH] messages containing \
        transcriptions of what the caller is saying. Respond naturally to the caller \
        using the say_to_caller tool. Have a real-time conversation — listen to what \
        they say and respond appropriately. Keep your spoken responses concise and natural.

        Be concise in your responses. Report tool results clearly.
        """

    public init(llmService: any LLMService, toolExecutor: ToolExecutor, eventStream: HFPEventStream) {
        self.llmService = llmService
        self.toolExecutor = toolExecutor
        self.eventStream = eventStream
    }

    /// Process a user message through the agent loop, returning the final text response
    public func processMessage(_ userMessage: String) async throws -> String {
        await requestGate.acquire()
        do {
            conversationHistory.append(
                LLMMessage(role: .user, content: [.text(userMessage)])
            )
            let response = try await runAgentLoop()
            await requestGate.release()
            return response
        } catch {
            await requestGate.release()
            throw error
        }
    }

    /// Inject a system event (e.g., incoming call notification) into the conversation
    public func injectEvent(_ eventDescription: String) async throws -> String {
        await requestGate.acquire()
        do {
            let message = "[PHONE EVENT] \(eventDescription)"
            conversationHistory.append(
                LLMMessage(role: .user, content: [.text(message)])
            )
            let response = try await runAgentLoop()
            await requestGate.release()
            return response
        } catch {
            await requestGate.release()
            throw error
        }
    }

    /// Start listening for HFP events and forwarding them to the agent
    public func startEventListener(onResponse: @escaping @Sendable (String) -> Void) -> Task<Void, Never> {
        let stream = eventStream.makeStream()

        return Task { [weak self] in
            for await event in stream {
                guard let self = self else { break }

                let description: String?
                switch event {
                case .incomingCall(let number):
                    description = "Incoming call from \(number ?? "unknown number")"
                case .callEnded:
                    description = "Call has ended"
                case .callActive:
                    description = "Call is now active"
                case .scoConnected:
                    description = "Audio connected — you can now hear and speak"
                case .scoDisconnected:
                    description = "Audio disconnected"
                case .callerSpeech(let text):
                    description = nil
                    do {
                        let response = try await self.injectEvent("[CALLER SPEECH] \"\(text)\"")
                        onResponse(response)
                    } catch {
                        self.logger.error("Failed to process caller speech (continuing): \(error)")
                    }
                    continue
                default:
                    description = nil
                }

                if let desc = description {
                    do {
                        let response = try await self.injectEvent(desc)
                        onResponse(response)
                    } catch {
                        self.logger.error("Failed to inject event '\(desc)' (continuing): \(error)")
                    }
                }
            }
        }
    }

    // MARK: - Private

    private func runAgentLoop() async throws -> String {
        truncateHistoryIfNeeded()

        var iterations = 0
        let maxIterations = 10

        while iterations < maxIterations {
            iterations += 1

            let response = try await callLLMWithRetry()

            conversationHistory.append(
                LLMMessage(role: .assistant, content: response.content)
            )

            if response.stopReason == .toolUse {
                var toolResults: [LLMContent] = []

                for content in response.content {
                    if case .toolUse(let id, let name, let input) = content {
                        logger.info("Tool call: \(name)")
                        let result = toolExecutor.execute(toolName: name, input: input)
                        toolResults.append(.toolResult(id: id, content: result))
                    }
                }

                conversationHistory.append(
                    LLMMessage(role: .user, content: toolResults)
                )
                continue
            }

            return extractTextResponse(from: response.content)
        }

        return "Agent reached maximum iterations without completing."
    }

    // MARK: - Retry Logic

    private func callLLMWithRetry() async throws -> LLMResponse {
        let maxRetries = 3
        let baseDelay: UInt64 = 1_000_000_000

        for attempt in 0..<maxRetries {
            do {
                return try await llmService.createMessage(
                    systemPrompt: systemPrompt,
                    messages: conversationHistory,
                    tools: PhoneTools.allTools,
                    maxTokens: 1024
                )
            } catch let error as LLMServiceError where error.isRetryable {
                if attempt < maxRetries - 1 {
                    let delay = baseDelay * UInt64(1 << attempt)
                    logger.warning("LLM call failed (attempt \(attempt + 1)/\(maxRetries)), retrying in \(1 << attempt)s: \(error.localizedDescription)")
                    try await Task.sleep(nanoseconds: delay)
                } else {
                    logger.error("LLM call failed after \(maxRetries) attempts: \(error.localizedDescription)")
                    throw error
                }
            }
        }
        fatalError("Unreachable")
    }

    // MARK: - History Management

    private let maxEstimatedTokens = 80_000
    private let keepRecentMessages = 10

    private func truncateHistoryIfNeeded() {
        let estimatedTokens = conversationHistory.reduce(0) { total, message in
            total + message.content.reduce(0) { subtotal, content in
                switch content {
                case .text(let t): return subtotal + t.count / 4
                case .toolUse(_, _, let input):
                    let desc = "\(input)"
                    return subtotal + desc.count / 4
                case .toolResult(_, let c): return subtotal + c.count / 4
                }
            }
        }

        guard estimatedTokens > maxEstimatedTokens else { return }
        guard conversationHistory.count > keepRecentMessages else { return }

        // Find a safe truncation boundary — never split tool_use/tool_result pairs.
        // Walk backward from the target keep count to find a user message that
        // contains only text (not tool results), which is a safe boundary.
        let targetStart = conversationHistory.count - keepRecentMessages
        var safeStart = targetStart
        for i in stride(from: targetStart, through: 0, by: -1) {
            let msg = conversationHistory[i]
            if msg.role == .user {
                let hasToolResult = msg.content.contains { content in
                    if case .toolResult = content { return true }
                    return false
                }
                if !hasToolResult {
                    safeStart = i
                    break
                }
            }
        }

        let trimCount = safeStart
        guard trimCount > 0 else { return }

        logger.warning("Truncating conversation: removing \(trimCount) older messages (est. \(estimatedTokens) tokens)")
        conversationHistory = Array(conversationHistory.suffix(from: safeStart))

        if let first = conversationHistory.first, first.role == .assistant {
            conversationHistory.insert(
                LLMMessage(role: .user, content: [.text("[conversation history truncated]")]),
                at: 0
            )
        }
    }

    private func extractTextResponse(from content: [LLMContent]) -> String {
        var texts: [String] = []
        for item in content {
            if case .text(let text) = item { texts.append(text) }
        }
        return texts.joined(separator: "\n")
    }
}
