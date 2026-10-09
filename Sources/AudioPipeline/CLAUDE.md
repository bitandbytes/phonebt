# CLAUDE.md — Sources/AudioPipeline

This target owns CoreAudio device discovery, system routing, the shared `AVAudioEngine`, and the raw audio bridge used by OpenAI GPT-Live. It depends only on `Shared`.

- `AudioDeviceManager.swift` enumerates and selects CoreAudio devices.
- `AudioRouter.swift` temporarily switches the default input/output devices and restores them after a call.
- `AudioSessionManager.swift` owns the single full-duplex `AVAudioEngine` and player node.
- `AudioBridge.swift` converts device input to mono PCM16 at 24 kHz and converts streamed PCM16 model output to the selected device format.

There is no STT or TTS subsystem. Do not add a second audio engine: capture and playback must share `AudioSessionManager`. Always restore previous audio routing when a call ends, disconnects, or fails.

`AudioSessionManager.setInputVolume(decibels:)` adjusts the configured call input device's writable hardware master gain and accepts only 1–29 dB. Unsupported or fixed-volume devices return an error to the caller; initial best-effort device-volume configuration remains nonfatal.
