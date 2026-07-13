"""
GrokAdapter — provider adapter for xAI's Grok Build CLI (`grok`).

grok v0.2.99 (verified live, task 014). Rust-based TUI + headless CLI with a
deliberate Claude Code compatibility layer: it auto-loads BOTH CLAUDE.md and
AGENTS.md from the project cwd, reads `.claude/settings.json` hooks, and loads
installed Claude Code plugins (the playbook plugin's hooks.json shows up in
`grok inspect` as `file  plugin: playbook`). State lives under ~/.grok/
(auth.json, sessions/, models_cache.json) — that path must be RW inside the
judge sandbox (sandbox._HOME_RW_SUBPATHS), or grok dies at startup with
FS_PERMISSION_DENIED before reading the prompt.

Headless invocation: `grok -p "<prompt>"` (aliases: --single); prompt is the
flag's argv VALUE, stdin is not a prompt channel (same contract as agy 1.1.x,
task 013). Useful flags: `-m <model>`, `--reasoning-effort <level>`,
`--disable-web-search`, `--max-turns <N>`, `--output-format plain|json`,
`--prompt-file <path>` (an argv-cap escape hatch no other provider has — not
used yet; the win32 >30K guard below mirrors agy/pi instead).

Model catalog: `grok models` lists account-entitled models live (verified:
grok-composer-2.5-fast (default), grok-build) — unlike claude (no list
command) and codex (cache ≠ entitlements), grok pins are directly probeable.
A bad `-m` fails fast: exit 1 + stderr `Couldn't set model '<x>': Invalid
params: "unknown model id"` (signature used by models_check.classify_failure).

Hook surface (payload dialect captured live from a real headless session):
top-level keys are camelCase (`hookEventName`, `sessionId`, `toolName`,
`toolInput`); tool names are partially Claude-aliased — Write/Read keep their
Claude names, but Edit arrives as `StrReplace` and Bash as `Shell`; toolInput
keys are grok-native: `path` (not file_path), `contents` (not content), while
`old_string`/`new_string`/`command` match Claude. The shared normalizer in
scripts/hook-payload-lib handles the translation for the bash hooks.
PreToolUse can block (exit 2 or {"decision":"deny"}); Stop CANNOT block
(fires, but the turn ends regardless) — anti-walk-away is soft, like pi.
Project hooks are folder-trust-gated: a human must run `/hooks-trust` once
per project (or launch with the trust flag); until then project hooks are
silently skipped. Global ~/.grok/hooks/*.json are always trusted.

Session identity: no PLAYBOOK-aware env from grok itself; hooks do receive
GROK_SESSION_ID + a camelCase sessionId payload key, but playbook resolution
follows the codex/agy pattern: $PLAYBOOK_SESSION_ID (set by the playbook-grok
wrapper) → PID-walk fallback (gate-echo-lib.sh knows the `grok` comm name).

Panel-review participation: ["grok-build"] — a deliberate pin (task 014
plan-panel F-G): bare `grok` specs resolve to (grok, None) which would run
the default grok-composer-2.5-fast; review work wants the stronger build
model. composer stays reachable via an explicit `grok:grok-composer-2.5-fast`.
"""

from __future__ import annotations
import os
import subprocess
from pathlib import Path
from typing import Optional

from ..adapter import ProviderAdapter, Invocation
from ..capabilities import ProviderCapabilities


# Efforts grok's --reasoning-effort accepts. Only "low" is live-verified
# (task 014); low/medium/high is the conservative documented trio. Kept
# permissive-but-loud like codex._REASONING_EFFORTS: an unknown keyword in a
# `grok:model:effort` pin raises at spec-parse time instead of reaching `-m`
# as a bogus token.
_REASONING_EFFORTS = frozenset({"low", "medium", "high"})


def _split_reasoning_effort(model: str) -> tuple[str, Optional[str]]:
    """Split a `model` or `model:effort` spec into (model, effort_or_None).

    Mirrors codex._split_reasoning_effort but with grok's effort vocabulary.
    Judge specs like `grok:grok-build:high` arrive here with the effort
    suffix still attached (resolve_judge_spec only peels the provider).
    """
    if ":" not in model:
        return model, None
    model_id, _, effort = model.rpartition(":")
    model_id = model_id.strip()
    effort = effort.strip().lower()
    if not model_id:
        raise ValueError(f"empty model id in grok model spec {model!r}.")
    if effort not in _REASONING_EFFORTS:
        raise ValueError(
            f"unknown reasoning effort {effort!r} in grok model spec {model!r}. "
            f"Use one of: {', '.join(sorted(_REASONING_EFFORTS))}."
        )
    return model_id, effort


class GrokAdapter(ProviderAdapter):
    """Provider adapter for xAI Grok Build CLI (`grok`)."""

    _PANEL_VARIANTS = ["grok-build"]

    def __init__(self, session_id: str, project_root: Path) -> None:
        self._session_id = session_id
        self._project_root = project_root

    # ── CLI identity ─────────────────────────────────────────────────────────

    @classmethod
    def binary_name(cls) -> str:
        return "grok"

    @classmethod
    def panel_variants(cls) -> list[Optional[str]]:
        return list(cls._PANEL_VARIANTS)

    def run_headless_judge(
        self,
        prompt: str,
        model: Optional[str],
        system_context: str,
        *,
        web_search: bool,
        timeout_secs: int,
        budget_usd: str = "2",
    ) -> str:
        import shutil
        if not shutil.which(self.binary_name()):
            return f"(error: {self.binary_name()} not found on PATH)"
        inv = self.headless_argv(prompt, model, context=system_context)
        # Judge-only extra: grok's web tools are on by default — strip them
        # when the caller didn't ask for web search (codex is the inverse:
        # opt-in via --search).
        agent_args = inv.argv + ([] if web_search else ["--disable-web-search"])
        # grok reads its prompt as the `-p` flag value (stdin is not a prompt
        # channel — same contract as agy 1.1.x, task 013). Windows caps the
        # whole command line at 32,767 chars (WinError 206) — fail fast with a
        # clear error instead of a cryptic spawn failure. (grok --prompt-file
        # could lift this cap later; unverified under sandbox, so mirror the
        # agy/pi guard for now.)
        if os.name == "nt":
            payload = sum(len(a) + 1 for a in agent_args)
            if payload > 30_000:
                return (f"(error: grok judge prompt+context is ~{payload} chars on argv; "
                        "Windows caps the command line at 32,767 chars and grok reads its "
                        "prompt from argv — shrink the context or use another backend)")
        env = os.environ.copy()
        env["PLAYBOOK_SESSION_ID"] = self._session_id or "judge"
        from provider import sandbox as _sandbox
        # encoding="utf-8" guards the stdout decode against the Windows cp1252
        # locale default. No stdin (prompt is on argv — see headless_argv).
        result = _sandbox.run(
            "grok", agent_args,
            project_root=self._project_root,
            env=env,
            input=None,
            capture_output=True, text=True, timeout=timeout_secs, encoding="utf-8",
        )
        return _sandbox.format_judge_output(result)

    def headless_argv(
        self,
        prompt: str,
        model: Optional[str],
        *,
        context: str = "",
        bare: bool = False,
        stream: bool = False,
    ) -> Invocation:
        # Context is joined into the prompt (agy/pi pattern) — grok has no
        # append-system-prompt flag, only a full --system-prompt-override,
        # which would clobber grok's own tool-use instructions.
        full_prompt = prompt if (bare or not context) else f"{context}\n\n---\n\n{prompt}"
        argv = ["-p", full_prompt]
        if model:
            model_id, effort = _split_reasoning_effort(model)
            argv += ["-m", model_id]
            if effort:
                argv += ["--reasoning-effort", effort]
        if stream:
            argv += ["--output-format", "streaming-json"]
        return Invocation(argv, stdin=None)

    # ── Identity ─────────────────────────────────────────────────────────────

    @property
    def session_id(self) -> str:
        return self._session_id

    @property
    def project_root(self) -> Path:
        return self._project_root

    # ── Bootstrap ────────────────────────────────────────────────────────────

    def bootstrap_file_name(self) -> str:
        # grok auto-loads BOTH AGENTS.md and CLAUDE.md from the project cwd
        # (plus .claude/CLAUDE.md at each level when Claude compat is on —
        # default). AGENTS.md is the provider-neutral choice, shared with
        # codex/pi.
        return "AGENTS.md"

    def install_bootstrap(self, project_root: Path) -> None:
        """Write AGENTS.md (shared with codex/pi) if not present."""
        from tasks.template import agents_md_template
        target = project_root / "AGENTS.md"
        if not target.exists():
            target.write_text(agents_md_template(), encoding="utf-8")

    # ── Hooks ─────────────────────────────────────────────────────────────────
    # grok discovers playbook hooks through TWO native channels, no config
    # mutation needed: (1) project `.claude/settings.json` (written by
    # `tasks init` in every playbook project), (2) the installed playbook
    # Claude Code plugin's hooks.json. Both are folder-trust-gated: project
    # hooks stay silently OFF until a human runs `/hooks-trust` once inside
    # the project (recorded in ~/.grok/trusted_folders.toml). That grant is
    # interactive by design — install_hooks can only remind, not automate.

    def install_hooks(self, project_root: Path) -> None:
        """No file writes needed — grok reads .claude/settings.json natively.

        Prints the one-time folder-trust step, the only part that needs a
        human, plus the space-in-path caveat. Idempotent.

        KNOWN LIMITATION (verified live, task 014): grok splits the hook
        manifest's `command` string on whitespace, so a hook whose resolved
        path contains a SPACE never launches → gate enforcement fail-opens
        SILENTLY. Normal installs (~/.claude/plugins/cache/.../playbook/<ver>)
        are space-free and fine; a project checked out under a spaced path
        (e.g. macOS "Mobile Documents" iCloud dirs) loses grok enforcement.
        """
        settings = project_root / ".claude" / "settings.json"
        if not settings.exists():
            print("  grok hooks   .claude/settings.json missing — run `tasks init` first")
            return
        print("  grok hooks   auto-discovered from .claude/settings.json (Claude compat)")
        print("               one-time step: run /hooks-trust inside a grok session in this")
        print("               project, or project hooks are silently skipped")
        if " " in str(project_root):
            print("               WARNING: project path contains a space — grok splits hook")
            print("               command paths on whitespace, so gate enforcement will")
            print("               fail-open here. Move the project to a space-free path.")

    def uninstall_hooks(self, project_root: Path) -> None:
        """Nothing to remove — grok reads the shared .claude/settings.json."""

    # ── Launch ───────────────────────────────────────────────────────────────

    @staticmethod
    def _wrapper_path() -> Optional[Path]:
        """Locate the shipped `playbook-grok` launcher. Installed: `scripts/`
        (next to the hooks). Dev: `bin/`. Walk up from this module looking in
        both."""
        here = Path(__file__).resolve()
        for parent in here.parents:
            for sub in ("scripts", "bin"):
                cand = parent / sub / "playbook-grok"
                if cand.exists():
                    return cand
        return None

    def launch_interactive(self, project_root: Path, **kwargs) -> int:
        """Interactive grok session via the `playbook-grok` wrapper.

        The wrapper sets PLAYBOOK_SESSION_ID + provisions the session dir so
        the gate hooks namespace state correctly. Falls back to direct `grok`
        if the wrapper can't be found.
        """
        env = os.environ.copy()
        wrapper = self._wrapper_path()
        cmd = [str(wrapper)] if wrapper else ["grok"]
        result = subprocess.run(cmd, cwd=str(project_root), env=env, **kwargs)
        return result.returncode

    def launch_headless(self, project_root: Path, prompt: str, **kwargs) -> str:
        """Headless one-shot via sandbox."""
        from provider import sandbox as _sandbox
        result = _sandbox.run(
            "grok", ["-p", prompt],
            project_root=project_root,
            capture_output=True, text=True, **kwargs,
        )
        return result.stdout or ""

    # ── Capabilities ────────────────────────────────────────────────────────

    def detect_capabilities(self) -> ProviderCapabilities:
        return ProviderCapabilities(
            provider="grok",
            # Verified live (task 014): UserPromptSubmit / PreToolUse /
            # PostToolUse / Stop / SessionStart all fire in headless mode.
            # PreToolUse blocks via exit 2 or {"decision":"deny"}.
            has_user_prompt_hook=True,
            has_pre_tool_hook=True,
            has_post_tool_hook=True,
            # Stop fires but CANNOT block ("Blocking? No" — 10-hooks.md);
            # anti-walk-away enforcement is soft, like pi. Keep False so
            # callers don't assume a hard Stop.
            has_stop_hook=False,
            # Payload has a camelCase sessionId (grok's own UUID), but
            # playbook session identity comes from PLAYBOOK_SESSION_ID (set
            # by the wrapper) / PID-walk — grok's UUID is not the playbook
            # session id, so don't advertise it.
            session_id_in_payload=False,
            # Sessions live under ~/.grok/sessions/ (sqlite index + per-cwd
            # percent-encoded dirs; hook payloads carry transcriptPath).
            # Parsing deferred — chat-log-hook covers attribution via
            # UserPromptSubmit. Wire read_new_messages when needed.
            session_log_format="unknown",
            session_log_base=None,
        )

    # ── Session log / chat log ──────────────────────────────────────────────
    # Deferred (see detect_capabilities): hook payloads include a
    # transcriptPath under ~/.grok/sessions/, but the format is unverified.
    # UserPromptSubmit → chat-log-hook covers message attribution.

    def session_log_path(self) -> Optional[Path]:
        return None

    def read_new_messages(self, since_offset: int) -> tuple[list[str], int]:
        return [], since_offset
