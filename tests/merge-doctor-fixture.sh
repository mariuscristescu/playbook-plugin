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
    mkdir -p .agent
    printf '[shared chat log line — pre-split]\n' > .agent/chat_log.md
    printf '# MIND_MAP\n\n- [1] **shared-root** — initial structure\n' > MIND_MAP.md
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
    printf '\n- [2] **%s-node** — work by %s\n' "$userA" "$userA" >> MIND_MAP.md
    git add . && git commit -q -m "split for $userA"
    git checkout -q main

    # Branch userB: same migration but different user, different MIND_MAP edit.
    git checkout -q -b "branch_$userB"
    mkdir -p ".agent/$userB"
    printf '%s\n' "$userB" > .agent/current_user
    git mv .agent/chat_log.md ".agent/$userB/chat_log.md"
    printf '[%s-only line: hello from %s]\n' "$userB" "$userB" >> ".agent/$userB/chat_log.md"
    printf '\n- [3] **%s-node** — work by %s with extra detail to clash\n' "$userB" "$userB" >> MIND_MAP.md
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
# MIND_MAP needs a conflict marker (the merge already produced one if the
# content actually conflicted; if not, we synthesize a representative one).
if ! grep -qF '<<<<<<' MIND_MAP.md; then
    printf '\n<<<<<<< HEAD\nmap divergence A\n=======\nmap divergence B\n>>>>>>> branch_userB\n' >> MIND_MAP.md
fi

set +e
OUT="$(tasks_cli merge-doctor branch_userB branch_userA 2>&1)"
RC=$?
set -e

assert_nonzero "$RC" "S1 exit code non-zero on contamination"
assert_contains "$OUT" "userA" "S1 lists user 'userA'"
assert_contains "$OUT" "userB" "S1 lists user 'userB'"
assert_contains "$OUT" "CONTAMINATION" "S1 names contamination finding"
assert_contains "$OUT" ".agent/userA/chat_log.md" "S1 names contaminated file"
assert_contains "$OUT" "MIND_MAP.md" "S1 flags MIND_MAP markers"

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

# ----- Summary --------------------------------------------------------------
echo "============================================"
echo "merge-doctor fixture: $PASS passed, $FAIL failed"
echo "============================================"
[ "$FAIL" -eq 0 ]
