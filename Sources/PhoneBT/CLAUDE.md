# CLAUDE.md — Sources/PhoneBT

The executable is a top-level-code CLI ending in `RunLoop.main.run()` so IOBluetooth callbacks remain alive.

The supported AI flow is outgoing-only: connect a paired phone, select a full-duplex audio device, then run `call <number> --config <file>`. The JSON file supplies `name`, `dateOfBirth`, `insurance`, free-form `additionalDetails`, optional `gender` for voice selection, optional `language` for the conversation language, optional `telephoneNumber`, and optional string-valued `doctorReferralDetails`. The command creates a `CallSession` while dialing and chooses a timestamped `*-appointment-result.json` path beside the input file, but it does not open GPT-Live during ringing. HFP `.callActive` starts both the Live session and the shared audio engine/raw bridge. `.callEnded` or `.disconnected` closes the session, writes the structured result, stops audio, and restores routing.

There is no agent sub-mode, model selector, STT authorization, or TTS configuration. This is the only target that prints to stdout or reads stdin. Keep business logic in library targets.
