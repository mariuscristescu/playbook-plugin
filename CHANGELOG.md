# Changelog

Notable changes to the playbook plugin. Follows [Keep a Changelog](https://keepachangelog.com/) loosely; maintained by the README audit skill (entries before 1.4.2 are reconstructed from git history and the project mind map).

## [1.4.2] — 2026-07-17

### Added
- README audit: maintainer skill (`.claude/skills/readme-audit/` in this repo, not shipped with the plugin), README-drift advisory in `tasks doctor` and `tasks bootstrap` (maintainer checkouts only), audit baseline at `docs/readme-audit-baseline.json`.
- Layered documentation: `docs/cli.md`, `docs/configuration.md`, `docs/providers.md`, `docs/architecture.md`; README rewritten user-first with the deep material moved there.

## [1.4.1] — 2026-07

### Fixed
- `tasks models check` now discovers current Claude models on fresh installs (reads the model your Claude Code is configured to run — Claude has no CLI list command); shipped alias table refreshed.

## [1.4.0] — 2026-07

### Added
- **Grok** as the fifth provider (judge + main agent): `playbook-grok` launcher, native hook discovery with a shared payload-normalization shim, entitlement-aware `models check` support.

### Fixed
- Hook commands quoted in `hooks.json` — plugin installs under paths with spaces (e.g. iCloud checkouts) no longer fail silently under providers that word-split.

## [1.3.9] — 2026-07

### Fixed
- Antigravity (agy) judge invocation: agy 1.1.x changed `--print` to take the prompt as its value; the panel's agy seat had been silently reviewing the wrong prompt.

## [1.3.8] — 2026-07

### Added
- Judge-pin maintenance loop: `tasks models check` (live availability audit with probe-confirmed hard stops when a pinned model is gone) and `tasks models select` (guided panel refresh); `tasks doctor` warns on dead pins.

### Fixed
- Failed judges (budget-exhausted, nonzero-exit) can no longer masquerade as successful empty reviews.

## [1.3.7] — 2026-07

### Added
- Per-install review knobs in `.agent/config.json`: `judge_budget_usd`, `review_timeout_secs` (CLI flag → env → config → default precedence).

## Earlier

Wrapper resolution and atomicity hardening (1.3.5–1.3.6), Codex `apply_patch` hooks + freehand mode (1.2.x), monitor integration (1.1.6), retro tooling, bash-log, mind-map subsystem, marketplace packaging (1.0.x). See git history for detail.
