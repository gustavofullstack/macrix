---
name: macrix
description: macOS automation MCP server (108 tools) with concurrent multi-agent access. Use when the user needs calendar, reminders, notes, shortcuts, files, git, web screenshots, system probes, or Jev/TypeSafe judgments without the 100-calls/day commercial cap.
---

# macrix skill

Server: `POST http://127.0.0.1:35730/mcp` with
`Authorization: Bearer $MACRIX_KEY`. Health: `GET /health` (no auth).
Console: `GET /` (no auth). Full tool list: `GET /catalog` (no auth,
100 entries JSON). Per-key metering: `GET /usage` (Bearer).

Protocol is MCP streamable HTTP, plain-JSON responses:
`initialize` -> `notifications/initialized` -> `tools/list` -> `tools/call`.

108 tools in families: Apple apps (calendar, reminders, notes,
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

Voice (v0.25): `voice_decide` runs a partial transcript through Jev (intent/app/complete/addressed/destructive) and acts mid-sentence when execute=true; `voice_listen` does the same from the microphone for N seconds. Pattern from Andy Gao's Jev demo.

Harness (v0.26): `agents_list`, `agent_run` (headless prompt on claude_fable/opus/sonnet, codex, antigravity, opencode, muse, goose inside ~/Projetos, ~/Documents or /tmp), `agent_route` (Jev picks the lane: hardest→fable, medium→opus, simple→sonnet, bulk→muse; execute=true runs it), `agents_gate` (in-flight runs, quota-suspended lanes), `journey_run` (one journey_id: Jev route → review stop ≥0.70 → gate → run → ledger with execution_status/cost_status), `env_inventory` (census of MCPs/skills/plugins/hooks/commands). agent_run: max 2 in flight, op_id dedupe 10 min, 429 suspends the lane 30 min, timeout kill = unknown, ledger ~/.config/macrix/agent-ledger.jsonl.
