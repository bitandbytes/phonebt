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
import Shared

/// LLM service backed by the OpenAI Chat Completions API (hand-rolled, no SDK dependency).
public final class OpenAILLMService: LLMService, @unchecked Sendable {
    public let modelName: String
    private let apiKey: String
    private let model: String
    private let logger = PhoneBTLogger(category: .agent)
    private let urlSession = URLSession.shared

    public init(apiKey: String, model: String = "gpt-4o") {
        self.modelName = model
        self.model = model
        self.apiKey = apiKey
    }

    public func createMessage(
        systemPrompt: String,
        messages: [LLMMessage],
        tools: [LLMToolDefinition],
        maxTokens: Int
    ) async throws -> LLMResponse {
        let requestBody = buildRequestBody(
            systemPrompt: systemPrompt,
            messages: messages,
            tools: tools,
            maxTokens: maxTokens
        )

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let urlError as URLError {
            throw LLMServiceError.transient(urlError.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMServiceError.transient("Invalid HTTP response")
        }

        if httpResponse.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            if httpResponse.statusCode == 429 || httpResponse.statusCode >= 500 {
                throw LLMServiceError.transient("HTTP \(httpResponse.statusCode): \(body)")
            } else {
                throw LLMServiceError.nonTransient("HTTP \(httpResponse.statusCode): \(body)")
            }
        }

        return try parseResponse(data)
    }

    // MARK: - Request Building

    private func buildRequestBody(
        systemPrompt: String,
        messages: [LLMMessage],
        tools: [LLMToolDefinition],
        maxTokens: Int
    ) -> [String: Any] {
        var apiMessages: [[String: Any]] = []

        apiMessages.append(["role": "system", "content": systemPrompt])

        for msg in messages {
            apiMessages.append(contentsOf: convertMessage(msg))
        }

        var body: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "max_tokens": maxTokens,
        ]

        if !tools.isEmpty {
            body["tools"] = tools.map { convertTool($0) }
        }

        return body
    }

    private func convertMessage(_ msg: LLMMessage) -> [[String: Any]] {
        if msg.role == .user {
            let toolResults = msg.content.compactMap { content -> (String, String)? in
                if case .toolResult(let id, let resultContent) = content {
                    return (id, resultContent)
                }
                return nil
            }
            if !toolResults.isEmpty && toolResults.count == msg.content.count {
                return toolResults.map { (id, content) in
                    ["role": "tool", "tool_call_id": id, "content": content]
                }
            }
            let text = msg.content.compactMap { content -> String? in
                if case .text(let t) = content { return t }
                return nil
            }.joined(separator: "\n")
            return [["role": "user", "content": text]]
        }

        if msg.role == .assistant {
            var result: [String: Any] = ["role": "assistant"]

            let texts = msg.content.compactMap { content -> String? in
                if case .text(let t) = content { return t }
                return nil
            }
            if !texts.isEmpty {
                result["content"] = texts.joined(separator: "\n")
            } else {
                result["content"] = NSNull()
            }

            let toolCalls = msg.content.compactMap { content -> [String: Any]? in
                if case .toolUse(let id, let name, let input) = content {
                    let argsData = try? JSONSerialization.data(withJSONObject: input)
                    let argsString = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    return [
                        "id": id,
                        "type": "function",
                        "function": [
                            "name": name,
                            "arguments": argsString,
                        ] as [String: Any],
                    ] as [String: Any]
                }
                return nil
            }
            if !toolCalls.isEmpty {
                result["tool_calls"] = toolCalls
            }

            return [result]
        }

        return []
    }

    private func convertTool(_ tool: LLMToolDefinition) -> [String: Any] {
        var properties: [String: Any] = [:]
        for (key, prop) in tool.parameters.properties {
            properties[key] = [
                "type": prop.type,
                "description": prop.description,
            ] as [String: Any]
        }

        return [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": tool.parameters.required,
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    // MARK: - Response Parsing

    private func parseResponse(_ data: Data) throws -> LLMResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw LLMServiceError.nonTransient("Failed to parse OpenAI response")
        }

        var content: [LLMContent] = []

        if let text = message["content"] as? String, !text.isEmpty {
            content.append(.text(text))
        }

        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for toolCall in toolCalls {
                guard let id = toolCall["id"] as? String,
                      let function = toolCall["function"] as? [String: Any],
                      let name = function["name"] as? String,
                      let argsString = function["arguments"] as? String else {
                    continue
                }

                var input: [String: Any] = [:]
                if let argsData = argsString.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                    input = parsed
                }

                content.append(.toolUse(id: id, name: name, input: input))
            }
        }

        let finishReason = firstChoice["finish_reason"] as? String
        let stopReason: LLMStopReason
        switch finishReason {
        case "tool_calls": stopReason = .toolUse
        case "length": stopReason = .maxTokens
        default: stopReason = .endTurn
        }

        return LLMResponse(content: content, stopReason: stopReason)
    }
}
