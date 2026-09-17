import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import {
  buildClaudeBackend,
  resolveExecutionArgs,
  projectNativeToolAuthority,
  parseJsonlLifecycleEvent,
} from "../src/backend.mjs";
const base = { baseArgs: ["-p", "--output-format", "stream-json"], executionMode: "agent" };
const value = (args, flag) => args[args.indexOf(flag) + 1];
test("standalone identity and generic supervised stream contract", () => {
  const b = buildClaudeBackend({ command: "/opt/router.sh" });
  assert.equal(b.id, "claude");
  assert.equal(b.modelProvider, undefined);
  assert.equal(b.config.command, "/opt/router.sh");
  assert.equal(b.config.jsonlDialect, "claude-stream-json");
  assert.equal(b.config.liveSession, undefined);
  assert.equal(b.prepareExecution({}).execute, undefined);
  assert.equal(b.bundleMcpMode, "claude-config-file");
  assert.equal(b.autoSelectAuthProfile, false);
  assert.deepEqual(b.config.resumeArgs.slice(-2), ["--resume", "{sessionId}"]);
  assert.equal(b.config.sessionArgs[1], "{sessionId}");
});
test("command defaults to packaged router and rejects relative execution", () => {
  assert.match(buildClaudeBackend().config.command, /claude-auth-router.sh$/);
  assert.throws(() => buildClaudeBackend({ command: "router.sh" }), /absolute/);
});
test("normal execution exposes only host MCP and no native tools", () => {
  const args = resolveExecutionArgs(base);
  assert.equal(value(args, "--tools"), "");
  assert.equal(value(args, "--allowedTools"), "mcp__openclaw__*");
  assert.equal(value(args, "--permission-mode"), "default");
  assert.ok(args.includes("--strict-mcp-config"));
});

test("host-prepared MCP connection survives argument projection", () => {
  const args = resolveExecutionArgs({
    ...base,
    baseArgs: [...base.baseArgs, "--strict-mcp-config", "--mcp-config", "/tmp/host-mcp.json"],
    toolAvailability: { native: [], openClaw: ["read"] },
  });
  assert.equal(value(args, "--mcp-config"), "/tmp/host-mcp.json");
  assert.equal(args.filter((arg) => arg === "--strict-mcp-config").length, 1);
  assert.equal(value(args, "--allowedTools"), "mcp__openclaw__read");
});
test("exact native and MCP selections remove ambient grants and instructions", () => {
  const args = resolveExecutionArgs({
    ...base,
    baseArgs: [
      ...base.baseArgs,
      "--tools",
      "default",
      "--allowedTools=*",
      "--settings",
      "/tmp/unsafe.json",
      "--plugin-dir",
      "/tmp/plugin",
      "--dangerously-skip-permissions",
      "--disallowedTools",
      "WebSearch",
    ],
    toolAvailability: { native: ["Read", "Bash"], openClaw: ["read", "session_status"] },
  });
  assert.equal(value(args, "--tools"), "Read,Bash");
  assert.equal(value(args, "--allowedTools"), "mcp__openclaw__read,mcp__openclaw__session_status");
  assert.ok(!args.includes("/tmp/plugin"));
  assert.ok(!args.includes("/tmp/unsafe.json"));
  assert.ok(!args.includes("--dangerously-skip-permissions"));
  assert.equal(value(args, "--setting-sources"), "");
  assert.equal(JSON.parse(value(args, "--settings")).disableAllHooks, true);
  assert.match(value(args, "--disallowedTools"), /WebSearch/);
  assert.match(value(args, "--disallowedTools"), /run_in_background/);
});
test("empty exact selections explicitly deny all MCP", () => {
  const args = resolveExecutionArgs({ ...base, toolAvailability: { native: [], openClaw: [] } });
  assert.ok(!args.includes("--allowedTools"));
  assert.match(value(args, "--disallowedTools"), /mcp__\*/);
});
test("wildcard and argument injection fail closed", () => {
  for (const name of ["*", "Bash(*)", "--dangerously-skip-permissions", "read,exec"])
    assert.throws(
      () => resolveExecutionArgs({ ...base, toolAvailability: { native: [name], openClaw: [] } }),
      /Invalid exact/,
    );
  assert.throws(
    () => resolveExecutionArgs({ ...base, executionMode: "side-question" }),
    /does not support/,
  );
});
test("native authority never implies process or unsupported tools", () => {
  assert.deepEqual(projectNativeToolAuthority(["Read", "Bash", "Glob", "NotebookEdit"]), [
    "read",
    "exec",
  ]);
});
test("compaction requires positive terminal acknowledgement", () => {
  const control = buildClaudeBackend().manualCompaction;
  assert.equal(
    control.validateOutput('{"type":"system","subtype":"status","status":"compacting"}').ok,
    false,
  );
  assert.equal(control.validateOutput('{"compact_result":"failed"}').ok, false);
  assert.equal(control.validateOutput('{"type":"system","subtype":"compact_boundary"}').ok, true);
  assert.equal(parseJsonlLifecycleEvent("noise"), null);
});
test("manifest and source contain no private runtime imports or Anthropic identity", () => {
  const manifest = JSON.parse(readFileSync(new URL("../openclaw.plugin.json", import.meta.url)));
  assert.deepEqual(manifest.cliBackends, ["claude"]);
  assert.deepEqual(manifest.setup.cliBackends, ["claude"]);
  for (const name of readdirSync(new URL("../src/", import.meta.url))) {
    const src = readFileSync(new URL("../src/" + name, import.meta.url), "utf8");
    assert.doesNotMatch(
      src,
      /extensions\/anthropic|buildAnthropicCliBackend|import\.meta\.resolve|modelProvider:\s*["']anthropic/,
    );
  }
});
