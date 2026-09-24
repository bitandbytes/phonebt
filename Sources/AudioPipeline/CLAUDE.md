# CLAUDE.md — Sources/AudioPipeline

Real-time audio for phone calls over Bluetooth SCO. Links CoreAudio, AudioToolbox, AVFoundation, Speech. Depends only on `Shared` — **no HFP/Bluetooth imports here**; the SCO device is just a CoreAudio device from this module's perspective.

## Audio Path

```
Phone → BT SCO → CoreAudio input ─ AVAudioEngine.inputNode ─ tap → SFSpeechRecognizer → onTranscription
Claude text → ElevenLabs API (raw PCM 16 kHz) → AVAudioPCMBuffer → playerNode → engine output → SCO → Phone
```

## Files & Responsibilities

- `AudioSessionManager.swift` — owns the single shared `AVAudioEngine` + `AVAudioPlayerNode` used for full-duplex capture and playback. `configure(deviceUID:)` pins input/output audio units to the SCO device via `kAudioOutputUnitProperty_CurrentDevice`. `start()` enables voice-processing echo cancellation on macOS 14+ (best-effort) before starting the engine.
- `AudioCapture.swift` — STT. Installs a tap on the engine's input node feeding `SFSpeechAudioBufferRecognitionRequest`. Prefers on-device recognition. Emits an utterance via `onTranscription` when either the recognizer reports final, or a **1.5 s silence timeout** fires. Auto-restarts recognition every **55 s** (before Apple's 60 s session limit) and after recognition errors. `AudioCapture.requestAuthorization` must be called (done at app startup) before `start()`.
- `TTSPlayer.swift` — ElevenLabs TTS. POSTs to `/v1/text-to-speech/{voiceID}/stream?output_format=pcm_16000` with model `eleven_turbo_v2`; response is raw 16-bit LE mono PCM @ 16 kHz. Builds an `AVAudioPCMBuffer` and converts (via `AVAudioConverter`) to the engine's output format when they differ. `speak(_:)` awaits buffer-completion; `cancelCurrentPlayback()` stops + re-arms the player node. Default voice ID `21m00Tcm4TlvDq8ikWAM`.
- `AudioRouter.swift` — switches the **system default** input/output devices to the BT SCO device (`routeToBluetoothDevice()`), remembering the previous defaults, and restores them (`restorePreviousRouting()`). Idempotent: restore is a no-op unless routed.
- `AudioDeviceManager.swift` — low-level CoreAudio property plumbing: enumerate devices (`AudioDeviceInfo` with id/name/uid/transport/hasInput/hasOutput), filter Bluetooth by transport type, get/set default input/output devices.

## Invariants & Gotchas

- **One engine.** `AudioCapture` and `TTSPlayer` must share the same `AudioSessionManager`; a second engine on the same SCO device will fight over it.
- Lifecycle is driven from `PhoneBT/main.swift`: pipeline starts on `.scoConnected`, stops on `.scoDisconnected`/`.disconnected`. Always pair `AudioRouter.routeToBluetoothDevice()` with `restorePreviousRouting()` — leaving the user's Mac stuck on the SCO device is the failure mode to avoid.
- Timers in `AudioCapture` are scheduled on the main queue (`DispatchQueue.main`) because the CLI keeps `RunLoop.main` alive — don't move them to background queues without providing a run loop.
- SCO devices typically run at 8/16 kHz mono; format conversion in `TTSPlayer.createPCMBuffer` handles mismatches — don't assume the engine format.
- Errors: `AudioSessionError` (OSStatus wrapper) and `TTSError` (URL/API/buffer/conversion cases).
