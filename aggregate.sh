#!/usr/bin/env bash
# Aggregate runs+verdicts into per-(arm,task) medians (passing runs only for
# cost/token metrics). Emits a records JSONL and prints a CSV summary.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNS="$HERE/runs"
rec="$RUNS/_records.jsonl"; : >"$rec"

shopt -s nullglob
for metaf in "$RUNS"/*/*/*.meta; do
  stem="${metaf%.meta}"
  j="$stem.json"; v="$stem.verdict"
  arm="$(jq -r .arm "$metaf")"; task="$(jq -r .task "$metaf")"; rep="$(jq -r .rep "$metaf")"
  wall="$(jq -r '.wall_ms // 0' "$metaf")"; rc="$(jq -r '.rc // -1' "$metaf")"
  sid="$(jq -r '.sid // ""' "$metaf")"
  cost="$(jq -r '.total_cost_usd // 0' "$j" 2>/dev/null)"; cost="${cost:-0}"
  inp="$(jq -r '.usage.input_tokens // 0' "$j" 2>/dev/null)"; inp="${inp:-0}"
  cr="$(jq -r '.usage.cache_read_input_tokens // 0' "$j" 2>/dev/null)"; cr="${cr:-0}"
  cc="$(jq -r '.usage.cache_creation_input_tokens // 0' "$j" 2>/dev/null)"; cc="${cc:-0}"
  out="$(jq -r '.usage.output_tokens // 0' "$j" 2>/dev/null)"; out="${out:-0}"
  turns="$(jq -r '.num_turns // 0' "$j" 2>/dev/null)"; turns="${turns:-0}"
  pass="$(jq -r '.pass // false' "$v" 2>/dev/null)"; pass="${pass:-false}"
  score="$(jq -r '.score // 0' "$v" 2>/dev/null)"; score="${score:-0}"
  billed_in=$(( inp + cr + cc ))
  jq -cn \
    --arg arm "$arm" --arg task "$task" --argjson rep "${rep:-0}" \
    --argjson cost "$cost" --argjson billed_in "$billed_in" --argjson out "$out" \
    --argjson cr "$cr" --argjson cc "$cc" --argjson turns "$turns" \
    --argjson wall "${wall:-0}" --argjson score "$score" --argjson rc "${rc:--1}" \
    --arg pass "$pass" --arg sid "$sid" \
    '{arm:$arm,task:$task,rep:$rep,cost_usd:$cost,billed_in:$billed_in,
      cache_read:$cr,cache_creation:$cc,out:$out,turns:$turns,wall_ms:$wall,
      pass:($pass=="true"),score:$score,rc:$rc,sid:$sid}' >>"$rec"
done

echo "records -> $rec  ($(wc -l <"$rec" | tr -d ' ') runs)"
echo
jq -rs '
  def median: sort | if length==0 then null
    elif length%2==1 then .[(length/2|floor)]
    else ((.[length/2-1]+.[length/2])/2) end;
  group_by(.arm+"/"+.task)
  | map(
      (.[0].arm) as $arm | (.[0].task) as $task |
      (map(select(.pass))) as $p |
      { arm:$arm, task:$task, n:length, pass:($p|length),
        med_cost_usd:   ($p|map(.cost_usd)|median),
        med_billed_in:  ($p|map(.billed_in)|median),
        med_cache_read: ($p|map(.cache_read)|median),
        med_out:        ($p|map(.out)|median),
        med_turns:      ($p|map(.turns)|median),
        med_wall_ms:    ($p|map(.wall_ms)|median) } )
  | (.[0]|keys_unsorted) as $c | ($c|@csv), (.[]|[.[$c[]]]|@csv)
' "$rec" | sed 's/"//g'
