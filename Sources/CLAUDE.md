# CLAUDE.md — Sources

Five SPM targets live here:

```text
PhoneBT
  ├── AgentBridge ── HFPCore ── Shared
  │                 └── AudioPipeline ── Shared
  ├── HFPCore
  ├── AudioPipeline
  └── Shared
```

`HFPCore` and `AudioPipeline` stay independent. `AgentBridge` joins GPT-Live model control to both, and the executable coordinates lifecycle. Keep IOBluetooth in `HFPCore`, CoreAudio/AVFoundation in `AudioPipeline`, GPT-Live protocol and Responses-delegation code in `AgentBridge`, and stdin/stdout in `PhoneBT`.

Every new source file must retain the Apache 2.0 / ICOA Inc. license header.
