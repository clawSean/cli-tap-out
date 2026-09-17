# cli-tap-out — Claude account routing for OpenClaw

A standalone OpenClaw plugin that runs Claude Code through a pool of Claude
subscription accounts. Models use `claude/<model-id>`; the installed plugin ID
is `claude-auth-router`. It uses the public plugin SDK and ships its own CLI
adapter and account router.

## Install

Requires OpenClaw 2026.9.3 or later, Node 26+, Claude Code on the gateway's
PATH, Bash 3.2+, and Python 3. No additional npm dependencies are required.

1. Keep this project in a durable directory outside the OpenClaw installation.
2. Copy `claude-profiles.example.json` to `~/.openclaw/claude-profiles.json`.
   Put tokens in the gateway environment; the profiles file contains only
   account labels and environment variable names. Set its `active` profile.
3. From this project, run `openclaw plugins install --link --force .`.
4. Merge `openclaw-config-snippet.json5` into your existing configuration.
   Use the project's absolute path. Preserve your other plugins and models.
5. Run `openclaw config validate`, restart the gateway, then open a fresh
   `/models` menu and select **claude**. Old menu buttons retain old identities.

The packaged router is the default command. An existing absolute router path
can optionally be set at `plugins.entries.claude-auth-router.config.command`.
The older `agents.defaults.cliBackends` command override is not supported by
OpenClaw 2026.9.3 and should be removed during migration.

## Behavior

The router selects the active profile's token and launches Claude Code.
When Claude reports a session limit, it records the real reset time when
available, selects a profile outside cooldown, and returns a request to resend.
It does not silently replay a partially executed turn. If every profile is
exhausted, it returns a real failure for OpenClaw's configured fallback handling.
Fallback behavior for explicitly pinned models remains owned by OpenClaw.

A rejected included-subscription quota does not trigger rotation when Claude
reports paid Extra Usage as `allowed`, `allowed_warning`, or already in use.
The router waits for the terminal result and rotates only when the request is
actually blocked.

OpenClaw supervises one process per turn. Native `--resume` preserves Claude
session history without retaining an idle inference process between turns.
OpenClaw tools are exposed through the host's MCP bridge. Native Claude tools
are disabled by default; exact host selections are projected explicitly.
Ambient CLI settings, hooks, plugins, and instruction files are suppressed.
Permission bypass is never enabled. Restricted side questions are unsupported
and fail closed.

Local file and shell tools are not exposed by the unrestricted MCP bridge.
Runs with explicit host tool caps can use host-mediated coding tools; this
plugin does not bypass that policy by enabling native Claude tools.

Native history stays in Claude Code's local session. If that session is lost,
OpenClaw may refuse to reconstruct it because a credential-presence marker
is not an authenticated owner for borrowing stored history.

Provider discovery checks that the selected profile has a credential in the
captured gateway environment. This is a presence check; Claude validates the
login when a turn executes. Credentials never become catalog values.

## Updates and compatibility

OpenClaw updates do not replace a linked plugin's source, its account state,
or its per-user configuration. This plugin imports only the public
`openclaw/plugin-sdk/plugin-entry` entry point. It does not import bundled
Anthropic implementation files or modify the OpenClaw launcher.

The manifest also declares `anthropic` as an auth-preparation reference. This
supplies a missing negative catalog fact in 2026.9.3 and prevents the
`Prepared synthetic auth is missing for anthropic` failure. The built-in
Anthropic plugin continues to own Anthropic; no provider is replaced.

Future SDK or Claude CLI breaking changes may require a plugin update.
Retaining files across updates does not guarantee compatibility with every
future release. After an upgrade, run `npm test`, `openclaw config validate`,
and a real `claude` model turn.

## Development

Run `npm test` for adapter, tool-boundary, catalog, and auth-discovery checks.
Run `npm pack --dry-run` to review the portable package contents. The package
excludes account state, credentials, and private project notes.

The shell router is also usable directly:

```sh
./claude-auth-router.sh -p 'Reply exactly: ROUTER_OK' \
  --output-format json --model claude-sonnet-4-6
```

Generate long-lived account tokens with `claude setup-token` and load each
token under its profile's environment variable name in the gateway environment.
Never put tokens in the profiles file or source code.
