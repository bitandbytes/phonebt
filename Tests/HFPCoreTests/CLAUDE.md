# CLAUDE.md — Tests/HFPCoreTests

Unit tests for the `HFPCore` target (`@testable import HFPCore`, `Shared`).

- `HFPStateMachineTests.swift` — creates a fresh `HFPStateMachine` in `setUp`, feeds it `HFPEvent`s, and asserts on `currentState`. Covers: initial state, connect/disconnect (disconnect resets call+audio+activeCall), connect failure, call lifecycle (incoming → answered → ended; dialing → alerting → active), CIEV indicator events (`callSetup`, `callIndicator`, `callHeldIndicator` integer semantics), phone status indicators, and caller ID.

Guidelines:
- Test the state machine purely through `handleEvent(_:)` + `currentState` — no other API.
- `ATParser` (in `HFPCore/ATCommandExtensions.swift`) is pure and belongs in this target if you add parser tests.
- Don't try to test `BluetoothManager`/`HFPDevice`/`HFPDelegate` — they need real IOBluetooth hardware.
