---
name: macuse-open
description: macOS automation MCP server with no daily limits and concurrent multi-agent access. Use when the user needs calendar, reminders, notes, or shortcuts tools without the 100-calls/day commercial cap.
---

# macuse-open skill

Server: `POST http://127.0.0.1:35730/mcp` with
`Authorization: Bearer $MACUSE_OPEN_KEY`. Health: `GET /health` (no auth).

Protocol is MCP streamable HTTP, plain-JSON responses:
`initialize` -> `notifications/initialized` -> `tools/list` -> `tools/call`.

Six read-first tools plus `shortcuts_run` (the only writer: it executes a
user-named Apple Shortcut) and `jev_rerank` (needs `MACUSE_OPEN_JEV=1` on the
server; shells the local TypeSafe CLI, max 10 candidates per call).

No daily quota exists in the code; any valid key works concurrently with any
other. If a call returns `isError: true` with "permission denied", the macOS
TCC grant (Calendar/Reminders/Full Disk Access) is missing — tell the user
exactly which one, do not retry in a loop.
