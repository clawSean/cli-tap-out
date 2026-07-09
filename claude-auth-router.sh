#!/usr/bin/env bash
# Claude CLI auth router - exec-based, profile-driven, env-only.
# Resolves profile -> env_var from claude-profiles.json, exports
# CLAUDE_CODE_OAUTH_TOKEN from that env var, then execs claude.
#
# Active-profile selection precedence (highest first):
#   1. --auth-profile / --profile CLI flag
#   2. "active" field in claude-profiles.json  <-- single source of truth
#
# The old standalone claude-auth-active file is retired: claude-profiles.json
# holds both the profile registry and the active switch. Every consumer
# (this router, claude-foreman dispatch.sh, smoke-claude-profile.sh, the mac
# auth router) reads the JSON "active" field. On a rate-limit rotation this
# script rewrites the JSON "active" field under the profiles lock so the next
# run (and the foreman) picks up the new profile. To switch manually, edit
# the "active" field in claude-profiles.json.
#
# Token env var names must be shell-safe: [A-Za-z_][A-Za-z0-9_]* (no hyphens).

set -euo pipefail

PROFILES_FILE="${CLAUDE_PROFILES_FILE:-/root/.openclaw/claude-profiles.json}"
PROFILE=""
PROFILE_EXPLICIT=""

case "${1:-}" in
  --auth-profile|--profile)
    PROFILE="${2:?missing profile name after $1}"
    PROFILE_EXPLICIT=1
    shift 2
    ;;
  --auth-profile=*)
    PROFILE="${1#--auth-profile=}"
    PROFILE_EXPLICIT=1
    shift
    ;;
  --profile=*)
    PROFILE="${1#--profile=}"
    PROFILE_EXPLICIT=1
    shift
    ;;
  --)
    shift
    ;;
esac

if [[ -z "$PROFILE" ]]; then
  PROFILE="$(python3 -c '
import json, sys
try:
    print((json.load(open(sys.argv[1])).get("active") or "").strip())
except Exception:
    print("")
' "$PROFILES_FILE")"
fi
if [[ -z "$PROFILE" ]]; then
  echo "[claude-auth-router] No profile selected. Set \"active\" in $PROFILES_FILE or pass --auth-profile <name>." >&2
  exit 1
fi
if [[ ! -f "$PROFILES_FILE" ]]; then
  echo "[claude-auth-router] Profiles file not found: $PROFILES_FILE" >&2
  exit 1
fi

PROFILE_META="$(python3 -c '
import json, sys
profiles_file, profile = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(profiles_file))
except Exception as exc:
    print(f"ERROR\x1fCannot read {profiles_file}: {exc}")
    sys.exit(0)
entry = (data.get("profiles") or {}).get(profile)
if not isinstance(entry, dict):
    print("ERROR\x1fUnknown profile: " + profile)
    sys.exit(0)
env_var = str(entry.get("env_var") or "").strip()
label = str(entry.get("label") or profile).strip()
if not env_var:
    print("ERROR\x1fProfile has no env_var: " + profile)
else:
    print(env_var + "\x1f" + label)
' "$PROFILES_FILE" "$PROFILE")"

IFS=$'\x1f' read -r TOKEN_ENV_VAR PROFILE_LABEL <<< "$PROFILE_META"
if [[ "$TOKEN_ENV_VAR" == "ERROR" ]]; then
  echo "[claude-auth-router] $PROFILE_LABEL" >&2
  echo "[claude-auth-router] Profiles file: $PROFILES_FILE" >&2
  exit 1
fi
if [[ ! "$TOKEN_ENV_VAR" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "[claude-auth-router] Profile '$PROFILE' uses invalid env_var '$TOKEN_ENV_VAR'." >&2
  echo "[claude-auth-router] Env var names must match [A-Za-z_][A-Za-z0-9_]*." >&2
  exit 1
fi

TOKEN="${!TOKEN_ENV_VAR:-}"
if [[ -z "$TOKEN" ]]; then
  echo "[claude-auth-router] Profile '$PROFILE' expects token env var \$$TOKEN_ENV_VAR, but it is empty." >&2
  exit 1
fi

export CLAUDE_CODE_OAUTH_TOKEN="$TOKEN"
export CLAUDE_PROFILE_NAME="$PROFILE"
export CLAUDE_PROFILE_LABEL="$PROFILE_LABEL"

FRIENDLY_RATE_LIMIT_MESSAGE_OVERRIDE="${CLAUDE_AUTH_ROUTER_RATE_LIMIT_MESSAGE:-}"
FRIENDLY_RATE_LIMIT_MESSAGE_DEFAULT="Claude hit a session limit 🧱 before I could answer. Please try your last message again after the limit resets ⏳"
FRIENDLY_RATE_LIMIT_MESSAGE="${FRIENDLY_RATE_LIMIT_MESSAGE_OVERRIDE:-$FRIENDLY_RATE_LIMIT_MESSAGE_DEFAULT}"
# Claude session limits reset on ~5h windows; a short cooldown lets a limited
# profile re-enter rotation while still limited, costing one wasted "resend"
# turn per churn. 2h keeps churn rare without benching a profile past reset.
RATE_LIMIT_COOLDOWN_SECONDS="${CLAUDE_AUTH_ROUTER_COOLDOWN_SECONDS:-7200}"
RATE_LIMIT_PROFILE_ROTATED=""
RATE_LIMIT_NEXT_PROFILE=""
RATE_LIMIT_NEXT_PROFILE_LABEL=""
# Real reset time (unix epoch) captured from the failing turn's
# rate_limit_info.resetsAt. Only recorded on failure — healthy turns never
# touch the profiles state file. Empty means unknown → flat cooldown.
RATE_LIMIT_RESET_AT=""

NONINTERACTIVE=""
STREAM_JSON=""
JSON_OUTPUT=""
for arg in "$@"; do
  case "$arg" in
    -p|--print)
      NONINTERACTIVE=1
      ;;
    --output-format=stream-json)
      STREAM_JSON=1
      ;;
    --output-format=json)
      JSON_OUTPUT=1
      ;;
  esac
done
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == "--output-format" ]]; then
    next=$((i + 1))
    if [[ "$next" -le "$#" ]]; then
      case "${!next}" in
        stream-json)
          STREAM_JSON=1
          ;;
        json)
          JSON_OUTPUT=1
          ;;
      esac
    fi
  fi
done

if [[ -z "$NONINTERACTIVE" ]]; then
  exec claude "$@"
fi

set_rate_limit_message() {
  if [[ -n "$FRIENDLY_RATE_LIMIT_MESSAGE_OVERRIDE" ]]; then
    FRIENDLY_RATE_LIMIT_MESSAGE="$FRIENDLY_RATE_LIMIT_MESSAGE_OVERRIDE"
  elif [[ -n "$RATE_LIMIT_PROFILE_ROTATED" ]]; then
    FRIENDLY_RATE_LIMIT_MESSAGE="Claude hit a session limit 🧱, so I switched Claude from ${PROFILE_LABEL} to ${RATE_LIMIT_NEXT_PROFILE_LABEL} 🔁. Please send your last message again now ⚡"
  elif [[ -n "$PROFILE_EXPLICIT" ]]; then
    FRIENDLY_RATE_LIMIT_MESSAGE="Claude hit a session limit on the pinned ${PROFILE_LABEL} profile 📌 before I could answer. Please choose another Claude profile or try again after the limit resets ⏳"
  else
    FRIENDLY_RATE_LIMIT_MESSAGE="$FRIENDLY_RATE_LIMIT_MESSAGE_DEFAULT"
  fi
}

notify_source_chat() {
  # The friendly message below is emitted as the turn's final assistant text,
  # but group-topic sessions never show final text (upstream #76424) — the
  # gateway only delivers explicit message-tool/CLI sends there. When the
  # gateway marked this session message_tool_only (or it's a group session),
  # push the same message through `openclaw message send` into the source
  # chat. Fire-and-forget with a timeout: a missed notification is fine, a
  # blocked rotation is not.
  local channel_id="${OPENCLAW_MCP_CURRENT_CHANNEL_ID:-}"
  [[ -n "$channel_id" ]] || return 0
  local mode="${OPENCLAW_MCP_SOURCE_REPLY_DELIVERY_MODE:-}"
  if [[ "$mode" != "message_tool_only" && "${OPENCLAW_MCP_SESSION_KEY:-}" != *":group:"* ]]; then
    return 0  # final text is delivered normally; skip to avoid a duplicate
  fi
  local channel="${OPENCLAW_MCP_MESSAGE_CHANNEL:-${channel_id%%:*}}"
  local rest="${channel_id#*:}" target thread=""
  if [[ "$rest" == *":topic:"* ]]; then
    target="${rest%%:topic:*}"
    thread="${rest##*:topic:}"
  else
    target="$rest"
  fi
  [[ -n "$target" ]] || return 0
  local send_cmd=(openclaw message send --channel "$channel" --target "$target" -m "$FRIENDLY_RATE_LIMIT_MESSAGE")
  [[ -n "$thread" ]] && send_cmd+=(--thread-id "$thread")
  timeout 15 "${send_cmd[@]}" >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

rotate_rate_limited_profile() {
  RATE_LIMIT_PROFILE_ROTATED=""
  RATE_LIMIT_NEXT_PROFILE=""
  RATE_LIMIT_NEXT_PROFILE_LABEL=""

  if [[ "${CLAUDE_AUTH_ROUTER_ROTATE_ON_RATE_LIMIT:-1}" != "1" || -n "$PROFILE_EXPLICIT" ]]; then
    set_rate_limit_message
    notify_source_chat
    return
  fi

  if [[ ! "$RATE_LIMIT_COOLDOWN_SECONDS" =~ ^[0-9]+$ ]]; then
    RATE_LIMIT_COOLDOWN_SECONDS=7200
  fi

  local rotate_meta
  rotate_meta="$(
    CLAUDE_AUTH_ROUTER_PROFILES_FILE="$PROFILES_FILE" \
    CLAUDE_AUTH_ROUTER_CURRENT_PROFILE="$PROFILE" \
    CLAUDE_AUTH_ROUTER_COOLDOWN_SECONDS="$RATE_LIMIT_COOLDOWN_SECONDS" \
    CLAUDE_AUTH_ROUTER_RESET_AT="$RATE_LIMIT_RESET_AT" \
      python3 - <<'PY' || true
import fcntl
import json
import os
import tempfile
import time

sep = "\x1f"
profiles_file = os.environ["CLAUDE_AUTH_ROUTER_PROFILES_FILE"]
current = os.environ["CLAUDE_AUTH_ROUTER_CURRENT_PROFILE"]
cooldown_seconds = int(os.environ.get("CLAUDE_AUTH_ROUTER_COOLDOWN_SECONDS") or "7200")
try:
    reset_at = int(float(os.environ.get("CLAUDE_AUTH_ROUTER_RESET_AT") or 0))
except Exception:
    reset_at = 0
now = int(time.time())

def emit(*parts):
    print(sep.join(str(p).replace(sep, " ") for p in parts))

def cooldown_until(entry):
    try:
        return int(float(entry.get("cooldown_until") or 0))
    except Exception:
        return 0

try:
    lock_path = profiles_file + ".lock"
    with open(lock_path, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with open(profiles_file) as fh:
            data = json.load(fh)
        profiles = data.get("profiles") or {}
        if not isinstance(profiles, dict) or current not in profiles:
            emit("NO_PROFILE", "", "")
            raise SystemExit(0)

        current_entry = profiles[current]
        if isinstance(current_entry, dict):
            # Prefer the real window reset from rate_limit_info.resetsAt over
            # the flat fallback cooldown. Sanity bounds: must be in the future
            # and within 7 days (guards against garbage/clock skew).
            if now < reset_at <= now + 7 * 24 * 3600:
                current_entry["cooldown_until"] = reset_at
                current_entry["cooldown_source"] = "resetsAt"
                current_entry["limit_resets_at"] = reset_at
            else:
                current_entry["cooldown_until"] = now + cooldown_seconds
                current_entry["cooldown_source"] = "flat_fallback"
                current_entry.pop("limit_resets_at", None)
            current_entry["cooldown_reason"] = "rate_limit"
            current_entry["last_failed_at"] = now
            current_entry["last_error"] = "Claude session limit"

        ready = []
        later = []
        for name, entry in profiles.items():
            if name == current or not isinstance(entry, dict):
                continue
            env_var = str(entry.get("env_var") or "").strip()
            if not env_var or not os.environ.get(env_var):
                continue
            label = str(entry.get("label") or name).strip()
            item = (name, label)
            if cooldown_until(entry) > now:
                later.append(item)
            else:
                ready.append(item)

        next_profile = ready[0] if ready else None
        if next_profile:
            data["active"] = next_profile[0]

        directory = os.path.dirname(profiles_file) or "."
        fd, tmp_path = tempfile.mkstemp(prefix=".claude-profiles.", suffix=".json", dir=directory)
        with os.fdopen(fd, "w") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")
        os.replace(tmp_path, profiles_file)

        if next_profile:
            emit("ROTATED", next_profile[0], next_profile[1])
        else:
            emit("NO_READY_PROFILE", "", "")
except Exception as exc:
    emit("ERROR", "", str(exc))
PY
  )"

  local rotate_status rotate_profile rotate_label
  IFS=$'\x1f' read -r rotate_status rotate_profile rotate_label <<< "$rotate_meta"
  if [[ "$rotate_status" == "ROTATED" && -n "$rotate_profile" ]]; then
    RATE_LIMIT_PROFILE_ROTATED=1
    RATE_LIMIT_NEXT_PROFILE="$rotate_profile"
    RATE_LIMIT_NEXT_PROFILE_LABEL="${rotate_label:-$rotate_profile}"
  fi

  set_rate_limit_message
  notify_source_chat
}

emit_friendly_stream_json() {
  CLAUDE_AUTH_ROUTER_RATE_LIMIT_MESSAGE="$FRIENDLY_RATE_LIMIT_MESSAGE" \
  CLAUDE_AUTH_ROUTER_RATE_LIMIT_PROFILE="$PROFILE" \
  CLAUDE_AUTH_ROUTER_RATE_LIMIT_PROFILE_LABEL="$PROFILE_LABEL" \
  CLAUDE_AUTH_ROUTER_PROFILE_ROTATED="$RATE_LIMIT_PROFILE_ROTATED" \
  CLAUDE_AUTH_ROUTER_NEXT_PROFILE="$RATE_LIMIT_NEXT_PROFILE" \
  CLAUDE_AUTH_ROUTER_NEXT_PROFILE_LABEL="$RATE_LIMIT_NEXT_PROFILE_LABEL" \
    python3 - <<'PY'
import json, os, time

message = os.environ["CLAUDE_AUTH_ROUTER_RATE_LIMIT_MESSAGE"]
session_id = "claude-auth-router-rate-limit"
assistant = {
    "type": "assistant",
    "message": {
        "id": session_id,
        "type": "message",
        "role": "assistant",
        "content": [{"type": "text", "text": message}],
        "stop_reason": "end_turn",
    },
    "session_id": session_id,
}
result = {
    "type": "result",
    "subtype": "success",
    "is_error": False,
    "api_error_status": None,
    "duration_ms": 0,
    "duration_api_ms": 0,
    "num_turns": 1,
    "result": message,
    "stop_reason": "end_turn",
    "session_id": session_id,
    "total_cost_usd": 0,
    "usage": {
        "input_tokens": 0,
        "cache_creation_input_tokens": 0,
        "cache_read_input_tokens": 0,
        "output_tokens": 0,
    },
    "modelUsage": {},
    "permission_denials": [],
    "terminal_reason": "completed",
    "router_friendly_rate_limit": True,
    "router_rate_limited_profile": os.environ.get("CLAUDE_AUTH_ROUTER_RATE_LIMIT_PROFILE") or None,
    "router_rate_limited_profile_label": os.environ.get("CLAUDE_AUTH_ROUTER_RATE_LIMIT_PROFILE_LABEL") or None,
    "router_profile_rotated": os.environ.get("CLAUDE_AUTH_ROUTER_PROFILE_ROTATED") == "1",
    "router_next_profile": os.environ.get("CLAUDE_AUTH_ROUTER_NEXT_PROFILE") or None,
    "router_next_profile_label": os.environ.get("CLAUDE_AUTH_ROUTER_NEXT_PROFILE_LABEL") or None,
    "router_emitted_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}
print(json.dumps(assistant, ensure_ascii=False, separators=(",", ":")))
print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
PY
}

is_rate_limit_file() {
  python3 - "$1" <<'PY'
import pathlib, re, sys

path = pathlib.Path(sys.argv[1])
try:
    text = path.read_text(errors="replace")
except Exception:
    text = ""

patterns = [
    r"\byou(?:'ve| have) hit your session limit\b",
    r'"api_error_status"\s*:\s*"?(?:429|529)"?',
    r'"error"\s*:\s*"rate_limit"',
    r'"rate_limit_info"\s*:\s*\{[^}]*"status"\s*:\s*"rejected"',
    r"\busage limit\b",
    r"\brate[- ]?limit(?:ed)?\b",
    r"\btoo many concurrent requests\b",
]
raise SystemExit(0 if any(re.search(p, text, re.I | re.S) for p in patterns) else 1)
PY
}

# Pull the last "resetsAt": <epoch> out of a raw output/stderr capture, for
# failure paths that bypass the stream filter. Prints nothing if absent.
extract_reset_at_file() {
  sed -n 's/.*"resetsAt"[[:space:]]*:[[:space:]]*\([0-9]\{1,\}\).*/\1/p' "$1" 2>/dev/null | tail -n 1
}

if [[ -n "$STREAM_JSON" ]]; then
  TMPERR="$(mktemp)"
  TMPFLAG="$(mktemp)"
  FIFO_DIR="$(mktemp -d)"
  STREAM_FIFO="$FIFO_DIR/claude-stdout"
  mkfifo "$STREAM_FIFO"
  trap 'rm -f "$TMPERR" "$TMPFLAG"; rm -rf "$FIFO_DIR"' EXIT

  set +e
  # claude runs in the background with stdout on a FIFO (instead of a plain
  # `claude | filter` pipeline) so the filter knows claude's PID and can kill
  # it when it detects a real rate limit. In a live session claude outlives
  # the turn (stdin stays open), so a filter that merely exits leaves bash
  # blocked on a still-running claude: the gateway never receives a result
  # event and the typing indicator sticks until a manual abort.
  # <&0 keeps the caller's stdin attached — live sessions stream stdin over
  # it, and bash would otherwise point a background job's stdin at /dev/null.
  claude "$@" <&0 >"$STREAM_FIFO" 2>"$TMPERR" &
  CLAUDE_PID=$!
  CLAUDE_AUTH_ROUTER_CLAUDE_PID="$CLAUDE_PID" \
    CLAUDE_AUTH_ROUTER_RATE_LIMIT_FLAG="$TMPFLAG" \
    CLAUDE_AUTH_ROUTER_RATE_LIMIT_MESSAGE="$FRIENDLY_RATE_LIMIT_MESSAGE" \
    python3 -u -c '
import json, os, re, signal, sys, time

flag_path = os.environ["CLAUDE_AUTH_ROUTER_RATE_LIMIT_FLAG"]
message = os.environ["CLAUDE_AUTH_ROUTER_RATE_LIMIT_MESSAGE"]
claude_pid = int(os.environ.get("CLAUDE_AUTH_ROUTER_CLAUDE_PID") or 0)
rate_limited = False
# Last resetsAt seen on any rate_limit_event this turn (in-memory only; the
# rejected event itself normally carries it). Persisted ONLY on failure via
# the flag file — healthy turns write nothing anywhere.
reset_at = 0

def write_flag():
    try:
        with open(flag_path, "w") as fh:
            fh.write("1\n")
            if reset_at > 0:
                fh.write(str(reset_at) + "\n")
    except Exception:
        pass

def mark_and_exit():
    write_flag()
    # Terminate claude too: exiting the filter alone strands a live-session
    # claude process and wedges the shell behind it (stuck typing indicator).
    if claude_pid > 0:
        try:
            os.kill(claude_pid, signal.SIGTERM)
        except Exception:
            pass
    # Exit with a distinctive code so the shell can rotate immediately.
    sys.exit(10)

def has_session_limit_text(ev):
    texts = []
    if isinstance(ev, dict):
        msg = ev.get("message") or {}
        if isinstance(msg, dict):
            content = msg.get("content") or []
            for item in content:
                if isinstance(item, dict) and item.get("type") == "text":
                    txt = item.get("text")
                    if isinstance(txt, str):
                        texts.append(txt)
        # Sometimes the text is embedded directly.
        for key in ("text", "result"):
            val = ev.get(key)
            if isinstance(val, str):
                texts.append(val)
    return any(re.search(r"\byou(?:'\''ve| have) hit your session limit\b", t, re.I) for t in texts)

def rejected_rate_limit(ev):
    global reset_at
    if not isinstance(ev, dict):
        return False
    if ev.get("type") == "rate_limit_event":
        info = ev.get("rate_limit_info") or {}
        if not isinstance(info, dict):
            return False
        try:
            candidate = int(float(info.get("resetsAt") or 0))
        except Exception:
            candidate = 0
        if candidate > 0:
            reset_at = candidate
        status = str(info.get("status") or "").lower()
        # overageStatus:"rejected" with org_level_disabled is a permanent,
        # normal state on subscription orgs (no overage billing) — it fires on
        # EVERY turn and must not be treated as a rate limit. Only the primary
        # status field says whether this request was actually rejected.
        return status == "rejected"
    if ev.get("error") == "rate_limit" or ev.get("error") == "overage":
        return True
    if has_session_limit_text(ev):
        return True
    if ev.get("type") == "result":
        status = str(ev.get("api_error_status") or ev.get("apiErrorStatus") or "")
        result = str(ev.get("result") or "")
        return status in {"429", "529"} or re.search(r"\byou(?:'\''ve| have) hit your session limit\b", result, re.I) is not None
    return False

def emit_friendly():
    session_id = "claude-auth-router-rate-limit"
    assistant = {
        "type": "assistant",
        "message": {
            "id": session_id,
            "type": "message",
            "role": "assistant",
            "content": [{"type": "text", "text": message}],
            "stop_reason": "end_turn",
        },
        "session_id": session_id,
    }
    result = {
        "type": "result",
        "subtype": "success",
        "is_error": False,
        "api_error_status": None,
        "duration_ms": 0,
        "duration_api_ms": 0,
        "num_turns": 1,
        "result": message,
        "stop_reason": "end_turn",
        "session_id": session_id,
        "total_cost_usd": 0,
        "usage": {
            "input_tokens": 0,
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 0,
            "output_tokens": 0,
        },
        "modelUsage": {},
        "permission_denials": [],
        "terminal_reason": "completed",
        "router_friendly_rate_limit": True,
        "router_emitted_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    print(json.dumps(assistant, ensure_ascii=False, separators=(",", ":")), flush=True)
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")), flush=True)

for line in sys.stdin:
    raw = line.rstrip("\n")
    try:
        ev = json.loads(raw)
    except Exception:
        if re.search(r"\byou(?:'\''ve| have) hit your session limit\b", raw, re.I):
            mark_and_exit()
            continue
        print(raw, flush=True)
        continue
    if rejected_rate_limit(ev):
        mark_and_exit()
    print(raw, flush=True)
' <"$STREAM_FIFO"
  FILTER_STATUS=$?
  # Normally claude has already exited (its EOF is what ends the filter). If
  # the filter TERMed it on a rate limit, give it a moment to die, then
  # force-kill so the router can never wedge behind a live process again.
  for _ in $(seq 1 25); do
    kill -0 "$CLAUDE_PID" 2>/dev/null || break
    sleep 0.2
  done
  kill -KILL "$CLAUDE_PID" 2>/dev/null
  wait "$CLAUDE_PID"
  CLAUDE_STATUS=$?
  set -e

  if [[ -s "$TMPFLAG" || "$FILTER_STATUS" -eq 10 ]]; then
    RATE_LIMIT_RESET_AT="$(sed -n '2p' "$TMPFLAG" 2>/dev/null | tr -cd '0-9')"
    [[ -n "$RATE_LIMIT_RESET_AT" ]] || RATE_LIMIT_RESET_AT="$(extract_reset_at_file "$TMPERR")"
    rotate_rate_limited_profile
    emit_friendly_stream_json
    exit 0
  fi
  if [[ "$CLAUDE_STATUS" -ne 0 ]] && is_rate_limit_file "$TMPERR"; then
    RATE_LIMIT_RESET_AT="$(extract_reset_at_file "$TMPERR")"
    rotate_rate_limited_profile
    emit_friendly_stream_json
    exit 0
  fi
  if [[ -s "$TMPERR" ]]; then
    cat "$TMPERR" >&2
  fi
  if [[ "$FILTER_STATUS" -ne 0 ]]; then
    exit "$FILTER_STATUS"
  fi
  exit "$CLAUDE_STATUS"
fi

TMPOUT="$(mktemp)"
TMPERR="$(mktemp)"
trap 'rm -f "$TMPOUT" "$TMPERR"' EXIT
set +e
claude "$@" >"$TMPOUT" 2>"$TMPERR"
CLAUDE_STATUS=$?
set -e

if [[ "$CLAUDE_STATUS" -ne 0 ]] && { is_rate_limit_file "$TMPOUT" || is_rate_limit_file "$TMPERR"; }; then
  RATE_LIMIT_RESET_AT="$(extract_reset_at_file "$TMPOUT")"
  [[ -n "$RATE_LIMIT_RESET_AT" ]] || RATE_LIMIT_RESET_AT="$(extract_reset_at_file "$TMPERR")"
  rotate_rate_limited_profile
  if [[ -n "$JSON_OUTPUT" ]]; then
    CLAUDE_AUTH_ROUTER_RATE_LIMIT_MESSAGE="$FRIENDLY_RATE_LIMIT_MESSAGE" \
    CLAUDE_AUTH_ROUTER_RATE_LIMIT_PROFILE="$PROFILE" \
    CLAUDE_AUTH_ROUTER_RATE_LIMIT_PROFILE_LABEL="$PROFILE_LABEL" \
    CLAUDE_AUTH_ROUTER_PROFILE_ROTATED="$RATE_LIMIT_PROFILE_ROTATED" \
    CLAUDE_AUTH_ROUTER_NEXT_PROFILE="$RATE_LIMIT_NEXT_PROFILE" \
    CLAUDE_AUTH_ROUTER_NEXT_PROFILE_LABEL="$RATE_LIMIT_NEXT_PROFILE_LABEL" \
      python3 - <<'PY'
import json, os
message = os.environ["CLAUDE_AUTH_ROUTER_RATE_LIMIT_MESSAGE"]
print(json.dumps({
    "type": "result",
    "subtype": "success",
    "is_error": False,
    "result": message,
    "total_cost_usd": 0,
    "num_turns": 1,
    "session_id": "claude-auth-router-rate-limit",
    "router_friendly_rate_limit": True,
    "router_rate_limited_profile": os.environ.get("CLAUDE_AUTH_ROUTER_RATE_LIMIT_PROFILE") or None,
    "router_rate_limited_profile_label": os.environ.get("CLAUDE_AUTH_ROUTER_RATE_LIMIT_PROFILE_LABEL") or None,
    "router_profile_rotated": os.environ.get("CLAUDE_AUTH_ROUTER_PROFILE_ROTATED") == "1",
    "router_next_profile": os.environ.get("CLAUDE_AUTH_ROUTER_NEXT_PROFILE") or None,
    "router_next_profile_label": os.environ.get("CLAUDE_AUTH_ROUTER_NEXT_PROFILE_LABEL") or None,
}, ensure_ascii=False, separators=(",", ":")))
PY
  else
    printf '%s\n' "$FRIENDLY_RATE_LIMIT_MESSAGE"
  fi
  exit 0
fi

cat "$TMPOUT"
if [[ -s "$TMPERR" ]]; then
  cat "$TMPERR" >&2
fi
exit "$CLAUDE_STATUS"
