# Providers

The playbook workflow runs on five agent CLIs — each can be the **main agent** (driving tasks under the same hooks) and/or a **judge** on the review panel.

| Provider | CLI | Launcher | Main agent | Judge | Notes |
|---|---|---|---|---|---|
| Claude Code | `claude` | *(native)* | ✔ | ✔ | Reference platform; hooks registered by the plugin. Only judge with a budget cap (`judge_budget_usd`). |
| Codex | `codex` | `playbook-codex` | ✔ | ✔ | `apply_patch` edits are gated via dedicated codex hooks. Effort levels `low…ultra` per the model cache. Business-plan runs can be slow — raise the review timeout if judges expire. |
| Antigravity | `agy` | `playbook-agy` | ✔ | ✔ | The ex-`gemini` CLI. Judge prompts ride `--print <prompt>` (no stdin path). The CLI offers no usable model flag, so the judge always runs whatever model is selected in the agy UI — pins are unverifiable by probe. |
| Grok | `grok` | `playbook-grok` | ✔ | ✔ | Discovers the plugin's hooks natively (reads `.claude/settings.json` + installed plugins) — but hooks stay **silently off until you run `/hooks-trust` once inside the project** (grok's folder-trust model; interactive by design). Payloads are normalized by a shared shim (camelCase keys, `Shell`→Bash, `StrReplace`→Edit). `grok models` is an account-entitlement list, so pins are verifiable without a live run. Web search is on by default (judges pass `--disable-web-search` when off). |
| Pi | `pi` | `playbook-pi` | ✔ | ✔ | Ships a hook adapter (`playbook-pi-hook-adapter.ts`) and a local models file (`playbook-pi-omlx-models.json`). Windows argv-length guard for big judge prompts. |

`playbook-gemini` is the pre-rename wrapper for the sunset `gemini` CLI — it still execs `gemini`, not `agy`, so it only works where that binary survives. Superseded by `playbook-agy`.

## Launchers

The `playbook-*` wrappers (installed to `.claude/bin/` by `/playbook:init`) start each CLI with a unique per-session Playbook session ID (PID-based, provider-agnostic), so gate state, chat-log attribution (`claude`/`codex`/`agy`/`grok`/`pi` tags), and multi-agent handoffs work identically everywhere.

## How the same hooks run everywhere

The plugin registers six lifecycle hooks once (see [architecture](architecture.md)); non-Claude providers reach them through provider adapters (`provider/adapters/*.py`) plus, where needed, a payload-normalization shim that translates each CLI's event schema to the Claude one. The edit gate ("no active task → no code edits") runs under every provider, with two provider-specific caveats: codex pre-blocks `apply_patch` edits but not file writes made through plain shell commands, and grok's hooks require the one-time `/hooks-trust` grant above.

## Judges across providers

Panel seats are specs like `codex:gpt-5.5:xhigh` or `grok:grok-4.5` in [`.agent/models.json`](configuration.md). Each provider adapter knows how to run its CLI headless (prompt on argv vs stdin, model/effort splitting, context inlining) and how to classify failures. Pin health is maintained with `tasks models check` / `select` — including probe-confirmed hard stops when a pinned model disappears from your account, which is a when, not an if.
