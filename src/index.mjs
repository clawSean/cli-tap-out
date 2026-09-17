import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import provider from "./provider.mjs";
import { buildClaudeBackend } from "./backend.mjs";
export default definePluginEntry({
  id: "claude-auth-router",
  name: "Claude Account Router",
  description: "Standalone Claude CLI backend with account routing.",
  register(api) {
    api.registerProvider(provider);
    api.registerCliBackend(buildClaudeBackend(api.pluginConfig));
  },
});
