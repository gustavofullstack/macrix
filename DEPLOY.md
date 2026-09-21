# MACRIX deploy — production checklist (v0.24.2)

This file makes production deploy actionable for the owner WITHOUT the
agent touching production. No step here runs itself.

## What runs where

- macrix is a single Swift binary, loopback-only (`127.0.0.1:35730`).
  Production needs: a host (VPS), a reverse path (Tailscale or tunnel),
  keys, and a license file. Nothing else.
- Apple-only tools degrade gracefully on Linux (each shells a missing
  binary and returns "...unavailable." — verified pattern, no crash):
  calendar, reminders, notes, shortcuts, sips/afinfo media, `open`,
  pbcopy/pbpaste, osascript notify/tts. Core stays green: MCP, 100-tool
  registry minus Apple-only, metering, quotas, Chromium (needs install,
  below), Jev (needs `typesafe` + key on the host).

## Checklist (owner order)

1. **Host**: Linux VPS (EasyPanel can host it as a generic app).
   Build with the official Swift image (`swift:6.0-jammy`,
   `swift build -c release`); the macOS binary does NOT run on Linux.
2. **Chromium**: install `chrome-headless-shell` (Playwright) where
   `Web.browser()` looks (Playwright cache path or Google Chrome.app).
   Custom paths need a small patch in Web.swift — not done until
   ordered; today there is no `CHROME_BIN` support.
3. **Keys**: create `keys` file (one `mcp_…` per line, 600), mount or
   env-generate on first boot. NEVER reuse the Mac's keys file.
4. **License**: write `license` (`tier=`/`key=`/`expires=`, same format
   as `License.issue`). Server auto-downgrades expired paid tiers.
5. **Network**: do NOT expose 35730 publicly. Reach it via Tailscale
   (`tailscale serve` on the host) or a Cloudflare Tunnel in front.
   The server has no TLS and no brute-force backoff by design.
6. **Healthcheck**: `GET /health` (no auth) for the orchestrator;
   alert on `tier` flip or `requests` stall.
7. **Billing**: finish `BILLING.md` first (Stripe products + webhooks),
   else every key runs free-1000/day.

## Explicitly NOT done by agents

Restart/kill/scale/deploy on any production host, editing prod keys
or license files, opening ports, creating tunnels. Those need the
owner's explicit order for that action (house rule, unchanged).
