# cli-tap-out 🥋 — multiple Claude accounts for Claude CLI + OpenClaw

> **Plain English:** `cli-tap-out` lets one OpenClaw `claude-cli/*` model lane
> use multiple Claude subscription accounts. It wraps the `claude` CLI, selects
> the active OAuth token, and switches to the next configured account when the
> current one hits a Claude session limit.

Claude CLI is built around one active Claude auth identity at a time. This repo
adds the missing multi-account layer for OpenClaw: a profile pool, safe token
selection, real session-limit detection, cooldown tracking, and account failover
for the bundled `claude-cli` backend.

> **The name:** in combat sports, you *tap out* when a submission hold sinks in
> — and your fresh tag-team partner jumps in to keep the fight going.
> `cli-tap-out` does exactly that for Claude auth: when a rate limit chokes out
> the active account mid-stream, the router taps it out, benches it until its
> window resets, and tags in the next account. The match never stops.

Battle-tested on OpenClaw >= 2026.6.x with Claude Code stream-json live sessions.

## At a glance

| If you need... | `cli-tap-out` gives you... |
|---|---|
| Multiple Claude accounts working through Claude CLI | One `claude-cli/*` lane backed by several OAuth-token profiles |
| Automatic account switching on Claude session limits | Live rate-limit detection, profile cooldowns, and next-account rotation |
| OpenClaw compatibility | A command override for the existing `claude-cli` backend, not a forked backend |
| Auditable behavior | JSON state fields showing the active profile, cooldown source, and reset time |

This is **not** a generic model router, Anthropic API-key load balancer, or
replacement for Claude CLI. It is specifically the glue that makes multiple
Claude accounts usable from OpenClaw's Claude CLI backend.

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
   the `active` field in the profiles JSON (flock-protected),
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
   **Exception — all profiles exhausted:** when rotation finds no usable
   profile (every account cooling down), the router surfaces a REAL error
   instead (is_error result marked `router_all_profiles_exhausted: true` +
   non-zero exit). Masking that case as a success would block OpenClaw's
   native model fallback; a real provider failure lets OpenClaw hand the turn
   to the next model in `agents.defaults.model.fallbacks` (defaults/auto
   sessions — user-pinned sessions surface the error visibly by OpenClaw's
   design). The source-chat note still fires so a human sees why.
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
| `claude-auth-router.sh` | The router. Install to e.g. `~/scripts/` (or `/root/scripts/` on a root Linux host). |
| `claude-profiles.example.json` | Template for `~/.openclaw/claude-profiles.json`. |
| `openclaw-config-snippet.json5` | The one config change: `cliBackends.claude-cli.command`. |

## Requirements

- bash 3.2+ (stock macOS bash works — no bash-4isms), python3 (stdlib only —
  no pip installs)
- `timeout` (coreutils) is optional: the router auto-falls back to `gtimeout`
  (brew coreutils) or a bare background send for the chat notify
- `claude` CLI on PATH for the gateway user
- `openclaw` CLI on PATH (only needed for the source-chat notify; everything
  else works without it)

This router is for **multi-account** setups. If the host has a single Claude
login there is nothing to rotate — run `claude` directly and skip the kit.

## Install (on the target OpenClaw host)

Paths below use `~` — that's `/root` on a root Linux VPS, `/Users/<you>` on a
Mac. The profiles path defaults to `~/.openclaw/claude-profiles.json` for
whatever user runs the gateway; override with `CLAUDE_PROFILES_FILE` if needed.

1. **Script:**
   ```bash
   install -m 0755 claude-auth-router.sh ~/scripts/claude-auth-router.sh
   ```

2. **Profiles file:** copy `claude-profiles.example.json` to
   `~/.openclaw/claude-profiles.json`, rename profiles/labels to taste.
   Rules: `env_var` names must be shell-safe (`[A-Za-z_][A-Za-z0-9_]*`, no
   hyphens). A profile whose env var is unset/empty is skipped by rotation —
   handy for parking a disabled account.

3. **Active profile:** the JSON `active` field in `claude-profiles.json` is the
   single canonical switch. Set it in the profiles file:
   ```json
   { "active": "primary", "profiles": { ... } }
   ```
   The router rewrites it on rotation. To switch manually, edit the field:
   ```bash
   python3 -c 'import json,os;p=os.path.expanduser("~/.openclaw/claude-profiles.json");d=json.load(open(p));d["active"]="primary";json.dump(d,open(p,"w"),indent=2)'
   ```
   (Earlier versions used a standalone `claude-auth-active` file; it is retired
   and the router no longer reads or creates it.)

4. **Tokens:** generate one long-lived token per Claude account with
   `claude setup-token` (log in as that account, run it, log back into your
   main account — the token keeps working), then put them in the gateway's
   environment — `~/.openclaw/.env` (mode 600), plus the systemd unit env on
   Linux:
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
   ~/scripts/claude-auth-router.sh -p 'Reply exactly: ROUTER_OK' \
     --output-format json --model claude-haiku-4-5
   ```
   Then one real turn through OpenClaw on a `claude-cli/*` model.

## macOS notes (single-machine setup)

The router is Keychain-agnostic and works on a Mac as-is:

- macOS Claude CLI stores its *interactive-login* OAuth creds in the Keychain,
  but `CLAUDE_CODE_OAUTH_TOKEN` (which the router exports from the selected
  profile) **takes precedence** over stored creds. Router-managed runs never
  read or write the Keychain; your normal `claude` login stays untouched for
  ambient use.
- `claude setup-token` tokens are what go in the profile env vars — the
  Keychain is irrelevant to them.
- Stock bash 3.2 is fine (no bash-4isms); locking is Python `fcntl.flock`.
- `timeout` doesn't exist on stock macOS. The router auto-detects and uses
  `gtimeout` (from `brew install coreutils`) or falls back to a bare
  background send — the chat notify degrades gracefully, turns are never
  affected.
- Use absolute paths in `openclaw.json` (`/Users/<you>/scripts/...`), not `~`.

## Tuning (env vars, all optional)

| Var | Default | Meaning |
|-----|---------|---------|
| `CLAUDE_PROFILES_FILE` | `~/.openclaw/claude-profiles.json` | Profiles path (registry + `active` switch); `~` = the gateway user's home |
| `CLAUDE_AUTH_ROUTER_COOLDOWN_SECONDS` | `7200` | Fallback bench time for a limited profile, used only when the event's `resetsAt` is missing or fails sanity bounds. Claude limits run on ~5h windows; 2h keeps churn rare. |
| `CLAUDE_AUTH_ROUTER_ROTATE_ON_RATE_LIMIT` | `1` | Set `0` to disable rotation (friendly message only) |
| `CLAUDE_AUTH_ROUTER_ERROR_ON_EXHAUSTED` | `1` | When all profiles are limited, surface a real error so OpenClaw model fallback can fire. Set `0` for the old always-friendly synthetic success. |
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
