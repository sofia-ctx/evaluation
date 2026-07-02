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
# Knobs (env): TARGET_REPO BASE_SHA ARMS TASKS REPS REP_START MODEL RUN_TIMEOUT WTBASE PERM SF_HOOK_MODE SF_BIN
#
# Smoke (cheapest possible unit — proves the mechanics, not a result):
#   REPS=1 ARMS=sf TASKS=t2_pricing bash run.sh
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
TASKS="${TASKS:-t1_composer t2_pricing}"
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
# tasks/t3_packagist.*), so the arm is differentiated by tool *usage*, not
# just tool availability.
SF_HOOK_MODE="${SF_HOOK_MODE:-nudge}"
# Path to an `sf` binary to put first on PATH inside every spawned session,
# both arms — the global `sf hook pre` PreToolUse hook resolves `sf` via PATH
# at session runtime even in the plain arm (SOFIA_HOOK_MODE=off just makes
# it a fast no-op there), so both arms must resolve the same pinned binary
# or the comparison silently drifts onto whatever build happens to be
# ambient. Unset (default): built once per run.sh invocation from
# TARGET_REPO@BASE_SHA (see resolve_sf_bin), so a stranger cloning this repo
# reproduces the maintainer's binary instead of whatever they personally
# have on PATH.
SF_BIN="${SF_BIN:-}"
SF_BIN_DIR=""

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
file's structure without function bodies; \`sf code <file> <Symbol1> [Symbol2 …]\`
prints one or several symbols' full source in one call; \`sf grep '<pattern>'\`
searches with enclosing function/class context attached to every hit;
\`sf changed [ref]\` summarises a git diff by file/churn/category/touched-symbols
instead of a raw diff dump. To understand a source file's logic, go
structural-first: \`sf code <file>\` for the map, then ONE
\`sf code <file> <Sym1> <Sym2> …\` call for the bodies you actually need —
reach for a full Read only if you genuinely need most of the file at once.
For a single small file you already need in full, one Read is fine — don't
force a structural-read-then-point-read dance where it doesn't pay for itself.

Batch your structural reads: when several files are relevant, request them in
ONE call — \`sf code file1 file2 file3\` — never one call per file; every extra
tool call costs a full round-trip over your whole context. For a single file
under ~150 lines a plain Read is fine. If the bodies you need cover most of a
file, read that file once in full instead. Never re-request a structure or
body you already fetched — earlier tool results are still in your context;
look back instead of calling again. Keep your final answer compact: state the
findings once, without restating the structures you fetched.

See \`sf --help\` and $1/CONTRIBUTING.md for detail.
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
    # PATH is pinned to SF_BIN_DIR so both the agent's own `sf` calls and the
    # hook resolve the same TARGET_REPO@BASE_SHA build, not whatever's ambient.
    ( cd "$wt" && PATH="$SF_BIN_DIR:$PATH" SOFIA_HOOK_MODE="$SF_HOOK_MODE" timeout "$RUN_TIMEOUT" claude -p "$prompt" "${common[@]}" "${args[@]}" ) \
      >"$stem.json" 2>"$stem.stderr"; rc=$?
  else
    # SOFIA_HOOK_MODE=off silences the global `sf hook pre` PreToolUse nudge
    # for the control arm even though it's registered in ~/.claude/settings.json.
    # PATH is still pinned: the hook still resolves `sf` via PATH to run its
    # (now no-op) check, so it must be the same pinned binary as the sf arm.
    ( cd "$wt" && PATH="$SF_BIN_DIR:$PATH" SOFIA_HOOK_MODE=off timeout "$RUN_TIMEOUT" claude -p "$prompt" "${common[@]}" "${args[@]}" ) \
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

# Resolve SF_BIN/SF_BIN_DIR before any claude call is spawned. If SF_BIN is
# already set (user knob), just point SF_BIN_DIR at its directory. Otherwise
# build one from TARGET_REPO@BASE_SHA: same detached-worktree technique
# run_one uses for task worktrees, but here just to compile a pinned binary.
# Returns non-zero (and prints why) instead of ever letting a run start
# against an unpinned or broken `sf` — a stranger's clone should reproduce
# the maintainer's binary, not silently fall through to PATH.
resolve_sf_bin() {
  if [ -n "$SF_BIN" ]; then
    if [ ! -x "$SF_BIN" ]; then
      echo "! SF_BIN=$SF_BIN is not an executable file" >&2
      return 1
    fi
    SF_BIN_DIR="$(cd "$(dirname "$SF_BIN")" && pwd)"
    echo "Using pinned sf binary: $SF_BIN" >&2
    return 0
  fi

  local short
  short="$(git -C "$TARGET_REPO" rev-parse --short "$BASE_SHA" 2>/dev/null)"
  if [ -z "$short" ]; then
    echo "! could not resolve BASE_SHA ($BASE_SHA) in TARGET_REPO ($TARGET_REPO)" >&2
    return 1
  fi
  local srcwt="$WTBASE/sf-bin-src-$short"
  local bindir="$WTBASE/sf-bin-$short"
  rm -rf "$srcwt"
  echo "Building pinned sf binary from TARGET_REPO@$short into $bindir ..." >&2
  if ! git -C "$TARGET_REPO" worktree add -q --detach "$srcwt" "$BASE_SHA"; then
    echo "! could not create build worktree for sf@$short" >&2
    return 1
  fi
  mkdir -p "$bindir"
  if ! ( cd "$srcwt" && go build -o "$bindir/sf" ./cmd/sf ); then
    echo "! go build of sf@$short failed — aborting before spending anything" >&2
    git -C "$TARGET_REPO" worktree remove --force "$srcwt" >/dev/null 2>&1
    return 1
  fi
  git -C "$TARGET_REPO" worktree remove --force "$srcwt" >/dev/null 2>&1
  SF_BIN="$bindir/sf"
  SF_BIN_DIR="$bindir"
  echo "Pinned sf binary ready: $SF_BIN" >&2
}

# Guard so this file can be `source`d (e.g. to call resolve_sf_bin directly
# for a free, no-claude-calls test of the build-pinning path) without also
# kicking off the full, money-spending A/B loop below.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if ! resolve_sf_bin; then
    echo "! could not resolve a pinned sf binary — aborting before running anything." >&2
    exit 1
  fi

  echo "A/B run: target=$TARGET_REPO base=$BASE_SHA arms=[$ARMS] tasks=[$TASKS] reps=$REPS model=$MODEL perm=$PERM sf_hook=$SF_HOOK_MODE sf_bin=$SF_BIN"
  for task in $TASKS; do
    for arm in $ARMS; do
      for rep in $(seq "$REP_START" "$REPS"); do
        run_one "$arm" "$task" "$rep"
      done
    done
  done
  echo "Done. Next: bash judge.sh && bash aggregate.sh"
fi
