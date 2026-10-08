# PhoneBT

PhoneBT is a macOS command-line HFP client that places a cellular call through a paired phone and connects the established call directly to OpenAI's `gpt-live-1` full-duplex voice model.

The phone and `IOBluetoothHandsFreeDevice` callbacks are authoritative for connection, call, and SCO state. The model does not dial or answer calls. Once HFP reports an active outgoing call, PhoneBT streams call audio to GPT-Live and plays model audio back to the selected call device. GPT-Live handles the natural conversation and delegates appointment reasoning and tool selection to a Responses backend. The backend can invoke `send_dtmf` to navigate an automated phone menu, `set_input_volume` to raise consistently quiet incoming call audio within the supported 1–29 dB range, `record_appointment_outcome` to checkpoint confirmed result data without ending the call, and `end_call` after GPT-Live has concluded the conversation. If the callee hangs up before a checkpoint arrives, PhoneBT briefly asks the backend to recover the structured outcome from conversation context before writing the fallback result. DTMF is sent as an out-of-band Bluetooth HFP command to the phone; it is not mixed into the PCM audio stream.

## Requirements

- macOS 13 or later
- Swift 5.9 or later
- A paired iPhone or Android phone exposing the HFP Audio Gateway service
- A full-duplex CoreAudio device carrying the call audio
- `OPENAI_API_KEY`

The default audio-device name is `USB Advanced Audio Device`. Set `PHONEBT_AUDIO_DEVICE` to override the case-insensitive name match, or select a device interactively.

Audio dumping is always enabled. Each call writes two raw mono, 24 kHz, signed 16-bit little-endian PCM files beside the input JSON and appointment-result file: `*-agent-input.pcm` contains the bytes sent to GPT-Live, and `*-agent-output.pcm` contains the bytes received from it. Their names use the same full date-and-time stamp as the appointment-result file, so multiple calls made on the same day do not overwrite one another. These files contain sensitive call audio and should be handled accordingly.

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
  "language": "German",
  "telephoneNumber": "+491234567890",
  "doctorReferralDetails": {
    "Überweisung": "Radiologie",
    "Diagnose/Verdachtsdiagnose": "Mastodynie links",
    "Auftrag": "Erbitte MammaSono bds., ggf. Mammographie"
  }
}
```

`gender` controls the GPT-Live output voice: `male` selects `cedar`, while `female` selects `marin`. The field is optional and defaults to `female`/`marin` for compatibility with existing configuration files. This is a PhoneBT voice-selection convention; OpenAI identifies these as named voices rather than assigning official genders to them.

`language` controls the language used throughout the conversation, for example `"English"`, `"German"`, or `"French"`. It is optional and defaults to English. PhoneBT applies it through the GPT-Live instructions because native speech-to-speech sessions do not have a separate output-language setting.

`telephoneNumber` and `doctorReferralDetails` are optional. Referral details are passed as string key-value pairs so German medical labels, document identifiers, and wording can be preserved verbatim. The assistant provides those facts only when relevant or requested.

Then start the call:

```text
phonebt> paired
phonebt> connect 0
phonebt> devices
phonebt> setdevice 2
phonebt> verbose on
phonebt> call +15551234567 --config /path/to/appointment.json
```

The GPT-Live session and call-audio capture start only after the HFP call-active callback, so a long ringing interval does not consume the Live session lifetime. Up to five seconds of initial call audio are buffered while the session starts and then delivered in order, preserving the callee's greeting. If the Live session expires or its transport fails while the telephone call remains active, PhoneBT makes up to three reconnection attempts and supplies the retained conversation transcript to the replacement session. Transcript text is retained only in memory for this recovery and is not printed. `hangup` remains available as a terminal safety override. When the call ends, PhoneBT writes a timestamped `*-appointment-result.json` beside the input configuration.

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

The automatically created PCM files can be imported into Audacity or played using:
```bash
ffplay -f s16le -ar 24000 -ac 1 /path/to/config/<file>-agent-input.pcm
```

GPT-Live activity is printed in the terminal as privacy-preserving status changes such as callee speaking, assistant speaking, waiting for the call assistant, and recovering the final result. Transcript text is not printed. While a call remains active, a 60-second heartbeat repeats the current status and elapsed time. `verbose on` additionally prints every HFP callback event. To inspect the complete macOS unified logs in another terminal, run:

```bash
log stream --level debug --predicate 'subsystem == "com.phonebt"'
```

## Architecture

- `HFPCore` owns Bluetooth HFP callbacks, commands, the event stream, and call state.
- `AudioPipeline` owns CoreAudio device routing and PCM16 conversion for GPT-Live audio.
- `AgentBridge` owns call configuration, result JSON persistence, the OpenAI GPT-Live WebSocket session, Responses delegation, and the `send_dtmf` and `end_call` tools.
- `PhoneBT` owns the terminal commands and wires call events to session lifecycle.

There is intentionally no separate STT, TTS, model selector, or agent mode. GPT-Live consumes and produces audio directly; its configured Responses backend handles delegated reasoning and tools.

## Build and test

```bash
swift build
swift build --build-system native

swift test
```

Hardware and live API behavior require an end-to-end call test; unit tests cover the pure HFP state machine, call-configuration decoding, and GPT-Live protocol payload construction/parsing.

## License

Copyright 2026 ICOA Inc. Licensed under the Apache License, Version 2.0.
