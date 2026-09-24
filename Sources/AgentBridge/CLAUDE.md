# CLAUDE.md — Sources/AgentBridge

The AI layer: connects Claude (via **SwiftAnthropic**, the only external dependency in the project) to the phone. Depends on `HFPCore`, `AudioPipeline`, `Shared`.

## Files & Responsibilities

- `ClaudeAgent.swift` — the tool-use conversation loop.
  - Holds `conversationHistory` (grows for the life of the agent session; no truncation) and a hardcoded model constant (`private let model: Model = .other(...)`) — change the model here.
  - `processMessage(_:)` appends a user turn and runs the loop; `injectEvent(_:)` does the same with a `[PHONE EVENT] …` prefix.
  - `runAgentLoop()` — max **10 iterations**: call `createMessage`, append assistant content to history, and while `stopReason == "tool_use"` execute each tool via `ToolExecutor` and append `toolResult` blocks as a user message. Returns concatenated text blocks when no more tool calls.
  - `startEventListener(onResponse:)` — subscribes to the `HFPEventStream` and forwards incoming call / call ended / call active / SCO events as `[PHONE EVENT]` injections; `.callerSpeech` is injected as `[CALLER SPEECH] "…"` so the model responds via `say_to_caller`.
  - System prompt (phone assistant persona + caller-speech instructions) is defined inline here.
  - `DynamicContent` → `[String: Any]` conversion helpers live at the bottom — needed because SwiftAnthropic returns typed tool inputs.
- `PhoneTools.swift` — declarative tool schemas (`MessageParameter.Tool`) exposed to Claude: `dial_number`, `accept_call`, `end_call`, `send_dtmf`, `get_call_status`, `get_phone_status`, `say_to_caller`. `PhoneTools.allTools` is the list passed on every request. Adding a tool = add schema here **and** a case in `ToolExecutor.execute`.
- `ToolExecutor.swift` — synchronous tool dispatch. Maps tool name + `[String: Any]` input to `HFPDevice`/`AudioRouter`/`TTSPlayer` calls and returns a **JSON string** (`successJSON`/`errorJSON`, always includes `"success": bool`, serialized with `.sortedKeys` for deterministic test assertions).
  - `dial_number` sanitizes to digits/`+`/`*`/`#` and proactively calls `transferAudioToComputer()`.
  - `accept_call` also routes system audio to BT; `end_call` restores routing.
  - `say_to_caller` fires TTS in a **detached task** and returns `"speaking"` immediately (doesn't await playback). Errors if `ttsPlayer` is nil (no ELEVENLABS_API_KEY / pipeline not started). `ttsPlayer` is a settable `var` because the pipeline starts after the executor may be created.

## Conventions

- Tool results are always JSON strings, never thrown errors — catch and convert to `errorJSON`.
- Keep tool schemas and executor cases in sync; unknown tool names return an error JSON (tested).
- Testing: real `HFPDevice` can't be constructed without hardware, so `Tests/AgentBridgeTests` exercises JSON format/error paths only.
