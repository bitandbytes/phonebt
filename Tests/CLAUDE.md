# CLAUDE.md — Tests/

XCTest-based unit tests (`swift test`), ~30 tests across two targets. Hardware-dependent classes (IOBluetooth, CoreAudio, real network) are **not** unit tested — tests target pure logic only.

## Targets

- `HFPCoreTests/` — `HFPStateMachineTests.swift`: drives `HFPStateMachine.handleEvent(_:)` with `HFPEvent` sequences and asserts on `currentState` (connection/call/audio/activeCall transitions, CIEV indicator semantics, disconnect-resets-everything). Also the natural home for `ATParser` tests.
- `AgentBridgeTests/` — `ToolExecutorTests.swift`: exercises `ToolExecutor` JSON output and error paths *without* a live device (a real `HFPDevice` needs an `IOBluetoothDevice`). Asserts on the `{"success": …}` JSON contract — unknown tool names, missing parameters, TTS-unavailable errors.

## Conventions

- XCTest, not swift-testing — match the existing style (`XCTAssertEqual`, `setUp`, `@testable import`).
- Tool-result JSON is serialized with `.sortedKeys`, so string assertions on JSON are deterministic; prefer parsing with `JSONSerialization` as existing tests do.
- If you add pure logic (parsers, reducers, sanitizers), add tests here; don't attempt to mock IOBluetooth/AVFoundation types.
- New test targets must be registered in `Package.swift`.
