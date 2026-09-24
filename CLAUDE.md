# CLAUDE.md — PhoneBT (Master)

## What This Project Is

PhoneBT is a **macOS Bluetooth Hands-Free Profile (HFP) client** — a Swift Package Manager executable that connects a Mac to a paired iPhone/Android phone so a Claude AI agent can make and receive real phone calls through the phone's cellular connection. The Mac acts as the Hands-Free (HF) unit; the phone is the Audio Gateway (AG).

- **License**: Apache 2.0, Copyright 2026 ICOA Inc. Every source file carries the license header — keep it when creating new files.
- **Platform**: macOS 13+ (`Package.swift` sets `.macOS(.v13)`), Swift tools 5.9.
- **Entry point**: `swift run PhoneBT` — an interactive CLI (`phonebt>` prompt) with an AI agent sub-mode (`agent>` prompt).

## Module Map (dependency order, low → high)

| Target | Path | Role | Links against |
|---|---|---|---|
| `Shared` | `Sources/Shared/` | Models (`CallInfo`, `PhoneStatus`) + `os_log` wrapper | nothing |
| `HFPCore` | `Sources/HFPCore/` | Bluetooth discovery, `IOBluetoothHandsFreeDevice` wrapper, event stream, state machine | IOBluetooth |
| `AudioPipeline` | `Sources/AudioPipeline/` | Full-duplex SCO audio: STT capture, ElevenLabs TTS, CoreAudio routing | CoreAudio, AudioToolbox, AVFoundation, Speech |
| `AgentBridge` | `Sources/AgentBridge/` | Claude tool-use loop, tool definitions, tool → HFP dispatch | HFPCore, AudioPipeline, SwiftAnthropic |
| `PhoneBT` | `Sources/PhoneBT/` | CLI executable wiring everything together | all of the above |

Dependency rule: `Shared` ← `HFPCore` / `AudioPipeline` ← `AgentBridge` ← `PhoneBT`. HFPCore and AudioPipeline do **not** depend on each other — `main.swift` and `ToolExecutor` bridge them. Keep new code on the right side of this graph.

Only external package dependency: **SwiftAnthropic** (`jamesrochabrun/SwiftAnthropic`, from 2.2.0). Other packages visible in the workspace (async-http-client, swift-nio, …) are transitive — do not import them directly.

## Core Architecture: Event Flow

```
IOBluetoothHandsFreeDevice callbacks
  → HFPDelegate (translates ObjC callbacks → HFPEvent)
  → HFPEventStream.emit()  (multi-subscriber AsyncStream fan-out)
      ├→ HFPStateMachine.handleEvent()   (updates HFPState under NSLock)
      ├→ main.swift handleEvent()        (CLI printing + audio pipeline start/stop)
      └→ ClaudeAgent.startEventListener() (injects "[PHONE EVENT] …" into conversation)
```

Caller speech flows the other way: `AudioCapture` (SFSpeechRecognizer) → `onTranscription` closure → `eventStream.emit(.callerSpeech(text))` → agent responds via the `say_to_caller` tool → `TTSPlayer` (ElevenLabs) → shared `AVAudioEngine` → SCO → phone.

Key invariants:
- **All state changes are event-driven.** Never mutate `HFPState` directly; emit an `HFPEvent` and let `HFPStateMachine` handle it.
- `HFPEventStream.makeStream()` creates an independent subscriber; `emit()` fans out to all. Events emitted before subscription are lost — subscribe first.
- SCO audio connect (`.scoConnected`) triggers audio routing + pipeline start; `.scoDisconnected`/`.disconnected` must tear it down and restore previous routing.

## Environment Variables

- `ANTHROPIC_API_KEY` — required for agent mode.
- `ELEVENLABS_API_KEY` — optional; enables TTS (`say_to_caller`). Without it, TTS tool returns an error JSON.

## Build & Test

```bash
swift build          # build
swift run PhoneBT    # run the CLI
swift test           # 30 XCTest tests (HFPStateMachineTests, ToolExecutorTests)
```

Tests use **XCTest** (not swift-testing). Real Bluetooth/audio hardware can't be mocked easily, so tests target the pure-logic layers (state machine, JSON output of tool executor).

## Conventions

- Swift concurrency (async/await, AsyncStream, Task groups) — **no Combine**.
- Classes touching ObjC frameworks are `@unchecked Sendable` with `NSLock` protecting mutable state; follow that pattern rather than actors when interfacing with IOBluetooth/CoreAudio callbacks.
- Logging: always `PhoneBTLogger(category:)` from `Shared` — never `print()` outside `Sources/PhoneBT/main.swift` (the CLI is the only place that prints to stdout).
- Errors: `LocalizedError` enums per module (`BluetoothError`, `TTSError`, `AudioSessionError`).
- 4-space indentation, PascalCase types, camelCase members, `// MARK:` section separators.

## Gotchas

- The Claude model is hardcoded in `Sources/AgentBridge/ClaudeAgent.swift` (`private let model`). The README's claim about the default model may lag the code — check the source.
- `transferAudioToComputer()` is attempted first for SCO routing, with manual CoreAudio routing (`AudioRouter`) as fallback; SCO exposure as a CoreAudio device varies by phone/Mac combo.
- Speech recognition needs user authorization (requested at app startup); on-device recognition is preferred and SFSpeechRecognizer sessions are auto-restarted before the 60 s system limit.
- Bluetooth access on newer macOS may require entitlements/code signing; discovery failures are often an entitlement issue, not a code bug.
- Per-folder `CLAUDE.md` files exist in each `Sources/*` and `Tests/*` directory with module-specific detail.
