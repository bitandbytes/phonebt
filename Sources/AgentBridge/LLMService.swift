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

// MARK: - Message Types

public enum LLMRole: String, Sendable {
    case user
    case assistant
}

public enum LLMContent: @unchecked Sendable {
    case text(String)
    case toolUse(id: String, name: String, input: [String: Any])
    case toolResult(id: String, content: String)
}

public struct LLMMessage: @unchecked Sendable {
    public let role: LLMRole
    public let content: [LLMContent]

    public init(role: LLMRole, content: [LLMContent]) {
        self.role = role
        self.content = content
    }
}

// MARK: - Tool Definition Types

public struct LLMToolDefinition: Sendable {
    public let name: String
    public let description: String
    public let parameters: LLMToolParameters

    public init(name: String, description: String, parameters: LLMToolParameters) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct LLMToolParameters: Sendable {
    public let properties: [String: LLMToolProperty]
    public let required: [String]

    public init(properties: [String: LLMToolProperty], required: [String] = []) {
        self.properties = properties
        self.required = required
    }
}

public struct LLMToolProperty: Sendable {
    public let type: String
    public let description: String

    public init(type: String, description: String) {
        self.type = type
        self.description = description
    }
}

// MARK: - Response Types

public struct LLMResponse: @unchecked Sendable {
    public let content: [LLMContent]
    public let stopReason: LLMStopReason

    public init(content: [LLMContent], stopReason: LLMStopReason) {
        self.content = content
        self.stopReason = stopReason
    }
}

public enum LLMStopReason: Sendable {
    case endTurn
    case toolUse
    case maxTokens
}

// MARK: - Error Types

public enum LLMServiceError: Error, LocalizedError {
    case transient(String)
    case nonTransient(String)
    case configuration(String)

    public var errorDescription: String? {
        switch self {
        case .transient(let msg): return "LLM service error (transient): \(msg)"
        case .nonTransient(let msg): return "LLM service error: \(msg)"
        case .configuration(let msg): return "LLM configuration error: \(msg)"
        }
    }

    public var isRetryable: Bool {
        if case .transient = self { return true }
        return false
    }
}

// MARK: - Service Protocol

public protocol LLMService: Sendable {
    var modelName: String { get }

    func createMessage(
        systemPrompt: String,
        messages: [LLMMessage],
        tools: [LLMToolDefinition],
        maxTokens: Int
    ) async throws -> LLMResponse
}
