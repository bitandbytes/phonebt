# CLAUDE.md — PhoneBT

PhoneBT is a Swift Package Manager executable for macOS 13+. It connects to a paired phone as an HFP Hands-Free unit, places an outgoing cellular call from the terminal, and bridges the established call to OpenAI `gpt-live-1` for native full-duplex speech conversation. GPT-Live delegates appointment reasoning and tool selection to a low-latency Responses backend.

Every source file carries the Apache 2.0 / ICOA Inc. header. Use Swift concurrency without Combine, `PhoneBTLogger` outside the CLI, four-space indentation, and `LocalizedError` for module errors.

## Dependency map

```text
Shared ← HFPCore
Shared ← AudioPipeline
HFPCore + AudioPipeline + Shared ← AgentBridge
all targets ← PhoneBT executable
```

- `Shared`: value models and logging only.
- `HFPCore`: IOBluetooth discovery, commands, callbacks, event stream, and authoritative HFP state.
- `AudioPipeline`: CoreAudio selection/routing, one shared audio engine, and 24 kHz PCM16 conversion.
- `AgentBridge`: call configuration and result models, result persistence, and the OpenAI GPT-Live WebSocket session with Responses-delegated `send_dtmf` and `end_call` tools.
- `PhoneBT`: terminal commands and lifecycle wiring.

HFP callbacks—not the model—own call state. The CLI loads `call <number> --config <file>` and dials without opening GPT-Live during ringing. `.callActive` starts the GPT-Live session and audio streaming together; input captured during startup is held in a bounded rolling buffer. Call end/disconnect closes the session, writes the timestamped appointment-result JSON beside the input configuration, stops audio, and restores routing. The delegated backend may end an active call after GPT-Live completes the conversation; terminal `hangup` remains a safety override.

There is intentionally no separate STT, TTS, text LLM abstraction, provider selection, or agent REPL.

## Environment

- `OPENAI_API_KEY` is required for calls.
- `PHONEBT_AUDIO_DEVICE` optionally overrides the preferred CoreAudio device name.

## Validation

Use Xcode's build action and test runner. Pure HFP state logic and call-configuration decoding are unit tested; Bluetooth, live audio, and API behavior require hardware integration testing.
