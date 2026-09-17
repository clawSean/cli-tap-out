import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { buildClaudeBackend } from "./backend.mjs";

export default definePluginEntry({
  id: "claude-auth-router",
  name: "Claude Account Router Setup",
  register(api) {
    api.registerCliBackend(buildClaudeBackend(api.pluginConfig));
  },
});
