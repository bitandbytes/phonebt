# CLAUDE.md — Sources/HFPCore

All IOBluetooth interaction lives here. Links `IOBluetooth.framework`. Depends only on `Shared`.

## Files & Responsibilities

- `BluetoothManager.swift` — device discovery. `scanForDevices(duration:)` wraps `IOBluetoothDeviceInquiry` in a checked continuation; `getPairedPhones()` filters paired devices by the HFP Audio Gateway SDP UUID (`0x111F`); `device(forAddress:)` resolves an `IOBluetoothDevice`. Also defines `DiscoveredDevice` and `BluetoothError` (the module-wide error enum).
- `HFPDevice.swift` — the public facade. Wraps `IOBluetoothHandsFreeDevice`, owns the `HFPEventStream` + `HFPStateMachine`, and exposes: `connect(timeout:)` (races the event stream against a timeout via `withThrowingTaskGroup`), `dial`, `acceptCall`, `endCall`, `sendDTMF`, `connectAudio`/`disconnectAudio` (SCO), `transferAudioToComputer()`, and raw `sendATCommand`. Failable init returns nil if `IOBluetoothHandsFreeDevice` can't be created.
- `HFPDelegate.swift` — implements `IOBluetoothHandsFreeDeviceDelegate`; the *only* translation point from ObjC callbacks to `HFPEvent`s. Callbacks arrive with implicitly-unwrapped optionals — always nil-coalesce.
- `HFPEvents.swift` — `HFPEvent` enum (connection, call state, SCO audio, CIEV-style indicators, caller ID, `callerSpeech`) and `HFPEventStream`, a lock-protected multi-subscriber fan-out: `makeStream()` registers an `AsyncStream` continuation keyed by UUID; `emit()` yields to all; termination auto-unregisters.
- `HFPStateMachine.swift` — pure event → state reducer. Holds `HFPState` (connection / call / audio / phoneStatus / activeCall) behind an `NSLock`. `.disconnected` resets everything. Indicator events (`callSetup`, `callIndicator`, `callHeldIndicator`) mirror HFP CIEV semantics — see inline comments for the integer meanings.
- `ATCommandExtensions.swift` — `ATParser`: stateless parsers for `+CLCC` (call list → `CallInfo`), `+COPS` (operator name), `+CLIP` (caller ID). Pure functions, well covered by patterns worth reusing for new AT responses.

## Invariants

- State changes **only** via `stateMachine.handleEvent(_:)` driven by emitted events. `HFPDevice` emits `.callDialing` itself on `dial()` because the AG doesn't echo it back immediately.
- `HFPDevice` runs its own internal task pumping its event stream into the state machine; external consumers create *separate* streams via `eventStream.makeStream()`.
- Events are fire-and-forget: subscribers created after an event never see it.
- All commands guard `currentState.connection == .connected` and throw `BluetoothError.notConnected` otherwise — keep this pattern for new commands.

## Testing

`HFPStateMachine` and `ATParser` are pure logic — test them in `Tests/HFPCoreTests`. The IOBluetooth-touching classes (`BluetoothManager`, `HFPDevice`, `HFPDelegate`) require real hardware and are not unit tested.
