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
import SwiftAnthropic
import Shared

public final class AnthropicLLMService: LLMService, @unchecked Sendable {
    public let modelName: String
    private let service: AnthropicService
    private let model: Model
    private let logger = PhoneBTLogger(category: .agent)

    public init(apiKey: String, model: String = "claude-sonnet-4-6") {
        self.modelName = model
        self.model = .other(model)
        self.service = AnthropicServiceFactory.service(apiKey: apiKey, betaHeaders: nil)
    }

    public func createMessage(
        systemPrompt: String,
        messages: [LLMMessage],
        tools: [LLMToolDefinition],
        maxTokens: Int
    ) async throws -> LLMResponse {
        let params = MessageParameter(
            model: model,
            messages: convertMessages(messages),
            maxTokens: maxTokens,
            system: .text(systemPrompt),
            tools: convertTools(tools)
        )

        do {
            let response = try await service.createMessage(params)
            return convertResponse(response)
        } catch let urlError as URLError {
            throw LLMServiceError.transient(urlError.localizedDescription)
        } catch let apiError as APIError {
            let message = apiError.displayDescription
            if message.contains("status code 401") ||
                message.contains("status code 403") ||
                message.contains("status code 404") ||
                message.contains("status code 400") {
                throw LLMServiceError.nonTransient(message)
            }
            throw LLMServiceError.transient(message)
        } catch {
            let msg = error.localizedDescription
            if msg.contains("401") || msg.contains("403") || msg.contains("authentication") {
                throw LLMServiceError.nonTransient(msg)
            } else if msg.contains("429") || msg.contains("500") || msg.contains("502") || msg.contains("503") || msg.contains("overloaded") {
                throw LLMServiceError.transient(msg)
            }
            throw LLMServiceError.transient(msg)
        }
    }

    // MARK: - Conversion: LLM -> SwiftAnthropic

    private func convertMessages(_ messages: [LLMMessage]) -> [MessageParameter.Message] {
        return messages.map { msg in
            let content: MessageParameter.Message.Content
            if msg.content.count == 1, case .text(let text) = msg.content[0] {
                content = .text(text)
            } else {
                let objects = msg.content.map { convertContentToObject($0) }
                content = .list(objects)
            }
            return MessageParameter.Message(
                role: msg.role == .user ? .user : .assistant,
                content: content
            )
        }
    }

    private func convertContentToObject(_ content: LLMContent) -> MessageParameter.Message.Content.ContentObject {
        switch content {
        case .text(let text):
            return .text(text)
        case .toolUse(let id, let name, let input):
            let dynamicInput = dictToDynamicContent(input)
            return .toolUse(id, name, dynamicInput)
        case .toolResult(let id, let resultContent):
            return .toolResult(id, resultContent)
        }
    }

    private func convertTools(_ tools: [LLMToolDefinition]) -> [MessageParameter.Tool] {
        return tools.map { tool in
            var properties: [String: JSONSchema.Property] = [:]
            for (key, prop) in tool.parameters.properties {
                properties[key] = JSONSchema.Property(
                    type: schemaType(prop.type),
                    description: prop.description
                )
            }
            return .function(
                name: tool.name,
                description: tool.description,
                inputSchema: JSONSchema(
                    type: .object,
                    properties: properties,
                    required: tool.parameters.required
                )
            )
        }
    }

    private func schemaType(_ type: String) -> JSONSchema.JSONType {
        switch type {
        case "string": return .string
        case "integer": return .integer
        case "number": return .number
        case "boolean": return .boolean
        case "array": return .array
        default: return .string
        }
    }

    // MARK: - Conversion: SwiftAnthropic -> LLM

    private func convertResponse(_ response: MessageResponse) -> LLMResponse {
        let content: [LLMContent] = response.content.compactMap { item in
            switch item {
            case .text(let text, _):
                return .text(text)
            case .toolUse(let toolUse):
                let inputDict = dynamicContentToDict(toolUse.input)
                return .toolUse(id: toolUse.id, name: toolUse.name, input: inputDict)
            default:
                return nil
            }
        }

        let stopReason: LLMStopReason
        switch response.stopReason {
        case "tool_use": stopReason = .toolUse
        case "max_tokens": stopReason = .maxTokens
        default: stopReason = .endTurn
        }

        return LLMResponse(content: content, stopReason: stopReason)
    }

    // MARK: - DynamicContent Helpers

    private func dynamicContentToDict(_ input: [String: MessageResponse.Content.DynamicContent]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in input {
            result[key] = dynamicContentToAny(value)
        }
        return result
    }

    private func dynamicContentToAny(_ value: MessageResponse.Content.DynamicContent) -> Any {
        switch value {
        case .string(let s): return s
        case .integer(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let arr): return arr.map { dynamicContentToAny($0) }
        case .dictionary(let dict): return dynamicContentToDict(dict)
        }
    }

    private func dictToDynamicContent(_ dict: [String: Any]) -> [String: MessageResponse.Content.DynamicContent] {
        var result: [String: MessageResponse.Content.DynamicContent] = [:]
        for (key, value) in dict {
            result[key] = anyToDynamicContent(value)
        }
        return result
    }

    private func anyToDynamicContent(_ value: Any) -> MessageResponse.Content.DynamicContent {
        switch value {
        case let s as String: return .string(s)
        case let i as Int: return .integer(i)
        case let d as Double: return .double(d)
        case let b as Bool: return .bool(b)
        case let arr as [Any]: return .array(arr.map { anyToDynamicContent($0) })
        case let dict as [String: Any]: return .dictionary(dictToDynamicContent(dict))
        default: return .null
        }
    }
}
