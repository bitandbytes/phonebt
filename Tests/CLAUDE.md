# CLAUDE.md — Tests/

Unit tests cover pure HFP state logic and call-configuration decoding. Hardware-dependent IOBluetooth, CoreAudio, and live Realtime API behavior are not unit tested.

## Targets

- `HFPCoreTests/` — `HFPStateMachineTests.swift`: drives `HFPStateMachine.handleEvent(_:)` with `HFPEvent` sequences and asserts on `currentState` (connection/call/audio/activeCall transitions, CIEV indicator semantics, disconnect-resets-everything). Also the natural home for `ATParser` tests.

- `AgentBridgeTests/` — uses Swift Testing to verify the input JSON contract and pure GPT-Live protocol construction/parsing without a live API session.
## Conventions

- Match the framework already used by the target: legacy `HFPCoreTests` uses XCTest, while new `AgentBridgeTests` uses Swift Testing.
- If you add pure logic (parsers, reducers, sanitizers), add tests here; don't attempt to mock IOBluetooth/AVFoundation types.
- New test targets must be registered in `Package.swift`.
