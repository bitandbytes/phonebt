# CLAUDE.md — Sources/

Five SPM targets live here. Dependency graph (arrows = "depends on"):

```
PhoneBT (executable)
  ├── AgentBridge ──┬── HFPCore ── Shared
  │                 └── AudioPipeline ── Shared
  ├── HFPCore
  ├── AudioPipeline
  └── Shared
```

- `Shared/` — dependency-free models and logging. Anything used by two or more targets belongs here.
- `HFPCore/` — everything IOBluetooth: discovery, HFP connection, events, state machine. No audio, no AI.
- `AudioPipeline/` — everything CoreAudio/AVFoundation/Speech: SCO audio capture (STT), TTS playback, device routing. No Bluetooth HFP, no AI.
- `AgentBridge/` — the only target that imports SwiftAnthropic. Maps Claude tool calls to HFPCore/AudioPipeline operations.
- `PhoneBT/` — the CLI executable (`main.swift` top-level code). Only place that reads stdin / prints to stdout.

Rules when adding code:
- Don't create cross-dependencies between `HFPCore` and `AudioPipeline` — they are bridged in `PhoneBT/main.swift` and `AgentBridge/ToolExecutor`.
- New frameworks go in `Package.swift` `linkerSettings` for the target that uses them.
- Every file starts with the Apache 2.0 / ICOA Inc. license header (copy from any existing file).
- See each subfolder's `CLAUDE.md` for module detail.
