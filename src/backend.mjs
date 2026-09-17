import { fileURLToPath } from "node:url";
import { isAbsolute } from "node:path";

export const BACKEND_ID = "claude";
const DEFAULT_ARGS = [
  "-p",
  "--output-format",
  "stream-json",
  "--include-partial-messages",
  "--verbose",
];
const DENIALS = ["ScheduleWakeup", "CronCreate", "Bash(run_in_background:true)", "Monitor"];
const RESTRICTED_SETTINGS = JSON.stringify({
  disableAllHooks: true,
  enabledPlugins: {},
  autoMemoryEnabled: false,
  claudeMdExcludes: ["**/CLAUDE.md", "**/CLAUDE.local.md", "**/.claude/rules/**"],
});
const NATIVE_CAPS = {
  read: "read",
  grep: "read",
  write: "write",
  edit: "edit",
  bash: "exec",
  webfetch: "web_fetch",
  websearch: "web_search",
};
const VALUE_FLAGS = new Set([
  "--setting-sources",
  "--settings",
  "--agent",
  "--agents",
  "--managed-settings",
  "--plugin-dir",
  "--plugin-dir-no-mcp",
  "--plugin-url",
  "--system-prompt",
  "--system-prompt-file",
  "--append-system-prompt",
  "--append-system-prompt-file",
  "--permission-mode",
  "--effort",
]);
const VARIADIC_FLAGS = new Set([
  "--tools",
  "--allowedTools",
  "--allowed-tools",
  "--disallowedTools",
  "--disallowed-tools",
  "--add-dir",
  "--file",
]);
const BARE_FLAGS = new Set([
  "--bare",
  "--safe-mode",
  "--disable-slash-commands",
  "--chrome",
  "--no-chrome",
  "--strict-mcp-config",
  "--dangerously-skip-permissions",
  "--allow-dangerously-skip-permissions",
  "--ide",
]);

function stripAmbientArgs(args) {
  const result = [];
  for (let i = 0; i < args.length; i++) {
    const flag = args[i].split("=", 1)[0];
    if (BARE_FLAGS.has(flag)) continue;
    if (VALUE_FLAGS.has(flag) || VARIADIC_FLAGS.has(flag)) {
      if (!args[i].includes("=")) {
        if (VARIADIC_FLAGS.has(flag))
          while (typeof args[i + 1] === "string" && !args[i + 1].startsWith("-")) i++;
        else if (typeof args[i + 1] === "string" && !args[i + 1].startsWith("-")) i++;
      }
      continue;
    }
    result.push(args[i]);
  }
  return result;
}
function exactNames(names, kind) {
  if (
    !Array.isArray(names) ||
    names.some((name) => typeof name !== "string" || !/^[A-Za-z][A-Za-z0-9_-]*$/.test(name))
  )
    throw new Error(`Invalid exact ${kind} tool selection`);
  return [...new Set(names)];
}
export function projectNativeToolAuthority(names) {
  const selected = new Set(names.map((name) => name.toLowerCase()));
  return [
    ...new Set(
      Object.entries(NATIVE_CAPS)
        .filter(([name]) => selected.has(name))
        .map(([, cap]) => cap),
    ),
  ];
}
export function resolveExecutionArgs(context) {
  // No permission bypass is inferred from absent policy or ambient CLI settings.
  // Side questions require a separate non-persistent transport contract.
  if (context.executionMode === "side-question")
    throw new Error("Standalone claude backend does not support side-question execution");
  const inheritedDenials = [];
  for (let i = 0; i < context.baseArgs.length; i++) {
    const arg = context.baseArgs[i];
    if (arg === "--disallowedTools" || arg === "--disallowed-tools") {
      while (
        typeof context.baseArgs[i + 1] === "string" &&
        !context.baseArgs[i + 1].startsWith("-")
      )
        inheritedDenials.push(...context.baseArgs[++i].split(","));
    } else if (arg.startsWith("--disallowedTools=") || arg.startsWith("--disallowed-tools="))
      inheritedDenials.push(...arg.slice(arg.indexOf("=") + 1).split(","));
  }
  const args = stripAmbientArgs(context.baseArgs);
  args.push(
    "--setting-sources",
    "",
    "--settings",
    RESTRICTED_SETTINGS,
    "--disable-slash-commands",
    "--no-chrome",
    "--strict-mcp-config",
    "--permission-mode",
    "default",
  );
  const selection = context.toolAvailability;
  const native = selection ? exactNames(selection.native, "native") : [];
  const openClaw = selection ? exactNames(selection.openClaw, "OpenClaw") : null;
  args.push("--tools", native.join(","));
  if (openClaw === null) args.push("--allowedTools", "mcp__openclaw__*");
  else if (openClaw.length)
    args.push("--allowedTools", openClaw.map((name) => `mcp__openclaw__${name}`).join(","));
  args.push(
    "--disallowedTools",
    [
      ...new Set([
        ...DENIALS,
        ...inheritedDenials.filter(Boolean),
        ...(openClaw?.length === 0 ? ["mcp__*"] : []),
      ]),
    ].join(","),
  );
  return args;
}
export function parseJsonlLifecycleEvent(line) {
  let event;
  try {
    event = JSON.parse(line);
  } catch {
    return null;
  }
  if (event?.compact_result === "success" || event?.compact_result === "failed")
    return { kind: "compaction", phase: "end", completed: event.compact_result === "success" };
  if (event?.type === "system" && event.subtype === "compact_boundary")
    return { kind: "compaction", phase: "end", completed: true };
  if (event?.type === "system" && event.subtype === "status" && event.status === "compacting")
    return { kind: "compaction", phase: "start" };
  return null;
}
/** @returns {import('openclaw/plugin-sdk/cli-backend').CliBackendPlugin} */
export function buildClaudeBackend(options = {}) {
  const command =
    options.command ?? fileURLToPath(new URL("../claude-auth-router.sh", import.meta.url));
  if (typeof command !== "string" || !command.trim() || !isAbsolute(command.trim()))
    throw new Error("Claude router command must be an absolute path");
  return {
    id: BACKEND_ID,
    autoSelectAuthProfile: false,
    bundleMcp: true,
    bundleMcpMode: "claude-config-file",
    nativeToolMode: "selectable",
    toolAvailabilityEnforcement: "execution-args",
    isolatesInstructionsWithExactTools: true,
    projectNativeToolAuthority,
    resolveExecutionArgs,
    parseJsonlLifecycleEvent,
    ownsNativeCompaction: true,
    manualCompaction: {
      input: "arg",
      buildPrompt: (instructions) =>
        instructions?.trim() ? `/compact ${instructions.trim()}` : "/compact",
      validateOutput: (output) =>
        output.split("\n").some((line) => {
          const event = parseJsonlLifecycleEvent(line);
          return event?.phase === "end" && event.completed;
        })
          ? { ok: true }
          : { ok: false, reason: "Claude CLI did not confirm native compaction" },
    },
    config: {
      command: command.trim(),
      args: [...DEFAULT_ARGS],
      resumeArgs: [...DEFAULT_ARGS, "--resume", "{sessionId}"],
      output: "jsonl",
      jsonlDialect: "claude-stream-json",
      input: "stdin",
      modelArg: "--model",
      sessionArgs: ["--session-id", "{sessionId}"],
      sessionMode: "always",
      sessionIdFields: ["session_id"],
      forkArg: "--fork-session",
      resumeAtArg: "--resume-session-at",
      systemPromptFileArg: "--append-system-prompt-file",
      systemPromptMode: "append",
      systemPromptWhen: "always",
      imageArg: "@",
      imagePathScope: "workspace",
      serialize: true,
      freshSessionRecovery: "invalidated-only",
      reseedFromRawTranscriptWhenUncompacted: true,
      clearEnv: [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_API_TOKEN",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_CUSTOM_HEADERS",
        "ANTHROPIC_OAUTH_TOKEN",
        "ANTHROPIC_UNIX_SOCKET",
        "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR",
        "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CODE_USE_FOUNDRY",
      ],
      env: { CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS: "1" },
    },
    prepareExecution: (context) => ({
      env: {
        ...(context.contextWindow === "200k" ? { CLAUDE_CODE_DISABLE_1M_CONTEXT: "1" } : {}),
        ...(Number.isFinite(context.contextTokenBudget) && context.contextTokenBudget > 0
          ? { CLAUDE_CODE_AUTO_COMPACT_WINDOW: String(Math.floor(context.contextTokenBudget)) }
          : {}),
      },
    }),
    resolveModelId: ({ modelId, contextWindow }) =>
      contextWindow === "1m" ? `${modelId}[1m]` : modelId,
  };
}
