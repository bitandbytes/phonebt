# CLAUDE.md — Sources/Shared

Foundation-only target with **zero dependencies**. Every other target imports it. Keep it that way: no IOBluetooth, no CoreAudio, no SwiftAnthropic here.

## Files

- `CallState.swift` — value models shared across the app:
  - `CallDirection` (`incoming`/`outgoing`) and `CallStatus` (`idle`, `dialing`, `alerting`, `incoming`, `active`, `held`, `waiting`, `ended`) — both `String`-raw, `Codable`, `Sendable`.
  - `CallInfo` — one call's index/direction/status/number/startTime; `durationDescription` formats elapsed time as `m:ss`.
  - `PhoneStatus` — signal strength (0–5), battery level (0–5), service availability, operator name, roaming. Defaults to all-zero/false.
- `Logger.swift` — `PhoneBTLogger`, a thin wrapper over `os.Logger` with subsystem `com.phonebt` and a fixed `LogCategory` enum (`bluetooth`, `hfp`, `audio`, `agent`, `app`). All messages logged with `privacy: .public`.

## Conventions

- New shared types must be `Sendable` (and usually `Codable`).
- Add a new `LogCategory` case rather than inventing ad-hoc category strings.
- This target should stay tiny — if something needs a framework import beyond Foundation/os, it belongs in a higher-level target.
