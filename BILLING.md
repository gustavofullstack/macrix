# MACRIX billing — account-server contract (v0.24)

Local metering is DONE and enforced in-server (`Usage.swift`):
quotas per tier (free 1000/day, starter 10k, growth 50k, scale 200k,
max/lifetime unlimited), per key-fingerprint, per UTC day, over-quota
error -32000. Visible via `usage_status` tool and `GET /usage` (Bearer).

What is NOT built (needs the owner, not the agent):

1. **Stripe (or/e) account + products.** Prices are fixed in code
   (`License.Tier.priceUSD`: 0/20/50/100/200, lifetime one-time):
   create one product per tier, monthly, USD.
2. **Account server** (any stack) implementing:
   - `POST /issue` — after checkout.session.completed webhook: write
     `tier=<t>/key=mx_<t>_<rand>/expires=<yyyy-mm-dd>` to the buyer's
     `~/.config/macrix/license` (same 3-line format `License.issue`
     writes today; the server keeps writing it — format is stable).
   - `POST /cancel` — on subscription.deleted: rewrite the file with
     `tier=free` (server auto-downgrades expired paid tiers already).
   - Webhook verification with the Stripe signing secret (never in repo).
3. **rates.json** (`~/.config/macrix/rates.json`, `model -> $/Mtok in/out`)
   filled from real invoices — only then does `providers_spend`
   print USD. Until then it says n/a, on purpose.
4. **Founder rule, unchanged:** price = 2x measured Jev cost. Recompute
   quarterly from invoices before touching `priceUSD`.

Nothing here invents charges: no card is touched, no trial converts,
downgrade is automatic on expiry. When the owner green-lights Stripe,
this file is the checklist — no code changes needed in macrix itself.
