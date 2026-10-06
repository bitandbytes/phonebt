# CLAUDE.md — Sources/PhoneBT

The executable target. Single file, `main.swift`, using **top-level code** (no `@main` type) — order matters, and the file ends with `RunLoop.main.run()` to keep the process alive for IOBluetooth callbacks. The command loop itself runs inside a `Task`.

## Structure of main.swift

1. **Globals** — `bluetoothManager`, `audioRouter`, optional `hfpDevice`/`claudeAgent`, `discoveredDevices` (index-addressed by `connect <idx>`), and audio pipeline globals (`audioSessionManager`, `audioCapture`, `ttsPlayer`).
2. **Signal handlers** — SIGINT/SIGTERM stop the pipeline, disconnect HFP, and restore audio routing before `exit(0)`.
3. **Command handlers** — one `handleX` function per CLI command (`scan`, `paired`, `connect`, `dial`, `answer`, `hangup`, `dtmf`, `status`, `phone`, `audio`, `agent`, …).
4. **Audio pipeline control** — `startAudioPipeline()` (resolve the call audio device via `audioRouter.callAudioDevice()` → configure/start `AudioSessionManager` → wire `AudioCapture.onTranscription` to `eventStream.emit(.callerSpeech(_:))` → create `TTSPlayer` if `ELEVENLABS_API_KEY` set; idempotent, returns `Bool`) and `stopAudioPipeline()`. `startCallAudio()` kicks off `startAudioWhenDeviceAppears()` on the main actor, which polls briefly for the device, routes system audio, and starts the pipeline — printing honest success/failure lines. The device name comes from `PHONEBT_AUDIO_DEVICE` (default `"USB Advanced Audio Device"`), with Bluetooth SCO as fallback.
5. **`handleEvent(_:)`** — the CLI's HFP event subscriber: prints emoji status lines and drives pipeline start (`.callActive` or `.scoConnected`, whichever comes first) / stop (`.callEnded`, `.disconnected`; `.scoDisconnected` only when the pipeline is on a Bluetooth device or no call is active — a wired USB device is unaffected by the Mac's SCO link).
6. **Agent mode** (`handleAgentMode`) — requires connection + `ANTHROPIC_API_KEY`; builds `ToolExecutor` + `ClaudeAgent`, starts the event listener task, then runs the `agent>` REPL until `exit`.
7. **Startup** — banner, help, speech-recognition authorization request, then the main `phonebt>` REPL task.

## Conventions & Gotchas

- This is the **only** place in the project allowed to `print()` / `readLine()`; all other targets use `PhoneBTLogger`.
- This file is glue only — no business logic. Parsing, state, audio, and AI logic belong in the library targets.
- `ttsPlayer` is created lazily in `startAudioPipeline()` (i.e., only once SCO connects). Note `ToolExecutor` is constructed in `handleAgentMode` with the *current* `ttsPlayer` — if agent mode starts before SCO audio connects, the executor's `ttsPlayer` will be nil until updated.
- Event subscription happens per `connect`: a new stream from `device.eventStream.makeStream()` feeds `handleEvent`.
- Command aliases exist (`call`→dial, `accept`→answer, `end`→hangup, `ai`→agent, `q`/`exit`→quit) — update `printHelp()` when adding commands.
