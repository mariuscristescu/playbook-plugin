---
name: merge-with-mindmap
description: >
  Merge two branches in a playbook-managed repo where each side has rewritten
  MIND_MAP.md independently and renamed `.agent/` files into different per-user
  namespaces. Use this whenever you are about to `git merge` between branches
  in a repo that contains `MIND_MAP.md` at the root and per-user `.agent/`
  subdirectories, especially before opening a PR or pulling main. A naive git
  merge silently cross-contaminates per-user files; this skill encodes the
  discipline to prevent that and produces a clean merge plus an updated
  MIND_MAP that documents the merge itself.
argument-hint: <source-branch> [target-branch]
---

# Merge with Mindmap

## What this skill is for

A playbook-managed repo namespaces agent runtime under `.agent/<user>/<files>`
so multiple humans (or one human's multiple workstations) can share the repo.
When two such lineages converge — typically merging `main` into a working
branch before a PR, or merging a feature branch into `main` — three failure
modes appear that a plain `git merge` will not handle correctly:

1. **MIND_MAP.md three-way merge** produces conflict markers in narrative
   prose that no one can resolve mechanically.
2. **Per-user file renames** (`.agent/chat_log.md` → `.agent/<userA>/chat_log.md`
   on one branch vs `.agent/<userB>/chat_log.md` on the other) trigger
   rename/rename conflicts. Git *also* runs a three-way content merge using
   the shared ancestor and **writes the merged blob to BOTH destinations**,
   silently cross-contaminating each user's per-user file with the other
   user's content. Naive `git add .agent/` ships the contamination.
3. **Install-specific policy files** (canonically `.agent/current_user`)
   tracked early in some installs should be gitignored. The merge is the
   natural moment to enact that policy.

This skill walks through a manual procedure for the parts that require
judgment (the MIND_MAP semantic merge, .gitignore style) and points at
`tasks merge-doctor` for the parts that are purely mechanical (contamination
detection, stranded markers, legacy-path files).

## Continuation policy

**Run Steps 0–7 continuously without asking the user.** The single mandatory
pause is at Step 8 (push), because that's the first irreversible /
shared-state action — everything before it is local commits the user can
`git reset --hard HEAD~1` if they don't like the result.

When `tasks merge-doctor` reports findings, read the labeled sections:

- **`[ACTIONABLE]`** — stop, fix the underlying issue in the next step, then
  re-run the doctor.
- **`[EXPECTED]`** — mid-merge surface that Step 5 is about to resolve.
  Continue. (Only ever appears in mid-merge inspection mode — `MERGE_HEAD`
  present. After the merge commit, any surviving marker becomes
  `[ACTIONABLE]`.)
- **`[INFORMATIONAL]`** — a path on disk that isn't tracked or gitignored,
  so it could end up in a commit if you `git add` blindly. Continue, but
  note it; don't surface it to the user as a problem.

`tasks merge-doctor` exits 0 when there are zero actionable findings — even
if `[EXPECTED]` and `[INFORMATIONAL]` lines were printed. Trust the exit
code: 0 means proceed, 1 means a real problem you have to fix.

**At Step 8**, show the user the merge commit's `git diff` and the new
`MIND_MAP.md` head, then ask exactly one clear question:

> "Push to `<remote>/<target>`?"

Accept `yes`, `no`, or `revise X`. Do not present multi-option menus
("continue / pause / abort?") at any earlier step.

## Usage

```
/playbook:merge-with-mindmap <source-branch> [target-branch]
```

- `<source-branch>` — the branch whose changes you want to bring in.
- `[target-branch]` — where you want the result (default: `main` for the
  "merge main into my feature before PR" case, but if invoking from `main`
  to absorb a feature, target is `main` and source is the feature).

Both arguments are explicit so the agent never guesses from context — the
direction of a merge is too consequential to infer.

## How rename/rename causes silent cross-contamination

Encode this verbatim and don't paraphrase it away — it is the load-bearing
explanation for everything that follows:

> A rename/rename conflict in git is *also* a content-merge in disguise. Git
> computes a three-way content merge using the merge base as ancestor and
> writes the merged blob to **both** destination paths. For per-user files
> (`chat_log.md`, `task.md`) the two destinations are not the same logical
> file — they are separate user lineages that should diverge by design. The
> content merge produces conflict markers inside files that have no conflict
> at the path level. Worse, when the two sides only *append* to the file
> (as chat logs do), the three-way content merge can succeed without any
> conflict markers at all and still write contaminated content to both
> destinations. **Reset each destination to its own branch's version.**

The mechanical detector for this lives in `tasks merge-doctor` and you should
run it after Step 4 and before committing.

---

## Procedure

### Step 0 — Diagnose

Read the merge surface before touching it.

```bash
git status
git fetch <remote>
git log --oneline <source> ^<target>
git log --oneline <target> ^<source>
git diff <target>..<source> --stat
git show <target>:MIND_MAP.md | wc -l
git show <source>:MIND_MAP.md | wc -l
git ls-tree -d --name-only <target> -- .agent/
git ls-tree -d --name-only <source> -- .agent/
```

Use `git ls-tree -d --name-only` (not `git show <ref>:.agent/`) because it
restricts to trees, so subdir names are unambiguous and don't get mixed with
file names.

Decide:
- **Real divergent merge or fast-forward?** If `git log <source> ^<target>`
  is empty, target is already ahead — nothing to do. If `git log <target>
  ^<source>` is empty, this is a fast-forward and this skill doesn't apply
  (just do `git merge --ff-only`).
- **Which side has the richer MIND_MAP?** Heuristic, in order:
  1. Presence of `[[node-id]]` style links anywhere in the file (newer
     MIND_MAP format).
  2. Number of named nodes (lines starting with `- **<name>**` or
     `[N] **<title>**`).
  3. Total non-whitespace character count.
  The richer side becomes the base for the semantic merge in Step 5.
- **What user namespaces exist on each side?** Union of the two
  `ls-tree -d --name-only` outputs gives every namespace you must preserve.
  Don't assume two — three or more is allowed; keep every namespace that
  appears on either side.
- **Is the current user's `chat_log.md` dirty?** If so, decide whether to
  amend (Step 1) before merging.
- **What is the upstream remote name?** Run `git remote`. If exactly one,
  use it. If zero or more than one, ask the user — don't guess.

### Step 1 — chat_log amend (safety-gated)

If the current user's `chat_log.md` is the only thing dirty on the source
branch AND the source branch's last commit is **unpublished** (not on any
remote), amend the chat_log into the last commit so the working tree is
clean before the merge:

```bash
git add .agent/<current-user>/chat_log.md
git commit --amend --no-edit
```

Determine "unpublished" with:

```bash
git branch -r --contains <source>
```

If that output is empty, the last commit is local-only and safe to amend.
**Never amend a commit that's on any remote** — amending rewrites the
commit's hash and will force everyone else's history out of sync. If the
last commit is published, either leave the chat_log uncommitted (it'll
be staged after the merge as a regular commit) or make a fresh commit for
the chat_log update before merging.

### Step 2 — Sync target

```bash
git checkout <target>
git merge --ff-only <remote>/<target>
```

If this is not a clean fast-forward, the target itself has diverged from
upstream — surface that to the user before proceeding. You may need to
rebase or merge the target before doing the cross-namespace merge.

### Step 3 — Start the merge

```bash
git merge --no-commit --no-ff <source>
git status
```

`--no-commit` lets you fix up rename/rename damage before any merge commit
is created. `--no-ff` ensures a real merge commit even if a fast-forward
would have been possible — you want the merge to be a single, reviewable
point in history.

### Step 4 — Per-user rename/rename rescue (the dangerous step)

For each rename/rename conflict where the path on each side lives under a
different `.agent/<user>/...`:

1. **Stage both destination directories:**
   ```bash
   git add .agent/<userA>/ .agent/<userB>/
   ```

2. **Remove the legacy shared path:**
   ```bash
   git rm -f .agent/<old-shared-path>
   ```

3. **Verify per-user content was not cross-contaminated.** Don't trust the
   merge — run the doctor:
   ```bash
   tasks merge-doctor <source> <target>
   ```
   This is the mechanical check. It flags every per-user file that contains
   lines from the OTHER branch's same-relative-path file, regardless of
   whether conflict markers are present (the silent case). If `merge-doctor`
   flags a file, **reset it to its own branch's version**:
   ```bash
   git show <target>:.agent/<userA>/<rel-path> > .agent/<userA>/<rel-path>
   git show <source>:.agent/<userB>/<rel-path> > .agent/<userB>/<rel-path>
   git add .agent/<userA>/<rel-path> .agent/<userB>/<rel-path>
   ```
   Re-run `tasks merge-doctor` after each reset. The doctor is idempotent,
   so safe to run repeatedly.

4. **Grep for stranded markers** (belt-and-braces, the doctor does this
   too):
   ```bash
   git grep -n -e '<<<<<<' -e '>>>>>>' -- .
   ```

### Step 5 — Semantic MIND_MAP merge

A textual three-way merge produces useless conflict markers in narrative
prose. Synthesize the resolution instead — this is prose-reading +
prose-writing, the same shape of work as `/playbook:mindmap`. Do it
continuously (per the Continuation policy above); don't pause to ask.

1. **Pick the richer side** by the heuristic from Step 0.

2. **Fold in unique content from the simpler side.** For each section on the
   simpler side (Tasks, Repository, History), check whether its content is
   already represented in the richer side. If not, add it as a new node.
   Specifically, expect to add:
   - New task nodes for tasks unique to the simpler side.
   - New artifact/deliverable nodes for docs unique to the simpler side.
   - A `merge-<source-branch>` node in History describing this merge.
   - A new decision node if any policy changed (e.g.
     `decision-ignore-current-user` if you switch the policy in Step 6).
   - Updated `git-timeline` showing both diverging lines and the merge.
   - Updated `gitignore-policy` if `.gitignore` changed.
   - Updated `Routing [1]` and `[2]` to mention both coexisting namespaces.

3. **Drop true duplicates** — same fact, two different phrasings: keep the
   richer one.

4. **Remove conflict markers.** Every `<<<<<<`, `=======`, `>>>>>>` must be
   gone. Run `tasks merge-doctor` again to confirm — markers in
   `MIND_MAP.md` should now disappear from `[EXPECTED]` because the file is
   no longer in `git ls-files --unmerged` once you `git add` it in Step 7.

5. **Re-read pass.** Read the merged MIND_MAP back as if you'd never seen
   either branch. Can you tell what merged? Can you tell what each side
   contributed? If the answer to either is "no", the History node is too
   thin — go back and beef it up. The user will see this same MIND_MAP head
   at Step 8 before any push happens.

### Step 6 — `.gitignore` resolution

Prefer `**` globstar over `*` (covers all depths including root). Drop
redundant entries the globstar form already covers. Add install-specific
files that must not be tracked across clones — for playbook installs the
canonical example is `.agent/current_user`, which selects the active user
locally and should never be shared:

```bash
git rm --cached .agent/current_user 2>/dev/null || true
# add `.agent/current_user` (and any other install-local pointer) to .gitignore
git add .gitignore
```

Document this policy change as a new decision node in MIND_MAP (Step 5).
Future-you will want to know why `current_user` stopped being tracked.

### Step 7 — Pre-commit verification

```bash
git status                                       # zero unmerged paths
tasks merge-doctor <source> <target>             # exit 0
grep -rn '<<<<<<' . --exclude-dir=.git || true   # zero markers
git diff --cached --stat                         # what you're about to commit
```

Spot-check (read the actual file content):
- `MIND_MAP.md` — does it document the merge and both namespaces?
- Each user's `chat_log.md` head/tail — only that user's entries, no foreign
  content.
- `.gitignore` — globstars present, redundancies removed, install-local
  entries added.

### Step 8 — Commit, present, and push (the user-gate moment)

**This is the only mandatory user pause in the whole procedure.** Everything
before this step is local, reversible state. The push is the irreversible /
shared-state action — so the user reviews and decides here.

First create the merge commit (not a fast-forward) with a structured
message that documents what was done:

```
Merge <source> into <target>

Parallel lines reconciled:
- <one-line summary of source-branch work>
- <one-line summary of target-branch work>

Resolutions:
- Per-user .agent/ rename/rename: kept both <userA>/ and <userB>/
  namespaces; reset each to its own branch's content to undo silent
  cross-contamination.
- MIND_MAP.md: semantically merged (richer side: <branch>), added
  merge-<source> history node and updated routing.
- .gitignore: switched to ** globstar form; ignored .agent/current_user.

Verified: tasks merge-doctor reports SAFE TO CONTINUE.
```

Then show the user three things, in this order:

1. `git log -1 --stat` of the merge commit (file list + insertion stats).
2. `git show HEAD` for the merge commit (the full diff, especially
   `MIND_MAP.md` — the load-bearing piece).
3. The new `MIND_MAP.md` head (e.g. `head -40 MIND_MAP.md`) so the routing
   nodes are visible at a glance.

Then ask exactly **one** clear question:

> "Push to `<remote>/<target>`?"

Accept three answers:

- `yes` → run `git push <remote> <target>` and report the result.
- `no` → stop. The merge commit stays in the local branch; user can
  `git reset --hard HEAD~1` to undo it or amend.
- `revise X` → make the requested change, amend the merge commit
  (`git commit --amend`), re-present the diff, ask the same question.

**Do not** present multi-option menus ("continue / abort / inspect?") or
ask follow-up questions before the user has answered the push question.

If the remote rejects the push because it's a non-bare working clone with
`<target>` checked out, surface that to the user — the right fix is in the
remote (check out another branch, or set
`receive.denyCurrentBranch=updateInstead` after cleaning the working tree).
**Do not change remote config without explicit consent.**

---

## Pitfalls

These are the four ways this procedure has gone wrong in practice. Every
playbook install will eventually hit at least one. Encode each as a
hard-no:

- **Amending a published commit.** Amending rewrites the commit hash. If the
  commit was already pushed, you've made your local branch incompatible with
  every fetch downstream of it — they'll get a "non-fast-forward" rejection
  or worse, accept the divergent line and create a fork. The Step 1 amend is
  gated on `git branch -r --contains <source>` being empty for exactly this
  reason. **Never amend a commit that's on any remote.**

- **Blind `git add` after rename/rename.** `git add .agent/` after Step 3
  ships the cross-contaminated merged blob in BOTH per-user directories.
  The contamination has no conflict markers in the silent case — you have
  to *deliberately* check for it. Always run `tasks merge-doctor` between
  Step 4 and Step 8.

- **Fast-forwarding when a merge commit was intended.** If `<source>` is
  ahead of `<target>` with no divergence, `git merge` will fast-forward and
  produce no merge commit. The history loses the "we converged the two
  lineages here" marker, and the next merge has less to anchor on. Step 3
  uses `--no-ff` to force a real merge commit even when fast-forward would
  succeed.

- **Pushing to a checked-out remote branch.** If the remote is a working
  clone (not bare) with the target branch currently checked out, git refuses
  the push to protect the remote's working tree. The fix is in the remote:
  check out another branch, or set `receive.denyCurrentBranch=updateInstead`
  *after cleaning the remote's working tree*. Do not silently change the
  remote's config — surface to the user and let them decide.

---

## Parameterization

| Aspect | Source |
|---|---|
| Source branch | Explicit arg (default: current) |
| Target branch | Explicit arg (default: `main`) |
| Upstream remote | Auto-detect single remote, else ask user / explicit |
| User namespaces | Auto-detect via `git ls-tree -d --name-only <branch> -- .agent/` on both branches |
| N (number of users) | Any N ≥ 2; keep every namespace that exists on either side |
| Richer MIND_MAP side | Auto-detect via heuristic (Step 0) |
| MIND_MAP path | `MIND_MAP.md` at repo root (playbook convention) |
| Active-user marker | `.agent/current_user`, treated as install-local (gitignored after Step 6) |

No usernames, branch names, or remote names are hardcoded in the procedure.
The only string this skill needs literally is `.agent/` (the playbook
namespace convention) and `MIND_MAP.md` (the index file at repo root).

---

## Tooling: `tasks merge-doctor`

The contamination check is purely mechanical with a precise definition,
which makes it exactly the step an agent under time pressure will skip.
`tasks merge-doctor` encodes it as one command with a binary verdict:

```
tasks merge-doctor <source> <target>
```

**Inspection contract:** the doctor inspects the current HEAD — working
tree if a merge is in progress (`.git/MERGE_HEAD` present), otherwise the
most recent merge commit reachable from HEAD. `<source>` and `<target>` are
the two ref names of the merge being audited; they are used purely for
cross-comparison, not to switch branches. If neither a mid-merge nor a
reachable merge commit is found, the doctor prints "no merge state detected"
and exits 0.

**What it checks:**

1. **User detection** — union of `git ls-tree -d --name-only` for `.agent/`
   on both refs. Cross-checks against `.agent/current_user` on each side
   where present.

2. **Per-user cross-contamination (silent or marker)** — for each per-user
   file path on either side, captures source-side content, working-tree
   content, and other-user content from the other branch. Flags the file if
   it contains non-trivial lines that originated on the other branch.

3. **Stranded conflict markers** — greps the working tree for `<<<<<<` and
   `>>>>>>`.

4. **Legacy shared paths** — lists `.agent/` files NOT under a detected
   `.agent/<user>/...` directory (and not the `current_user` marker
   itself).

**Behavior:** idempotent (safe to run repeatedly during a merge), exits
non-zero if any finding is present, exits 0 on clean trees.

---

## Out of scope

This skill does not handle:

- **`CLAUDE.md` conflicts.** Each install has its own `CLAUDE.md`; whatever
  `git auto-merge` produces is the default result. If it conflicts, surface
  to the user — the resolution is install-specific.
- **Dormant `branch_a`-style branches** that were rebased onto a different
  ancestor. Bring those up to date with a separate rebase first.
- **Three-way merges** (more than two parent branches). Sequence them into
  two-way merges with this skill applied each time.
- **Automating the semantic MIND_MAP merge itself.** The richer-side
  heuristic helps pick a starting point; the actual merge requires reading
  prose and making judgment calls. Encode the procedure, don't synthesize
  the output.
