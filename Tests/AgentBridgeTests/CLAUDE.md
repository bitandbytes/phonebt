# CLAUDE.md — Tests/AgentBridgeTests

Unit tests for the `AgentBridge` target (`@testable import AgentBridge`, `HFPCore`, `AudioPipeline`, `Shared`).

- `ToolExecutorTests.swift` — verifies `ToolExecutor`'s JSON result contract without a live phone: a real `HFPDevice` can't be constructed in tests (needs an `IOBluetoothDevice`), so tests go through a helper that executes tools expecting "not connected"/error paths. Covers: phone number sanitization surface, unknown tool → error JSON, `say_to_caller` missing-text and TTS-unavailable errors.

Guidelines:
- Assert on parsed JSON (`JSONSerialization`) or on the deterministic `.sortedKeys` string output — every result contains `"success": Bool` and, on failure, `"error": String`.
- When adding a tool in `PhoneTools`/`ToolExecutor`, add at least: unknown/missing-parameter error test + routing test here.
- `ClaudeAgent` itself is untested (needs live Anthropic API); keep testable logic in `ToolExecutor` or pure helpers.
