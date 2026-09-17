import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const router = fileURLToPath(new URL("../claude-auth-router.sh", import.meta.url));
function fixture(t, { events, exhausted = false, missingToken = false }) {
  const root = mkdtempSync(join(tmpdir(), "claude-router-integration-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const bin = join(root, "bin");
  mkdirSync(bin);
  const profilesFile = join(root, "profiles.json");
  const profiles = {
    active: "first",
    profiles: {
      first: { env_var: "TEST_ROUTER_FIRST", label: "First test profile" },
      second: {
        env_var: "TEST_ROUTER_SECOND",
        label: "Second test profile",
        ...(exhausted ? { cooldown_until: Math.floor(Date.now() / 1000) + 3600 } : {}),
      },
    },
  };
  const original = JSON.stringify(profiles, null, 2) + "\n";
  writeFileSync(profilesFile, original);
  const streamFile = join(root, "stream.jsonl");
  const stream = events.map((event) => JSON.stringify(event)).join("\n") + "\n";
  writeFileSync(streamFile, stream);
  const invoked = join(root, "invoked");
  const forbidden = join(root, "forbidden");
  writeFileSync(
    join(bin, "claude"),
    '#!/bin/sh\n[ "$CLAUDE_CODE_OAUTH_TOKEN" = "test-first-placeholder" ] || exit 96\n[ "$CLAUDE_PROFILE_NAME" = "first" ] || exit 95\n: > "$TEST_ROUTER_INVOKED"\ncat "$TEST_ROUTER_STREAM"\n',
    { mode: 0o755 },
  );
  // Defense in depth: even an accidental notification/network invocation stays local.
  for (const name of ["openclaw", "curl", "wget"])
    writeFileSync(join(bin, name), '#!/bin/sh\n: > "$TEST_ROUTER_FORBIDDEN"\nexit 97\n', {
      mode: 0o755,
    });
  // Deliberately construct a fresh environment. No real credentials, MCP chat context,
  // shell startup files, or user profile paths reach the tested process.
  const env = {
    PATH: `${bin}:/usr/bin:/bin`,
    HOME: root,
    TMPDIR: root,
    CLAUDE_PROFILES_FILE: profilesFile,
    TEST_ROUTER_SECOND: "test-second-placeholder",
    ...(missingToken ? {} : { TEST_ROUTER_FIRST: "test-first-placeholder" }),
    TEST_ROUTER_STREAM: streamFile,
    TEST_ROUTER_INVOKED: invoked,
    TEST_ROUTER_FORBIDDEN: forbidden,
    CLAUDE_AUTH_ROUTER_ERROR_ON_EXHAUSTED: "1",
  };
  const result = spawnSync("/bin/bash", [router, "-p", "--output-format", "stream-json"], {
    env,
    input: "unit test prompt\n",
    encoding: "utf8",
    timeout: 15000,
    maxBuffer: 1024 * 1024,
  });
  assert.equal(result.error, undefined, result.error?.message);
  assert.equal(existsSync(forbidden), false, "router attempted a notification or network tool");
  return {
    result,
    original,
    stream,
    invoked: existsSync(invoked),
    saved: readFileSync(profilesFile, "utf8"),
  };
}

test("shell router healthy subscription overage record passes JSONL without state mutation", (t) => {
  const f = fixture(t, {
    events: [
      {
        type: "rate_limit_event",
        rate_limit_info: {
          status: "allowed",
          overageStatus: "rejected",
          overageDisabledReason: "org_level_disabled",
        },
      },
      {
        type: "result",
        subtype: "success",
        result: "healthy test",
        session_id: "test-session",
        is_error: false,
      },
    ],
  });
  assert.equal(f.result.status, 0, f.result.stderr);
  assert.equal(f.invoked, true);
  assert.equal(f.result.stdout, f.stream);
  assert.equal(f.saved, f.original);
});

for (const rateLimitInfo of [
  { status: "rejected", overageStatus: "allowed", overageInUse: true },
  { status: "rejected", overageStatus: "allowed_warning", isUsingOverage: true },
]) {
  test(`shell router preserves paid overage when subscription is rejected (${rateLimitInfo.overageStatus})`, (t) => {
    const f = fixture(t, {
      events: [
        { type: "rate_limit_event", rate_limit_info: rateLimitInfo },
        {
          type: "result",
          subtype: "success",
          result: "paid overage test",
          session_id: "test-session",
          is_error: false,
        },
      ],
    });
    assert.equal(f.result.status, 0, f.result.stderr);
    assert.equal(f.invoked, true);
    assert.equal(f.result.stdout, f.stream);
    assert.equal(f.saved, f.original);
  });
}

test("shell router rejected limit rotates and preserves real reset time", (t) => {
  const resetsAt = Math.floor(Date.now() / 1000) + 1800;
  const f = fixture(t, {
    events: [{ type: "rate_limit_event", rate_limit_info: { status: "rejected", resetsAt } }],
  });
  assert.equal(f.result.status, 0, f.result.stderr);
  const saved = JSON.parse(f.saved);
  assert.equal(saved.active, "second");
  assert.equal(saved.profiles.first.cooldown_until, resetsAt);
  assert.equal(saved.profiles.first.cooldown_source, "resetsAt");
  const result = f.result.stdout
    .trim()
    .split("\n")
    .map(JSON.parse)
    .find((event) => event.type === "result");
  assert.equal(result.router_profile_rotated, true);
  assert.equal(result.router_next_profile, "second");
  assert.equal(result.is_error, false);
});

test("shell router exhausted accounts returns error result and nonzero exit", (t) => {
  const f = fixture(t, {
    exhausted: true,
    events: [{ type: "rate_limit_event", rate_limit_info: { status: "rejected" } }],
  });
  assert.notEqual(f.result.status, 0);
  assert.equal(f.result.signal, null);
  assert.equal(JSON.parse(f.saved).active, "first");
  const result = f.result.stdout
    .trim()
    .split("\n")
    .map(JSON.parse)
    .find((event) => event.type === "result");
  assert.equal(result.is_error, true);
  assert.equal(result.router_friendly_rate_limit, false);
});

test("shell router missing selected credential fails before launching CLI", (t) => {
  const f = fixture(t, {
    missingToken: true,
    events: [{ type: "result", result: "must not run" }],
  });
  assert.notEqual(f.result.status, 0);
  assert.equal(f.invoked, false);
  assert.equal(f.saved, f.original);
  assert.equal(f.result.stdout, "");
  assert.match(f.result.stderr, /expects token env var/);
});
