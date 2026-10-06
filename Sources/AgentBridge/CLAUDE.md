# CLAUDE.md — Sources/AgentBridge

This target contains the OpenAI Realtime call session. It depends on `HFPCore`, `AudioPipeline`, and `Shared` and has no external package dependencies.

`RealtimeCallSession.swift` opens a server-side WebSocket using `OPENAI_API_KEY` and the fixed model `gpt-realtime-2.1`. `prepare()` is called while an outgoing HFP call is dialing. `startAudio(using:)` is called only after the phone reports an active call. The session accepts and emits mono PCM16 at 24 kHz.

`CallConfiguration.swift` defines the input JSON (`name`, `dateOfBirth`, `insurance`, `additionalDetails`, optional `gender`, and optional `language`) and the persisted appointment-result schema. PhoneBT maps `male` to the `cedar` Realtime voice and `female` (or an omitted value) to `marin`; this is an application convention because OpenAI names voices without official gender labels. `language` is injected into the session instructions and defaults to English; it is not an audio-output API parameter. The saved result contains `status` and optional appointment date (`MM-DD`, without a year), appointment time, practice, and notes. Notes intentionally repeat the confirmed appointment details as a useful human-readable summary rather than relying only on the structured fields.

The system instructions make the lifecycle boundary explicit: the application owns dialing and call state, and the model never speaks first. The model supplies the structured outcome to `end_call` only after saying goodbye. Result persistence occurs when the HFP call actually closes; an unstructured termination produces an `unknown` result.

Keep Realtime protocol handling here. Keep audio conversion in `AudioPipeline` and HFP state/commands in `HFPCore`.
