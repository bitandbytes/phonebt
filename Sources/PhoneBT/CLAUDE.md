# CLAUDE.md — Sources/PhoneBT

The executable is a top-level-code CLI ending in `RunLoop.main.run()` so IOBluetooth callbacks remain alive.

The supported AI flow is outgoing-only: connect a paired phone, select a full-duplex audio device, then run `call <number> --config <file>`. The JSON file supplies `name`, `dateOfBirth`, `insurance`, free-form `additionalDetails`, optional `gender` for voice selection, and optional `language` for the conversation language. The command creates and configures a `RealtimeCallSession` while dialing and chooses a timestamped `*-appointment-result.json` path beside the input file. HFP `.callActive` starts the shared audio engine and raw Realtime bridge. `.callEnded` or `.disconnected` closes the session, writes the structured result, stops audio, and restores routing.

There is no agent sub-mode, model selector, STT authorization, or TTS configuration. This is the only target that prints to stdout or reads stdin. Keep business logic in library targets.
