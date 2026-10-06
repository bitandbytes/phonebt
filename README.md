# PhoneBT

PhoneBT is a macOS command-line HFP client that places a cellular call through a paired phone and connects the established call directly to OpenAI's `gpt-realtime-2.1` model.

The phone and `IOBluetoothHandsFreeDevice` callbacks are authoritative for connection, call, and SCO state. The model does not dial or answer calls. Once HFP reports an active outgoing call, PhoneBT streams call audio to the Realtime API and plays model audio back to the selected call device. The model can invoke `end_call` after it has concluded the conversation.

## Requirements

- macOS 13 or later
- Swift 5.9 or later
- A paired iPhone or Android phone exposing the HFP Audio Gateway service
- A full-duplex CoreAudio device carrying the call audio
- `OPENAI_API_KEY`

The default audio-device name is `USB Advanced Audio Device`. Set `PHONEBT_AUDIO_DEVICE` to override the case-insensitive name match, or select a device interactively.

For audio-path debugging, set `PHONEBT_AUDIO_DUMP_DIR` to a writable directory. Each call writes two raw mono, 24 kHz, signed 16-bit little-endian PCM files: `*-agent-input.pcm` contains the bytes sent to the Realtime API, and `*-agent-output.pcm` contains the bytes received from it. These files may contain sensitive call audio and are not created unless the variable is set.

## Run

```bash
export OPENAI_API_KEY=sk-...
swift run PhoneBT
swift run --build-system native PhoneBT
```

Typical flow. First create a call configuration, for example `appointment.json`:

```json
{
  "name": "Max Mustermann",
  "dateOfBirth": "1990-05-20",
  "insurance": "Example Health, member 123456",
  "additionalDetails": "Request a routine appointment, preferably in the morning.",
  "gender": "male",
  "language": "German"
}
```

`gender` controls the Realtime output voice: `male` selects `cedar`, while `female` selects `marin`. The field is optional and defaults to `female`/`marin` for compatibility with existing configuration files. This is a PhoneBT voice-selection convention; OpenAI identifies these as named voices rather than assigning official genders to them.

`language` controls the language used throughout the conversation, for example `"English"`, `"German"`, or `"French"`. It is optional and defaults to English. PhoneBT applies it through the Realtime session instructions because native speech-to-speech sessions do not have a separate output-language setting.

Then start the call:

```text
phonebt> paired
phonebt> connect 0
phonebt> devices
phonebt> setdevice 2
phonebt> verbose on
phonebt> call +15551234567 --config /path/to/appointment.json
```

The Realtime session is prepared while the phone is dialing. Audio capture and playback begin only after the HFP call-active callback. `hangup` remains available as a terminal safety override. When the call ends, PhoneBT writes a timestamped `*-appointment-result.json` beside the input configuration.

A booked appointment result has this format:

```json
{
  "status": "booked",
  "appointmentDate": "10-15",
  "appointmentTime": "14:30",
  "practice": "ABC Medical Practice",
  "notes": "Routine appointment confirmed by the practice."
}
```

`appointmentDate` uses `MM-DD` without a year. `notes` retains a readable summary including the confirmed date, time, practice, and other useful call details, even when those values also appear in structured fields. `status` is `booked`, `not_booked`, or `unknown`. Optional appointment fields are omitted when unavailable. If the call ends without a structured outcome, PhoneBT writes an `unknown` result.

Input and output audio to and from the AI model can be dumped by setting:

```bash
export PHONEBT_AUDIO_DUMP_DIR=/tmp/phonebt-audio
```

PCM files could be imported to Audacity or could be played using
```bash
ffplay -f s16le -ar 24000 -ac 1 /tmp/phonebt-audio/<file>.pcm
```

Realtime connection and API events are printed in the terminal. `verbose on` additionally prints every HFP callback event. To inspect the complete macOS unified logs in another terminal, run:

```bash
log stream --level debug --predicate 'subsystem == "com.phonebt"'
```

## Architecture

- `HFPCore` owns Bluetooth HFP callbacks, commands, the event stream, and call state.
- `AudioPipeline` owns CoreAudio device routing and PCM16 conversion for Realtime audio.
- `AgentBridge` owns call configuration, result JSON persistence, the OpenAI Realtime WebSocket session, and its `end_call` tool.
- `PhoneBT` owns the terminal commands and wires call events to session lifecycle.

There is intentionally no separate STT, TTS, text LLM, model selector, or agent mode. The Realtime model consumes and produces audio directly.

## Build and test

```bash
swift build
swift build --build-system native

swift test
```

Hardware and live API behavior require an end-to-end call test; unit tests cover the pure HFP state machine and call-configuration decoding.

## License

Copyright 2026 ICOA Inc. Licensed under the Apache License, Version 2.0.
