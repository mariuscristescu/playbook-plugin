#!/usr/bin/env bash
# Synthetic git fixture for `tasks merge-doctor`.
#
# Reproduces the cross-namespace rename/rename pattern that motivates the
# skill: a shared `.agent/chat_log.md` renamed into two different per-user
# paths on two branches. Then merges them and asserts that merge-doctor
# flags the silent cross-contamination + the conflict markers in MIND_MAP.
#
# Run from anywhere: `bash claude-playbook-plugin/tests/merge-doctor-fixture.sh`.
# Exits 0 if every scenario passes, non-zero on the first failure.

set -euo pipefail

# Resolve plugin scripts path relative to this file (portable across cwd).
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS="$HERE/../plugins/playbook/scripts"

# Function-form CLI dispatch — handles paths containing spaces correctly,
# unlike a TASKS="env PYTHONPATH=... python3 ..." string that bash would
# word-split on unquoted expansion.
tasks_cli() {
    PYTHONPATH="$PLUGIN_SCRIPTS/lib" python3 -m tasks.cli "$@"
}
export -f tasks_cli 2>/dev/null || true
export PLUGIN_SCRIPTS

PASS=0
FAIL=0

pass() { echo "  PASS  $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

assert_contains() {
    local haystack="$1" needle="$2" label="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        pass "$label (contains '$needle')"
    else
        fail "$label — expected to find '$needle'"
        echo "----- output start -----"
        printf '%s\n' "$haystack"
        echo "----- output end -----"
    fi
}

# Extract the slice of $haystack starting at the line `[<section>]` and
# ending at the next `[<...>]` header or the `merge-doctor:` summary line,
# then assert the slice contains $needle. Catches misclassification
# regressions that plain co-occurrence checks miss (e.g. a contamination
# string appearing under [INFORMATIONAL] would still satisfy
# `assert_contains "$out" "contamination:"`).
assert_in_section() {
    local haystack="$1" section="$2" needle="$3" label="$4"
    local slice
    slice=$(printf '%s\n' "$haystack" | awk -v marker="[$section]" '
        index($0, marker) > 0 { in_sec = 1; next }
        in_sec && (/^\[/ || /^merge-doctor:/) { in_sec = 0 }
        in_sec { print }
    ')
    if [ -z "$slice" ]; then
        fail "$label — [$section] section not found in output"
        return
    fi
    if printf '%s' "$slice" | grep -qF "$needle"; then
        pass "$label ('$needle' in [$section])"
    else
        fail "$label — '$needle' not found under [$section]"
        echo "----- [$section] slice -----"
        printf '%s\n' "$slice"
        echo "----- end slice -----"
    fi
}

assert_nonzero() {
    local rc="$1" label="$2"
    if [ "$rc" -ne 0 ]; then
        pass "$label (exit $rc != 0)"
    else
        fail "$label — expected non-zero exit, got $rc"
    fi
}

assert_zero() {
    local rc="$1" label="$2"
    if [ "$rc" -eq 0 ]; then
        pass "$label (exit 0)"
    else
        fail "$label — expected exit 0, got $rc"
    fi
}

build_two_user_repo() {
    # $1 = repo dir, $2 = userA name, $3 = userB name
    local dir="$1" userA="$2" userB="$3"
    mkdir -p "$dir" && cd "$dir"
    git init -q -b main
    git config user.email "fixture@example"
    git config user.name "fixture"

    # Shared initial commit: legacy `.agent/chat_log.md` + MIND_MAP.md
    # MIND_MAP.md includes a TBD line both branches will rewrite divergently,
    # producing a real --unmerged content conflict on merge (vs append-only
    # edits which git auto-merges cleanly).
    mkdir -p .agent
    printf '[shared chat log line — pre-split]\n' > .agent/chat_log.md
    printf '# MIND_MAP\n\n- [1] **shared-root** — initial structure\n- [2] **active-work** — TBD\n' > MIND_MAP.md
    printf '.agent/current_user\n' > .gitignore
    git add . && git commit -q -m "initial"

    # Branch userA: write current_user marker, rename chat_log, append, edit map.
    # Apple Git 2.50.1 requires the destination directory to exist before
    # `git mv`, so `mkdir -p` it first.
    git checkout -q -b "branch_$userA"
    mkdir -p ".agent/$userA"
    printf '%s\n' "$userA" > .agent/current_user   # gitignored, but mirrors a real install
    git mv .agent/chat_log.md ".agent/$userA/chat_log.md"
    printf '[%s-only line: hello from %s]\n' "$userA" "$userA" >> ".agent/$userA/chat_log.md"
    # Same-line divergent edit on MIND_MAP.md → real merge conflict.
    # Use a portable in-place sed (BSD sed on macOS requires `-i ''`).
    sed -i.bak "s|- \[2\] \*\*active-work\*\* — TBD|- [2] **active-work** — $userA progress|" MIND_MAP.md && rm MIND_MAP.md.bak
    git add . && git commit -q -m "split for $userA"
    git checkout -q main

    # Branch userB: same migration but different user, different MIND_MAP edit
    # of the SAME line — guarantees git's three-way merge can't auto-resolve.
    git checkout -q -b "branch_$userB"
    mkdir -p ".agent/$userB"
    printf '%s\n' "$userB" > .agent/current_user
    git mv .agent/chat_log.md ".agent/$userB/chat_log.md"
    printf '[%s-only line: hello from %s]\n' "$userB" "$userB" >> ".agent/$userB/chat_log.md"
    sed -i.bak "s|- \[2\] \*\*active-work\*\* — TBD|- [2] **active-work** — $userB progress|" MIND_MAP.md && rm MIND_MAP.md.bak
    git add . && git commit -q -m "split for $userB"
    git checkout -q "branch_$userA"
}

# ----- Scenario 1: two-user merge produces detectable contamination ----------
echo "Scenario 1: two-user merge (silent contamination + MIND_MAP markers)"
SCEN1=$(mktemp -d -t merge-doctor-s1.XXXXXX)
( build_two_user_repo "$SCEN1" "userA" "userB" )
cd "$SCEN1"

# Try the merge. Expect rename/rename + MIND_MAP content conflict.
git merge --no-commit --no-ff branch_userB || true

# Diagnostic dump: show what git itself produced before we touch anything.
# Lets a reader of the test output see git's actual rename/rename(1to2)
# behavior on this version, separate from the deterministic detection test
# below.
echo "  --- git-natural rename/rename state (Apple Git $(git --version | awk '{print $3}')) ---"
echo "  .agent/userA listing:"
ls -la .agent/userA 2>/dev/null | sed 's/^/    /' || echo "    (no userA dir)"
echo "  .agent/userB listing:"
ls -la .agent/userB 2>/dev/null | sed 's/^/    /' || echo "    (no userB dir)"
echo "  unmerged paths:"
git ls-files --unmerged | head -10 | sed 's/^/    /' || echo "    (none)"
echo "  --- end git-natural state ---"

# After git's rename/rename(1to2): legacy path is gone (or staged for deletion),
# and the appended content lands in one or both per-user destinations. We
# *manually* induce the cross-contamination the brief describes — git's exact
# behavior varies by version, so we don't depend on it. The point of the test
# is "merge-doctor must catch this state regardless of how it arose":
mkdir -p .agent/userA .agent/userB
# Reset both destinations to their own branch's version first to start clean…
git show "branch_userA:.agent/userA/chat_log.md" > .agent/userA/chat_log.md
git show "branch_userB:.agent/userB/chat_log.md" > .agent/userB/chat_log.md
# …then deliberately contaminate userA's file with a line from userB (no
# conflict marker — the silent case from the brief).
echo "[userB-only line: hello from userB]" >> .agent/userA/chat_log.md
# Note: MIND_MAP.md conflict markers are now produced *naturally* by git's
# three-way merge (both branches edited the same `- [2] **active-work**`
# line divergently in build_two_user_repo), so the file enters
# `git ls-files --unmerged` and the doctor classifies its markers as
# [EXPECTED]. No manual `printf '<<<<<<' >> MIND_MAP.md` injection needed.

set +e
OUT="$(tasks_cli merge-doctor branch_userB branch_userA 2>&1)"
RC=$?
set -e

assert_nonzero "$RC" "S1 exit code non-zero on contamination"
assert_contains "$OUT" "userA" "S1 lists user 'userA'"
assert_contains "$OUT" "userB" "S1 lists user 'userB'"
assert_contains "$OUT" "[ACTIONABLE]" "S1 emits [ACTIONABLE] section"
assert_contains "$OUT" "[EXPECTED]" "S1 emits [EXPECTED] section (MIND_MAP unmerged)"
assert_in_section "$OUT" "ACTIONABLE" "contamination: .agent/userA/chat_log.md" "S1 contamination under [ACTIONABLE]"
assert_in_section "$OUT" "EXPECTED" "MIND_MAP.md" "S1 MIND_MAP marker under [EXPECTED]"
assert_contains "$OUT" "NEEDS ATTENTION" "S1 summary verdict is NEEDS ATTENTION"

cd / && rm -rf "$SCEN1"
echo

# ----- Scenario 2: three-user variant ---------------------------------------
echo "Scenario 2: three-user variant — all namespaces detected"
SCEN2=$(mktemp -d -t merge-doctor-s2.XXXXXX)
mkdir -p "$SCEN2" && cd "$SCEN2"
git init -q -b main
git config user.email "fixture@example"
git config user.name "fixture"
mkdir -p .agent
printf 'shared\n' > .agent/chat_log.md
printf '# MIND_MAP\n' > MIND_MAP.md
git add . && git commit -q -m "initial"

for U in userA userB userC; do
    git checkout -q -b "branch_$U" main
    mkdir -p ".agent/$U"
    git mv .agent/chat_log.md ".agent/$U/chat_log.md"
    # Two short lines per user (~13 chars each, total ~26). Tests the
    # cumulative-bytes rule from W13: neither line alone clears the 20-byte
    # threshold, but together they do — mirroring the realistic chat-log
    # pattern where each message header is short but contamination dumps
    # several at once.
    printf '%s msg one\n%s msg two\n' "$U" "$U" >> ".agent/$U/chat_log.md"
    git add . && git commit -q -m "split for $U"
done

# Build a target that has userB AND userC merged in, then merge userA on top.
git checkout -q branch_userB
git merge --no-commit --no-ff branch_userC || true
mkdir -p .agent/userB .agent/userC
git show branch_userB:.agent/userB/chat_log.md > .agent/userB/chat_log.md
git show branch_userC:.agent/userC/chat_log.md > .agent/userC/chat_log.md
# Commit this combined target.
git add .agent/userB .agent/userC 2>/dev/null || true
git rm -f --ignore-unmatch .agent/chat_log.md 2>/dev/null || true
git commit -q -m "combine userB+userC" || true

# Now merge userA on top: three namespaces total.
git merge --no-commit --no-ff branch_userA || true
mkdir -p .agent/userA
git show branch_userA:.agent/userA/chat_log.md > .agent/userA/chat_log.md
# Contaminate userA with the two short lines userC committed. Neither line
# individually clears the 20-byte threshold; together they do (W13's
# cumulative-bytes rule).
printf 'userC msg one\nuserC msg two\n' >> .agent/userA/chat_log.md

set +e
OUT="$(tasks_cli merge-doctor branch_userA branch_userB 2>&1)"
RC=$?
set -e

assert_nonzero "$RC" "S2 exit code non-zero"
assert_contains "$OUT" "userA" "S2 lists userA"
assert_contains "$OUT" "userB" "S2 lists userB"
assert_contains "$OUT" "userC" "S2 lists userC"
assert_contains "$OUT" "[ACTIONABLE]" "S2 emits [ACTIONABLE] section"
assert_contains "$OUT" "contamination:" "S2 names contamination under actionable"

cd / && rm -rf "$SCEN2"
echo

# ----- Scenario 3: fresh repo with no merge in progress (negative test) ----
echo "Scenario 3: fresh repo, no merge — must report clean"
SCEN3=$(mktemp -d -t merge-doctor-s3.XXXXXX)
mkdir -p "$SCEN3" && cd "$SCEN3"
git init -q -b main
git config user.email "fixture@example"
git config user.name "fixture"
echo "hi" > README.md
git add . && git commit -q -m "initial"

set +e
OUT="$(tasks_cli merge-doctor main main 2>&1)"
RC=$?
set -e

assert_zero "$RC" "S3 exit 0 on clean repo"
assert_contains "$OUT" "no merge state detected" "S3 reports sentinel"

cd / && rm -rf "$SCEN3"
echo

# ----- Scenario 4: stratification — suppress, expected, informational -------
echo "Scenario 4: stratification — gitignored noise suppressed, expected + informational separated"
SCEN4=$(mktemp -d -t merge-doctor-s4.XXXXXX)
mkdir -p "$SCEN4" && cd "$SCEN4"
git init -q -b main
git config user.email "fixture@example"
git config user.name "fixture"
mkdir -p .agent
# Gitignore patterns that mirror a real playbook install — `.DS_Store`
# everywhere, plus the .agent-specific noise files. These cover .agent/.DS_Store
# (zero-dirs-between case of the `**` glob).
printf '**/.DS_Store\n.agent/**/bash_history\n.agent/current_user\n' > .gitignore
# Initial commit: MIND_MAP.md with TBD line for the divergent edit.
printf '# MIND_MAP\n\n- [1] **shared** — root\n- [2] **active** — TBD\n' > MIND_MAP.md
git add . && git commit -q -m "initial"
# Two divergent branches, same-line edit → real conflict on merge.
git checkout -q -b branch_a
sed -i.bak 's|- \[2\] \*\*active\*\* — TBD|- [2] **active** — A progress|' MIND_MAP.md && rm MIND_MAP.md.bak
git add . && git commit -q -m "A edit"
git checkout -q main
git checkout -q -b branch_b
sed -i.bak 's|- \[2\] \*\*active\*\* — TBD|- [2] **active** — B progress|' MIND_MAP.md && rm MIND_MAP.md.bak
git add . && git commit -q -m "B edit"
git checkout -q branch_a
git merge --no-commit --no-ff branch_b || true
# Untracked + gitignored disk noise: should be SUPPRESSED entirely.
touch .agent/.DS_Store
# Untracked + NOT gitignored, sits at .agent/ top level outside any user
# namespace: should be [INFORMATIONAL].
echo "stray legacy content" > .agent/stray.md

set +e
OUT="$(tasks_cli merge-doctor branch_b branch_a 2>&1)"
RC=$?
set -e

assert_zero "$RC" "S4 exit 0 (no actionable findings)"
assert_contains "$OUT" "[EXPECTED]" "S4 emits [EXPECTED] for MIND_MAP active conflict"
assert_contains "$OUT" "MIND_MAP.md" "S4 [EXPECTED] mentions MIND_MAP.md"
assert_contains "$OUT" "[INFORMATIONAL]" "S4 emits [INFORMATIONAL] for stray.md"
assert_contains "$OUT" "stray.md" "S4 [INFORMATIONAL] names stray.md"
assert_contains "$OUT" "SAFE TO CONTINUE" "S4 summary verdict is SAFE TO CONTINUE"
# Suppression: .DS_Store must NOT appear anywhere — neither in any bucket
# nor in the summary counts (which print numbers, not paths).
if printf '%s' "$OUT" | grep -qF '.DS_Store'; then
    fail "S4 .DS_Store should be suppressed entirely but appears in output"
else
    pass "S4 .DS_Store suppressed (not in output)"
fi

cd / && rm -rf "$SCEN4"
echo

# ----- Scenario 5: mixed — actionable + expected + suppressed ---------------
echo "Scenario 5: mixed — contamination [ACTIONABLE] + MIND_MAP [EXPECTED] + .DS_Store suppressed"
SCEN5=$(mktemp -d -t merge-doctor-s5.XXXXXX)
( build_two_user_repo "$SCEN5" "userA" "userB" )
cd "$SCEN5"
# Ensure .DS_Store gitignore is in place (build_two_user_repo only ignores
# current_user). Mirror the S4 pattern.
printf '**/.DS_Store\n.agent/**/bash_history\n.agent/current_user\n' > .gitignore
git add .gitignore && git commit -q --amend --no-edit
git merge --no-commit --no-ff branch_userB || true
mkdir -p .agent/userA .agent/userB
git show "branch_userA:.agent/userA/chat_log.md" > .agent/userA/chat_log.md
git show "branch_userB:.agent/userB/chat_log.md" > .agent/userB/chat_log.md
echo "[userB-only line: hello from userB]" >> .agent/userA/chat_log.md
touch .agent/.DS_Store

set +e
OUT="$(tasks_cli merge-doctor branch_userB branch_userA 2>&1)"
RC=$?
set -e

assert_nonzero "$RC" "S5 exit non-zero (actionable contamination)"
assert_contains "$OUT" "[ACTIONABLE]" "S5 emits [ACTIONABLE]"
assert_in_section "$OUT" "ACTIONABLE" "contamination:" "S5 contamination under [ACTIONABLE]"
assert_contains "$OUT" "[EXPECTED]" "S5 emits [EXPECTED] (MIND_MAP unmerged)"
assert_in_section "$OUT" "EXPECTED" "MIND_MAP.md" "S5 MIND_MAP marker under [EXPECTED]"
assert_contains "$OUT" "NEEDS ATTENTION" "S5 verdict is NEEDS ATTENTION"
if printf '%s' "$OUT" | grep -qF '.DS_Store'; then
    fail "S5 .DS_Store should be suppressed but appears in output"
else
    pass "S5 .DS_Store suppressed (not in output)"
fi

cd / && rm -rf "$SCEN5"
echo

# ----- Scenario 6: post-merge inspection — carve-out for [EXPECTED] ---------
# After the merge commits, MERGE_HEAD is gone and `git ls-files --unmerged`
# is empty, so [EXPECTED] collapses: any surviving marker reports under
# [ACTIONABLE].
echo "Scenario 6a: post-merge clean — no findings"
SCEN6=$(mktemp -d -t merge-doctor-s6.XXXXXX)
mkdir -p "$SCEN6" && cd "$SCEN6"
git init -q -b main
git config user.email "fixture@example"
git config user.name "fixture"
echo "hello" > file.txt
git add . && git commit -q -m "initial"
git checkout -q -b branch_x
echo "branch_x edit" >> file.txt
git add . && git commit -q -m "x"
git checkout -q main
echo "main edit" > other.txt
git add . && git commit -q -m "other"
git merge -q --no-ff -m "merge x" branch_x
# Now in post-merge inspection mode (MERGE_HEAD gone).

set +e
OUT="$(tasks_cli merge-doctor branch_x main 2>&1)"
RC=$?
set -e

assert_zero "$RC" "S6a exit 0 (clean post-merge)"
assert_contains "$OUT" "post-merge" "S6a reports post-merge inspection"

echo "Scenario 6b: post-merge with stranded marker — classifies as [ACTIONABLE]"
# Introduce a marker after the merge committed, then commit again.
printf '<<<<<<< HEAD\nstranded\n=======\nleftover\n>>>>>>> branch_x\n' >> file.txt
git add file.txt && git commit -q -m "oops stranded marker"

set +e
OUT="$(tasks_cli merge-doctor branch_x main 2>&1)"
RC=$?
set -e

assert_nonzero "$RC" "S6b exit non-zero (stranded marker is actionable post-merge)"
assert_contains "$OUT" "[ACTIONABLE]" "S6b stranded marker classified as actionable"
assert_in_section "$OUT" "ACTIONABLE" "stranded conflict markers in file.txt" "S6b names file.txt under [ACTIONABLE]"
if printf '%s' "$OUT" | grep -qF '[EXPECTED]'; then
    fail "S6b should not emit [EXPECTED] in post-merge mode"
else
    pass "S6b no [EXPECTED] section in post-merge mode"
fi

cd / && rm -rf "$SCEN6"
echo

# ----- Scenario 7: tracked .agent/current_user — actionable -----------------
# The install-day bug Step 6 of SKILL.md fixes: some installs accidentally
# tracked .agent/current_user before realizing it should be gitignored.
# Doctor must surface it under [ACTIONABLE] with the git rm --cached hint.
echo "Scenario 7: tracked .agent/current_user — [ACTIONABLE] with git rm --cached hint"
SCEN7=$(mktemp -d -t merge-doctor-s7.XXXXXX)
mkdir -p "$SCEN7" && cd "$SCEN7"
git init -q -b main
git config user.email "fixture@example"
git config user.name "fixture"
mkdir -p .agent
# Deliberately NO gitignore line for current_user — simulating the
# accidentally-tracked case.
printf '**/.DS_Store\n' > .gitignore
printf 'userA\n' > .agent/current_user
printf '# MIND_MAP\n\n- [1] **shared** — root\n- [2] **active** — TBD\n' > MIND_MAP.md
git add . && git commit -q -m "initial (current_user tracked by mistake)"
# Divergent edit to force a merge state so doctor inspects.
git checkout -q -b branch_x
sed -i.bak 's|- \[2\] \*\*active\*\* — TBD|- [2] **active** — X progress|' MIND_MAP.md && rm MIND_MAP.md.bak
git add . && git commit -q -m "X edit"
git checkout -q main
git checkout -q -b branch_y
sed -i.bak 's|- \[2\] \*\*active\*\* — TBD|- [2] **active** — Y progress|' MIND_MAP.md && rm MIND_MAP.md.bak
git add . && git commit -q -m "Y edit"
git checkout -q branch_x
git merge --no-commit --no-ff branch_y || true

set +e
OUT="$(tasks_cli merge-doctor branch_y branch_x 2>&1)"
RC=$?
set -e

assert_nonzero "$RC" "S7 exit non-zero (tracked current_user is actionable)"
assert_in_section "$OUT" "ACTIONABLE" ".agent/current_user" "S7 .agent/current_user under [ACTIONABLE]"
assert_in_section "$OUT" "ACTIONABLE" "git rm --cached" "S7 actionable includes git rm --cached hint"

cd / && rm -rf "$SCEN7"
echo

# ----- Summary --------------------------------------------------------------
echo "============================================"
echo "merge-doctor fixture: $PASS passed, $FAIL failed"
echo "============================================"
[ "$FAIL" -eq 0 ]
