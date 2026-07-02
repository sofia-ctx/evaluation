#!/usr/bin/env bash
# A/B: does the `sf` CLI (github.com/sofia-ctx/sofia) earn its tokens?
#
# Each run is one throwaway `git worktree` of TARGET_REPO at a frozen
# BASE_SHA, one headless `claude -p` invocation, captured result JSON + diff.
# One arm has `sf` available (tools + the global PreToolUse nudge hook), the
# other arm is plain Read/Grep/Glob/Edit with the hook off. See README.md for
# the full design and docs/measurements/evaluation/{micro,macro}.md in
# sofia-ctx/sofia for the methodology this reproduces.
#
# Guarded by default: tools are allowlisted (no arbitrary shell), edits land
# only in the disposable worktree. PERM=bypass switches to
# --dangerously-skip-permissions (faster, unguarded — opt-in only).
#
# Knobs (env): TARGET_REPO BASE_SHA ARMS TASKS REPS REP_START MODEL RUN_TIMEOUT WTBASE PERM SF_HOOK_MODE
#
# Smoke (cheapest possible unit — proves the mechanics, not a result):
#   REPS=1 ARMS=sf TASKS=t3_pricing bash run.sh
# Full study (real cost — a separate, deliberate decision, not a default):
#   bash run.sh
set -uo pipefail

# Detach from any ambient sf project-tag env so calllog inside each spawned
# session tags itself from the worktree it actually runs in, not from
# whatever project this harness happens to be invoked from.
unset SOFIA_TAG

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_REPO="${TARGET_REPO:-../sofia}"
# HEAD of sofia-ctx/sofia's main at the time these demo tasks/rubrics were
# written and verified against the real files. Pin it so the rubrics stay
# valid regardless of what lands on main later; override to test against a
# different commit (rubrics will no longer be guaranteed accurate).
BASE_SHA="${BASE_SHA:-257718bfc4d6fee74322c24f4c90e8db02c99efa}"
MODEL="${MODEL:-sonnet}"
ARMS="${ARMS:-sf plain}"
TASKS="${TASKS:-t1_calllog t2_composer t3_pricing}"
REPS="${REPS:-5}"
# First rep index to run (default 1). Lets a partial run resume without
# redoing completed reps — e.g. run rep 1 as a pilot, inspect it, then
# REP_START=2 to finish reps 2..REPS reusing the pilot's rep-1 artifacts.
REP_START="${REP_START:-1}"
RUN_TIMEOUT="${RUN_TIMEOUT:-600}"
WTBASE="${WTBASE:-/tmp/ab-sofia-wt}"
PERM="${PERM:-allowlist}" # allowlist (guarded) | bypass (--dangerously-skip-permissions)
# SOFIA_HOOK_MODE for the sf arm's `sf hook pre` PreToolUse nudge:
#   nudge (default, production) — deny the FIRST full read of a big source
#   file, let an identical repeat through; strict — always deny full reads of
#   big source files (no second-chance pass-through); suggest — advise only.
# The control arm always forces off. Set SF_HOOK_MODE=strict to make the hook
# an actual forcing function on a full-file-comprehension task (see
# tasks/t4_packagist.*), so the arm is differentiated by tool *usage*, not
# just tool availability.
SF_HOOK_MODE="${SF_HOOK_MODE:-nudge}"

if [ ! -d "$TARGET_REPO/.git" ]; then
  echo "! TARGET_REPO ($TARGET_REPO) is not a git checkout. Clone sofia-ctx/sofia next to this repo, or set TARGET_REPO." >&2
  exit 1
fi
TARGET_REPO="$(cd "$TARGET_REPO" && pwd)"

RUNS="$HERE/runs"
mkdir -p "$RUNS" "$WTBASE"
git -C "$TARGET_REPO" worktree prune 2>/dev/null || true

sf_preamble() { # $1 = worktree dir — what the sf arm is told
  cat <<EOF
This session works on the 'sofia' project (working directory $1, the
sofia-ctx/sofia Go toolkit). You are already in this directory — do not
\`cd\` elsewhere. Read $1/CONTRIBUTING.md at the start and follow it. The
\`sf\` CLI is on PATH and saves tokens versus raw Read/cat/grep on source
files (.go/.php/.ts/.tsx/.vue) — prefer it: \`sf code <file>\` prints a
file's structure without function bodies; \`sf code <file> <Symbol>\` prints
one symbol's full source; \`sf grep '<pattern>'\` searches with enclosing
function/class context attached to every hit; \`sf changed [ref]\`
summarises a git diff by file/churn/category/touched-symbols instead of a
raw diff dump. To understand a source file's logic, go structural-first:
\`sf code <file>\` for the map, then \`sf code <file> <Symbol>\` for each body
you actually need — reach for a full Read only if you genuinely need most of
the file at once. For a single small file you already need in full, one Read
is fine — don't force a structural-read-then-point-read dance where it
doesn't pay for itself. See \`sf --help\` and $1/CONTRIBUTING.md for detail.
EOF
}

plain_preamble() { # $1 = worktree dir — control: same repo, no sf
  cat <<EOF
This session works on the 'sofia' project (working directory $1, a Go
codebase). You are already in this directory — do not \`cd\` elsewhere. Read
$1/CONTRIBUTING.md at the start and follow it. Use ONLY standard tools
(Read, Grep, Glob, Edit) to navigate and edit code. Do NOT use the \`sf\` CLI
or any of its subcommands, even if it is on PATH. Work directly, without
unnecessary detours.
EOF
}

run_one() {
  local arm="$1" task="$2" rep="$3"
  local outdir="$RUNS/$arm/$task"; mkdir -p "$outdir"
  local stem="$outdir/$rep"
  local wt="$WTBASE/$arm-$task-$rep"
  rm -rf "$wt"
  if ! git -C "$TARGET_REPO" worktree add -q --detach "$wt" "$BASE_SHA" 2>"$stem.stderr"; then
    echo "  ! worktree add failed: $wt"; return 1
  fi
  local taskfile="$HERE/tasks/$task.task"
  if [ ! -f "$taskfile" ]; then
    echo "  ! no task file: $taskfile"; git -C "$TARGET_REPO" worktree remove --force "$wt" >/dev/null 2>&1; return 1
  fi
  local prompt; prompt="$(cat "$taskfile")"

  local -a common=(--model "$MODEL" --output-format json)
  if [ "$PERM" = bypass ]; then
    common+=(--dangerously-skip-permissions)
  else
    common+=(--permission-mode acceptEdits)
  fi
  local -a args
  if [ "$arm" = sf ]; then
    args=(--append-system-prompt "$(sf_preamble "$wt")")
    [ "$PERM" = bypass ] || args+=(--allowedTools Read Edit Write Grep Glob "Bash(sf:*)")
  else
    args=(--append-system-prompt "$(plain_preamble "$wt")")
    [ "$PERM" = bypass ] || args+=(--allowedTools Read Edit Write Grep Glob)
  fi

  local t0 t1 rc
  t0=$(date +%s.%N)
  if [ "$arm" = sf ]; then
    # SOFIA_HOOK_MODE ($SF_HOOK_MODE, default nudge) drives the global
    # `sf hook pre` PreToolUse nudge for the treatment arm; strict turns it
    # into a hard forcing function toward `sf code` on big source files.
    ( cd "$wt" && SOFIA_HOOK_MODE="$SF_HOOK_MODE" timeout "$RUN_TIMEOUT" claude -p "$prompt" "${common[@]}" "${args[@]}" ) \
      >"$stem.json" 2>"$stem.stderr"; rc=$?
  else
    # SOFIA_HOOK_MODE=off silences the global `sf hook pre` PreToolUse nudge
    # for the control arm even though it's registered in ~/.claude/settings.json.
    ( cd "$wt" && SOFIA_HOOK_MODE=off timeout "$RUN_TIMEOUT" claude -p "$prompt" "${common[@]}" "${args[@]}" ) \
      >"$stem.json" 2>"$stem.stderr"; rc=$?
  fi
  t1=$(date +%s.%N)

  git -C "$wt" diff >"$stem.diff" 2>/dev/null
  : >"$stem.vet"
  if [ -s "$stem.diff" ] && command -v go >/dev/null 2>&1; then
    ( cd "$wt" && go vet ./... ) >>"$stem.vet" 2>&1
  fi
  local cost sid wall_ms
  cost="$(jq -r '.total_cost_usd // 0' "$stem.json" 2>/dev/null)"
  sid="$(jq -r '.session_id // ""' "$stem.json" 2>/dev/null)"
  wall_ms=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%d", (b-a)*1000}')
  printf '{"arm":"%s","task":"%s","rep":%s,"rc":%s,"wall_ms":%s,"sid":"%s"}\n' \
    "$arm" "$task" "$rep" "$rc" "$wall_ms" "$sid" >"$stem.meta"
  git -C "$TARGET_REPO" worktree remove --force "$wt" >/dev/null 2>&1
  echo "  done $arm/$task/$rep  rc=$rc  wall=${wall_ms}ms  cost=\$$cost  sid=$sid"
}

echo "A/B run: target=$TARGET_REPO base=$BASE_SHA arms=[$ARMS] tasks=[$TASKS] reps=$REPS model=$MODEL perm=$PERM sf_hook=$SF_HOOK_MODE"
for task in $TASKS; do
  for arm in $ARMS; do
    for rep in $(seq "$REP_START" "$REPS"); do
      run_one "$arm" "$task" "$rep"
    done
  done
done
echo "Done. Next: bash judge.sh && bash aggregate.sh"
