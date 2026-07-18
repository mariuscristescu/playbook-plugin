#!/usr/bin/env python3
"""Point tests for the README drift helper (task 017).

Covers the two detection signals (module-path walk, child-checkout scan), the
~/.claude/plugins exclusion (marketplaces full clone must never fire), the
baseline-coverage trigger semantics (typo-README commit does NOT reset the
signal), and every soft-degrade path (missing/malformed/incomplete baseline,
unresolvable sha, not a git checkout).

Pure stdlib unittest (no hypothesis — honors the stdlib-only runtime invariant).
Run: python3 tests/test_readme_drift.py   (or: python3 -m unittest ...)
"""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# The runtime tree is plugins/playbook/ (dispatcher sets PYTHONPATH there).
_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE.parent / "plugins/playbook"))

from tasks.readme_drift import (  # noqa: E402
    BASELINE_REL,
    DEFAULT_COVERED_PATHS,
    find_source_repo,
    readme_drift,
)

_GIT = ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]


def _git(repo: Path, *args: str) -> str:
    proc = subprocess.run(
        [*_GIT, "-C", str(repo), *args], capture_output=True, text=True, check=True
    )
    return proc.stdout.strip()


def make_source_repo(root: Path, git: bool = True) -> Path:
    """Lay down a minimal plugin source checkout and return its root."""
    root.mkdir(parents=True, exist_ok=True)
    manifest = root / "plugins" / "playbook" / ".claude-plugin" / "plugin.json"
    manifest.parent.mkdir(parents=True)
    manifest.write_text('{"name": "playbook", "version": "9.9.9"}')
    (root / "README.md").write_text("# readme\n")
    (root / "plugins" / "playbook" / "commands").mkdir()
    (root / "plugins" / "playbook" / "commands" / "init.md").write_text("x\n")
    if git:
        _git(root, "init", "-q")
        _git(root, "add", "-A")
        _git(root, "commit", "-qm", "initial")
    return root


def write_baseline(repo: Path, sha: str, paths=None) -> None:
    baseline = repo / BASELINE_REL
    baseline.parent.mkdir(parents=True, exist_ok=True)
    baseline.write_text(json.dumps({
        "audited_commit": sha,
        "version": "9.9.9",
        "date": "2026-01-01",
        "covered_paths": list(DEFAULT_COVERED_PATHS) if paths is None else paths,
    }))


def surface_commit(repo: Path) -> None:
    (repo / "plugins" / "playbook" / "commands" / "new-feature.md").write_text("y\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-qm", "feat: new command")


class ReadmeDriftTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        # A plugins-home guaranteed not to contain any fixture unless a test
        # places one there deliberately.
        self.plugins_home = self.tmp / "claude-plugins"
        self.plugins_home.mkdir()

    def tearDown(self):
        self._tmp.cleanup()

    def _module_in(self, repo: Path) -> Path:
        return repo / "plugins" / "playbook" / "tasks" / "readme_drift.py"

    def _drift(self, repo=None, project=None):
        return readme_drift(
            project_path=project,
            module_file=self._module_in(repo) if repo else self.tmp / "nowhere" / "mod.py",
            plugins_home=self.plugins_home,
        )

    # --- detection signals -------------------------------------------------

    def test_signal1_module_walk_finds_dev_checkout(self):
        repo = make_source_repo(self.tmp / "checkout")
        found = find_source_repo(module_file=self._module_in(repo), plugins_home=self.plugins_home)
        # signal 1 walks resolved parents (macOS /var -> /private/var), so
        # compare resolved forms.
        self.assertEqual(found, repo.resolve())

    def test_signal2_child_scan_finds_dogfood_workspace(self):
        ws = self.tmp / "workspace"
        repo = make_source_repo(ws / "playbook-plugin")
        found = find_source_repo(
            project_path=ws,
            module_file=self.tmp / "nowhere" / "mod.py",
            plugins_home=self.plugins_home,
        )
        self.assertEqual(found, repo)

    def test_marketplaces_clone_excluded(self):
        # A full git clone under plugins-home is content-identical to a dev
        # checkout — the path guard must exclude it for BOTH signals.
        repo = make_source_repo(self.plugins_home / "marketplaces" / "mkt")
        self.assertIsNone(
            find_source_repo(module_file=self._module_in(repo), plugins_home=self.plugins_home)
        )
        self.assertIsNone(
            find_source_repo(
                project_path=self.plugins_home / "marketplaces",
                module_file=self.tmp / "nowhere" / "mod.py",
                plugins_home=self.plugins_home,
            )
        )

    def test_host_project_and_installed_cache_silent(self):
        # Installed cache layout: plugin dir with manifest but no repo-root
        # README/.git above it — resembles ~/.claude/plugins/cache/<mkt>/....
        cache = self.plugins_home / "cache" / "mkt" / "playbook" / "1.0.0"
        (cache / ".claude-plugin").mkdir(parents=True)
        (cache / ".claude-plugin" / "plugin.json").write_text("{}")
        (cache / "tasks").mkdir()
        host = self.tmp / "host-project"
        (host / ".agent" / "tasks").mkdir(parents=True)
        self.assertEqual(
            readme_drift(
                project_path=host,
                module_file=cache / "tasks" / "readme_drift.py",
                plugins_home=self.plugins_home,
            ),
            [],
        )

    def test_not_a_git_checkout_silent(self):
        repo = make_source_repo(self.tmp / "no-git", git=False)
        self.assertEqual(self._drift(repo=repo), [])

    # --- baseline trigger semantics ----------------------------------------

    def test_no_baseline_nags_once_with_skill_path(self):
        repo = make_source_repo(self.tmp / "checkout")
        msgs = self._drift(repo=repo)
        self.assertEqual(len(msgs), 1)
        self.assertIn("no README audit baseline yet", msgs[0])
        self.assertIn(".claude/skills/readme-audit/SKILL.md", msgs[0])

    def test_fresh_baseline_silent(self):
        repo = make_source_repo(self.tmp / "checkout")
        write_baseline(repo, _git(repo, "rev-parse", "HEAD"))
        self.assertEqual(self._drift(repo=repo), [])

    def test_surface_commit_after_baseline_fires(self):
        repo = make_source_repo(self.tmp / "checkout")
        write_baseline(repo, _git(repo, "rev-parse", "HEAD"))
        surface_commit(repo)
        msgs = self._drift(repo=repo)
        self.assertEqual(len(msgs), 1)
        self.assertIn("1 commit(s) touched user-facing paths", msgs[0])
        self.assertIn(".claude/skills/readme-audit/SKILL.md", msgs[0])

    def test_docs_only_commit_stays_silent(self):
        repo = make_source_repo(self.tmp / "checkout")
        write_baseline(repo, _git(repo, "rev-parse", "HEAD"))
        (repo / "docs" / "extra.md").parent.mkdir(exist_ok=True)
        (repo / "docs" / "extra.md").write_text("docs only\n")
        _git(repo, "add", "-A")
        _git(repo, "commit", "-qm", "docs: extra page")
        self.assertEqual(self._drift(repo=repo), [])

    def test_typo_readme_commit_does_not_reset_signal(self):
        # The T2 regression: a README-only commit AFTER an undocumented surface
        # commit must not silence the warning (recency triggers would reset).
        repo = make_source_repo(self.tmp / "checkout")
        write_baseline(repo, _git(repo, "rev-parse", "HEAD"))
        surface_commit(repo)
        (repo / "README.md").write_text("# readme (typo fixed)\n")
        _git(repo, "add", "-A")
        _git(repo, "commit", "-qm", "fix readme typo")
        msgs = self._drift(repo=repo)
        self.assertEqual(len(msgs), 1)
        self.assertIn("1 commit(s) touched user-facing paths", msgs[0])

    # --- soft-degrade paths -------------------------------------------------

    def test_malformed_baseline_soft_message(self):
        repo = make_source_repo(self.tmp / "checkout")
        baseline = repo / BASELINE_REL
        baseline.parent.mkdir(parents=True, exist_ok=True)
        baseline.write_text("{not json")
        msgs = self._drift(repo=repo)
        self.assertEqual(len(msgs), 1)
        self.assertIn("unreadable", msgs[0])

    def test_baseline_without_commit_soft_message(self):
        repo = make_source_repo(self.tmp / "checkout")
        baseline = repo / BASELINE_REL
        baseline.parent.mkdir(parents=True, exist_ok=True)
        baseline.write_text(json.dumps({"version": "9.9.9"}))
        msgs = self._drift(repo=repo)
        self.assertEqual(len(msgs), 1)
        self.assertIn("incomplete", msgs[0])

    def test_unresolvable_baseline_sha_soft_message(self):
        repo = make_source_repo(self.tmp / "checkout")
        write_baseline(repo, "0" * 40)  # never a real object in this repo
        msgs = self._drift(repo=repo)
        self.assertEqual(len(msgs), 1)
        self.assertIn("unresolvable", msgs[0])

    def test_baseline_missing_covered_paths_uses_defaults(self):
        repo = make_source_repo(self.tmp / "checkout")
        write_baseline(repo, _git(repo, "rev-parse", "HEAD"), paths=[])
        surface_commit(repo)
        msgs = self._drift(repo=repo)
        self.assertEqual(len(msgs), 1)
        self.assertIn("1 commit(s)", msgs[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
