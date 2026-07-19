# Configuration

Two per-install JSON files, both under `.agent/` in your project, hand-editable and machine-specific: `config.json` is created by `/playbook:init`; `models.json` is deliberately NOT — create it with `tasks models select` (or by hand). It's gitignored by design.

## `.agent/config.json` — review knobs

```json
{
  "judge_budget_usd": 2,
  "review_timeout_secs": 300
}
```

- `judge_budget_usd` — spend cap for the **claude** judge (`--max-budget-usd`). Claude-only; codex/agy/grok/pi have no budget knob.
- `review_timeout_secs` — hard timeout for every review agent (plan / impl / panel). On expiry the whole process tree is terminated and the prior review log is left untouched. High-effort judge models can legitimately need more — raise it (600–900) if your reviews time out.

**Precedence, highest first:** CLI flag (`--budget`, `--timeout` on `plan-review` / `impl-review` / `panel-review`) → env var (`PLAYBOOK_JUDGE_BUDGET_USD`, `PLAYBOOK_REVIEW_TIMEOUT_SECS`) → `.agent/config.json` → built-in default. A missing file or malformed value falls back to the default (surfaced by `tasks doctor`, never fatal).

## `.agent/models.json` — judge panel pins

Judge selection lives in `models.json`: the plugin ships defaults in `provider/models.json`, and each install can shadow them per key with a gitignored `.agent/models.json`:

```json
{
  "default_judge": "claude",
  "panel": ["opus", "claude:claude-sonnet-5", "codex:gpt-5.5:xhigh", "agy", "grok:grok-4.5"],
  "aliases": {"opus": "claude:claude-opus-4-8"}
}
```

- `default_judge` — backend for bare `plan-review` / `impl-review`.
- `panel` — the judge seats for `panel-review`; each spec is `backend[:model[:effort]]`.
- `aliases` — shorthand names expanded before dispatch.

### Keeping pins alive

Pinned model ids rot as providers ship and retire models, so the pins have a maintenance loop:

- `tasks models check` audits every pin against **live availability**: codex pins are probed with a tiny prompt (the `~/.codex/models_cache.json` catalog alone doesn't prove your account can use a model), claude pins are probed budget-capped (claude has no list command — new ids enter via `--claude-candidates`), grok pins are checked against `grok models` (a login-aware entitlement list, so a listed pin is OK without a live turn), agy is unverifiable (`--model` is inert in `--print` mode; the judge always runs whatever model is selected in the agy UI). `--no-probe` is the free/fast degraded audit. Exits 1 when any pin can't run as configured.
- `tasks models select` refreshes interactively: shows the report, takes the new panel + default judge, writes `.agent/models.json` — creating it on fresh installs and preserving keys it doesn't manage.
- `tasks doctor` warns (never fails) on a missing models.json or dead pins, using the cheap checks only.

### Failure semantics

- When a review judge fails **specifically because its model no longer exists** — probe-confirmed, not just pattern-matched — the review still saves its output, then prints the availability report and exits nonzero: a deliberate hard stop so you re-pin before trusting a degraded panel. Timeouts, budget caps, and other errors keep their soft behavior.
- A judge that exhausts its budget cap is reported as **failed** with an explicit notice (raise `judge_budget_usd` or pass `--budget`) instead of masquerading as a successful empty review.

## Environment variables

| Variable | Purpose |
|---|---|
| `PLAYBOOK_JUDGE_BUDGET_USD` | Overrides `judge_budget_usd` (below CLI flags). |
| `PLAYBOOK_REVIEW_TIMEOUT_SECS` | Overrides `review_timeout_secs` (below CLI flags). |
| `PLAYBOOK_PROJECT_ROOT`, `PLAYBOOK_SESSION_ID`, `PLAYBOOK_SANDBOXED`, `PLAYBOOK_MINDMAP_MAX`, `PLAYBOOK_EVAL_CONFIG` | Internal — set by the wrappers, hooks, and sandbox; not meant to be set by hand. |
