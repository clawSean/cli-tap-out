import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import provider, { routerAuthReady, AUTH_MARKER } from "../src/provider.mjs";
test("readiness requires selected profile valid env name and token presence", async () => {
  const dir = mkdtempSync(join(tmpdir(), "claude-provider-test-"));
  const file = join(dir, "profiles.json");
  try {
    const env = { CLAUDE_PROFILES_FILE: file, UNIT_FAKE_TOKEN: "test-placeholder" };
    assert.equal(await routerAuthReady(env), false);
    writeFileSync(
      file,
      JSON.stringify({ active: "test", profiles: { test: { env_var: "UNIT_FAKE_TOKEN" } } }),
    );
    assert.equal(await routerAuthReady(env), true);
    assert.equal(await routerAuthReady({ ...env, UNIT_FAKE_TOKEN: "" }), false);
    writeFileSync(
      file,
      JSON.stringify({ active: "missing", profiles: { test: { env_var: "UNIT_FAKE_TOKEN" } } }),
    );
    assert.equal(await routerAuthReady(env), false);
    writeFileSync(
      file,
      JSON.stringify({ active: "test", profiles: { test: { env_var: "BAD;NAME" } } }),
    );
    assert.equal(await routerAuthReady(env), false);
    assert.equal(await provider.prepareSyntheticAuth({ provider: "anthropic", env }), undefined);
    assert.equal(provider.id, "claude");
    assert.equal(AUTH_MARKER, "openclaw:claude-router-native-auth");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
test("prepared auth uses captured environment and returns only marker despite cooldown", async () => {
  const dir = mkdtempSync(join(tmpdir(), "claude-provider-capture-"));
  const file = join(dir, "profiles.json");
  try {
    writeFileSync(
      file,
      JSON.stringify({
        active: "test",
        profiles: { test: { env_var: "UNIT_FAKE_TOKEN", cooldownUntil: Date.now() + 600000 } },
      }),
    );
    const env = { CLAUDE_PROFILES_FILE: file, UNIT_FAKE_TOKEN: "test-placeholder-not-a-secret" };
    const result = await provider.prepareSyntheticAuth({ provider: "claude", env });
    assert.equal(result.apiKey, AUTH_MARKER);
    assert.equal(result.mode, "oauth");
    assert.ok(!JSON.stringify(result).includes(env.UNIT_FAKE_TOKEN));
    assert.equal(
      await provider.prepareSyntheticAuth({
        provider: "claude",
        env: { CLAUDE_PROFILES_FILE: file },
      }),
      undefined,
    );
    assert.equal(provider.resolveSyntheticAuth, undefined);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
test("preparation checks cancellation before I/O and after readiness read", async () => {
  const controller = new AbortController();
  controller.abort(new Error("cancelled-test"));
  await assert.rejects(
    provider.prepareSyntheticAuth({
      provider: "claude",
      env: { CLAUDE_PROFILES_FILE: "/not-used" },
      signal: controller.signal,
    }),
    /cancelled-test/,
  );
  let checks = 0;
  const signal = {
    throwIfAborted() {
      if (++checks === 2) throw new Error("cancelled-after-read");
    },
  };
  await assert.rejects(
    provider.prepareSyntheticAuth({
      provider: "claude",
      env: { CLAUDE_PROFILES_FILE: "/does-not-exist" },
      signal,
    }),
    /cancelled-after-read/,
  );
  assert.equal(checks, 2);
});
