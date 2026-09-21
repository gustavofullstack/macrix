---
name: macrix
description: macOS automation MCP server (100 tools) with concurrent multi-agent access. Use when the user needs calendar, reminders, notes, shortcuts, files, git, web screenshots, system probes, or Jev/TypeSafe judgments without the 100-calls/day commercial cap.
---

# macrix skill

Server: `POST http://127.0.0.1:35730/mcp` with
`Authorization: Bearer $MACRIX_KEY`. Health: `GET /health` (no auth).
Console: `GET /` (no auth). Full tool list: `GET /catalog` (no auth,
100 entries JSON). Per-key metering: `GET /usage` (Bearer).

Protocol is MCP streamable HTTP, plain-JSON responses:
`initialize` -> `notifications/initialized` -> `tools/list` -> `tools/call`.

100 tools in families: Apple apps (calendar, reminders, notes,
shortcuts, mail/messages, contacts, screen), Jev/TypeSafe (route,
rerank, eval, check, skill, models), computer-use, system probes,
files/text/zip/csv, git, clock, headless Chromium, network, clipboard,
codec/hash/QR, image/audio, plist, Tailscale, metering.

Quotas are per tier, per key, per UTC day: `free` 1000 calls/day,
`starter` 10k, `growth` 50k, `scale` 200k, `max`/`lifetime` unlimited.
Over quota returns JSON-RPC error -32000 naming the tier — back off
and tell the user, do not retry in a loop. `usage_status` (or
`GET /usage`) shows today's count vs quota.

Jev tools need `MACRIX_JEV=1` in the server environment; without it
they return a "jev disabled" error, not a judgment.

If a call returns `isError: true` with "permission denied", the macOS
TCC grant (Calendar/Reminders/Full Disk Access) is missing — tell the
user exactly which one, do not retry in a loop.

Audio is never played (`tts_render` writes an AIFF file); treat the
returned path as the artifact.
