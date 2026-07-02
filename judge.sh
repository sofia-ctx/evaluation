#!/usr/bin/env bash
# Judge each captured run against its task's frozen rubric -> {pass,score,notes}.
# One cheap `claude -p` call per run, no tools. Run after run.sh.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNS="$HERE/runs"
MODEL="${JUDGE_MODEL:-sonnet}"

shopt -s nullglob
for metaf in "$RUNS"/*/*/*.meta; do
  stem="${metaf%.meta}"
  task="$(jq -r .task "$metaf" 2>/dev/null)"
  rubricf="$HERE/tasks/$task.rubric"
  if [ ! -f "$rubricf" ]; then
    echo "  ! no rubric for $task"; continue
  fi
  rubric="$(cat "$rubricf")"
  answer="$(jq -r '.result // ""' "$stem.json" 2>/dev/null)"
  diff="$(cat "$stem.diff" 2>/dev/null)"
  vet="$(cat "$stem.vet" 2>/dev/null)"
  prompt="You are a strict judge of a completed development task. Score
strictly against the rubric below. Return ONLY a single-line JSON object,
no markdown fences: {\"pass\":true|false,\"score\":0-100,\"notes\":\"brief\"}.

=== RUBRIC ===
$rubric

=== AGENT'S FINAL ANSWER (result text) ===
$answer

=== CODE DIFF (git diff; empty = no edits were made) ===
$diff

=== go vet (only run when diff is non-empty) ===
$vet"
  verdict="$(claude -p "$prompt" --model "$MODEL" --output-format json \
    --allowedTools '' 2>/dev/null | jq -r '.result // "{}"')"
  # tolerate prose/fences/newlines around the JSON object
  verdict="$(printf '%s' "$verdict" | tr -d '\n' | grep -oE '\{.*\}' | head -1)"
  if ! jq -e . >/dev/null 2>&1 <<<"$verdict"; then
    verdict='{"pass":false,"score":0,"notes":"judge-parse-failed"}'
  fi
  echo "$verdict" >"$stem.verdict"
  printf '  judged %-7s %-12s rep %s -> %s\n' \
    "$(jq -r .arm "$metaf")" "$task" "$(jq -r .rep "$metaf")" \
    "$(jq -c '{pass,score}' <<<"$verdict")"
done
echo "Done. Next: bash aggregate.sh"
