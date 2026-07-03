# claude-auth-router — multi-account rotation for OpenClaw's `claude-cli` backend

A bash wrapper that sits between OpenClaw and the `claude` CLI. It lets one
OpenClaw host run multiple Claude subscription accounts (OAuth tokens) behind a
single `claude-cli/*` model lane, and **auto-rotates to the next account when
one hits its session limit** — mid-turn, without wedging the session, with a
friendly "I switched accounts, resend your message" reply delivered to the chat.

Battle-tested on OpenClaw ≥ 2026.6.x with Claude Code stream-json live sessions.

## What it does

1. **Profile → token resolution.** Reads `claude-profiles.json`, picks the
   active profile, exports that profile's OAuth token as
   `CLAUDE_CODE_OAUTH_TOKEN`, then runs `claude` with all original args.
2. **Rate-limit detection (print/stream-json mode).** `claude` runs in the
   background with stdout on a FIFO; a python filter forwards events untouched
   and watches for real rate limits ("you've hit your session limit",
   `rate_limit_event` with `status:"rejected"`, HTTP 429/529). On detection it
   SIGTERMs the claude process (critical — in live sessions claude outlives the
   turn and a stranded process = stuck typing indicator forever).
3. **Rotation.** Marks the limited profile with a cooldown, atomically flips
   `active` in the JSON **and** the `claude-auth-active` file (flock-protected),
   and picks the next profile whose token env var is set and not cooling down.
   The cooldown uses the real reset time when available: the rejected
   `rate_limit_event` carries `rate_limit_info.resetsAt` (unix timestamp of the
   session-window reset), so the profile benches until exactly then
   (`cooldown_source: "resetsAt"` in the state file). Sanity bounds apply
   (must be in the future, ≤7 days out); missing/garbage values fall back to a
   flat cooldown (default 2h, `cooldown_source: "flat_fallback"`). Healthy
   turns write nothing — reset capture is failure-only by design.
4. **Friendly result.** Emits a synthetic assistant+result stream-json pair
   ("Claude hit a session limit 🧱, so I switched from X to Y 🔁. Please resend
   ⚡") so the gateway gets a clean turn end instead of an error.
5. **Source-chat notify.** Group-topic sessions never show final text upstream
   (openclaw#76424), so on rotation the router also fire-and-forgets the same
   message via `openclaw message send` into the source chat (topic-aware),
   using the `OPENCLAW_MCP_*` env vars the gateway already injects. Only fires
   for group / `message_tool_only` sessions to avoid DM duplicates.

Interactive (non `-p/--print`) invocations skip all of this and just
`exec claude` with the token exported.

## Files

| File | Purpose |
|------|---------|
| `claude-auth-router.sh` | The router. Install to e.g. `/root/scripts/`. |
| `claude-profiles.example.json` | Template for `/root/.openclaw/claude-profiles.json`. |
| `openclaw-config-snippet.json5` | The one config change: `cliBackends.claude-cli.command`. |

## Requirements

- bash, python3 (stdlib only — no pip installs), coreutils (`timeout`, `mkfifo`)
- `claude` CLI on PATH for the gateway user
- `openclaw` CLI on PATH (only needed for the source-chat notify; everything
  else works without it)

## Install (on the target OpenClaw host)

1. **Script:**
   ```bash
   install -m 0755 claude-auth-router.sh /root/scripts/claude-auth-router.sh
   ```

2. **Profiles file:** copy `claude-profiles.example.json` to
   `/root/.openclaw/claude-profiles.json`, rename profiles/labels to taste.
   Rules: `env_var` names must be shell-safe (`[A-Za-z_][A-Za-z0-9_]*`, no
   hyphens). A profile whose env var is unset/empty is skipped by rotation —
   handy for parking a disabled account.

3. **Active-profile file:**
   ```bash
   echo primary > /root/.openclaw/claude-auth-active
   ```
   This file is the canonical switch and **wins over** the JSON `active` field.
   The router rewrites both on rotation. Don't delete it — treat it as a shared
   contract if other tooling wants to know the current profile.

4. **Tokens:** generate one long-lived token per Claude account with
   `claude setup-token` (run as that account), then put them in the gateway's
   environment — e.g. `/root/.openclaw/.env` and/or the systemd unit env:
   ```bash
   ANTHROPIC_OAUTH_TOKEN1=sk-ant-oat01-...
   ANTHROPIC_OAUTH_TOKEN2=sk-ant-oat01-...
   ```
   Never put tokens in the profiles JSON or the script.

5. **Config:** merge `openclaw-config-snippet.json5` into `openclaw.json`
   (`agents.defaults.cliBackends.claude-cli.command` → the script path).
   Validate with `openclaw config validate`, then restart the gateway.

6. **Smoke test (as the gateway user, with the env loaded):**
   ```bash
   /root/scripts/claude-auth-router.sh -p 'Reply exactly: ROUTER_OK' \
     --output-format json --model claude-haiku-4-5
   ```
   Then one real turn through OpenClaw on a `claude-cli/*` model.

## Tuning (env vars, all optional)

| Var | Default | Meaning |
|-----|---------|---------|
| `CLAUDE_PROFILES_FILE` | `/root/.openclaw/claude-profiles.json` | Profiles path |
| `CLAUDE_AUTH_ACTIVE_FILE` | `/root/.openclaw/claude-auth-active` | Active-profile file |
| `CLAUDE_AUTH_ROUTER_COOLDOWN_SECONDS` | `7200` | Fallback bench time for a limited profile, used only when the event's `resetsAt` is missing or fails sanity bounds. Claude limits run on ~5h windows; 2h keeps churn rare. |
| `CLAUDE_AUTH_ROUTER_ROTATE_ON_RATE_LIMIT` | `1` | Set `0` to disable rotation (friendly message only) |
| `CLAUDE_AUTH_ROUTER_RATE_LIMIT_MESSAGE` | (built-in) | Override the user-facing limit message |

Pinning: `claude-auth-router.sh --auth-profile <name> ...` forces a profile and
disables rotation for that run (used by foreman-style dispatch tooling).

## Gotchas / hard-won lessons

- **Do NOT treat `overageStatus:"rejected"` as a rate limit.** Subscription
  orgs emit `rate_limit_event` with `overageStatus:"rejected"`
  (`org_level_disabled`) on *every* turn. Only the primary
  `rate_limit_info.status == "rejected"` field means the request was actually
  rejected. Getting this wrong kills every turn at start (stuck typing
  indicator + false rotations). The shipped detector is already correct.
- **The FIFO + PID-kill design is load-bearing.** A plain `claude | filter`
  pipeline can't kill claude when the filter finds a limit; in live sessions
  claude keeps running (stdin stays open), bash blocks on it, and the gateway
  never gets a result event. Don't "simplify" this back to a pipe.
- **`<&0` on the background claude is load-bearing too.** Live sessions stream
  stdin over it; a background job otherwise gets /dev/null stdin.
- **Live sessions pick up script changes only on respawn.** Sessions spawned
  before an edit keep the old process — abort once (or `/reset`) so the next
  message respawns through the new script.
- **Auth-profile switch invalidates stored CLI sessions** (OpenClaw drops
  claude session reuse when the auth identity changes). Expected: after a
  rotation the next turn starts a fresh claude session seeded by OpenClaw.
- **Notify lane is best-effort by design:** `timeout 15 ... & disown`. A missed
  notification is fine; a rotation blocked on a hung send is not.

## Architecture note

This is deliberately *not* an OpenClaw plugin. The plugin CLI-backend SDK
(`prepareExecution`, `defaultAuthProfileId`, `authEpochMode`) covers token
injection, but has no hook for live mid-stream detection with process control,
which is where all the value is. A command override on the bundled `claude-cli`
backend is the supported, upgrade-stable integration point
(`agents.defaults.cliBackends.<id>.command` is merged over plugin defaults).
Long-term, rate-limit-driven auth-profile rotation belongs upstream.
