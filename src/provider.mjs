import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
export const AUTH_MARKER = "openclaw:claude-router-native-auth";
// Presence-only readiness: actual login validity is checked by the router at execution.
// No credential is returned, copied, logged, or persisted by discovery.
export async function routerAuthReady(env = process.env) {
  try {
    const file =
      env.CLAUDE_PROFILES_FILE || join(env.HOME || homedir(), ".openclaw", "claude-profiles.json");
    const config = JSON.parse(await readFile(file, "utf8"));
    const active = typeof config.active === "string" ? config.active.trim() : "";
    const entry = config.profiles?.[active];
    const name = typeof entry?.env_var === "string" ? entry.env_var.trim() : "";
    return (
      !!active &&
      /^[A-Za-z_][A-Za-z0-9_]*$/.test(name) &&
      typeof env[name] === "string" &&
      env[name].length > 0
    );
  } catch {
    return false;
  }
}
/** @type {import('openclaw/plugin-sdk/provider-model-shared').ProviderPlugin} */
const provider = {
  id: "claude",
  label: "Claude",
  docsPath: "/providers/models",
  auth: [],
  async prepareSyntheticAuth({ provider, env = process.env, signal }) {
    signal?.throwIfAborted();
    if (provider !== "claude") return undefined;
    const ready = await routerAuthReady(env);
    signal?.throwIfAborted();
    if (!ready) return undefined;
    return {
      apiKey: AUTH_MARKER,
      source: "Claude router selected-profile credential presence",
      mode: "oauth",
    };
  },
};
export default provider;
