# t4 dedup re-pilot — pre-registration + results

**Pre-registered 2026-07-08 BEFORE any paid run.** Do not edit the pre-registration section after the first run; results are appended below.

## Hypothesis
The H-B per-session dedup stub (shipped v0.2.0, `internal/dedup`, wired into `sf code`) removes the "re-fetch hammer" — byte-identical repeated `sf code` calls — collapsing each repeat to a ~19-token stub instead of the full output. On the t4_dispatch task (many-file structural map, where the batch->re-open pathology surfaced in H1/H4), this should lower cost if the agent issues identical repeats.

## Design (isolates dedup, not confounded with other HEAD features)
A/B of ONE HEAD `sf` binary against itself; arms differ ONLY by the dedup window:
- **ON**  = `SOFIA_DEDUP_WINDOW=3600` (dedup active; generous window so late re-opens still stub)
- **OFF** = `SOFIA_DEDUP_WINDOW=0` (dedup disabled)

Same task `t4_dispatch`, same `BASE_SHA=257718b`, model sonnet, `SF_HOOK_MODE=nudge`, same preamble. HEAD-vs-published would confound dedup with footer/brief/raw-passthrough/dir-mode — rejected.

Telemetry isolated per arm via separate `SOFIA_LOG_DIR` (dedup state is a sibling of `calls.jsonl`, so it's isolated too). Each rep gets a fresh native `CLAUDE_CODE_SESSION_ID` (unique per claude session -> clean per-rep dedup state); `SOFIA_SESSION_ID` deliberately NOT pinned (a fixed id would share dedup state across reps).

### Exact commands
```
go build -o ~/sf-dedup/sf ./cmd/sf        # HEAD (has internal/dedup)
# ON:
SF_BIN=~/sf-dedup/sf SOFIA_LOG_DIR=~/t4-pilot/on  SOFIA_DEDUP_WINDOW=3600 \
  REPS=1 ARMS=sf TASKS=t4_dispatch bash run.sh
# OFF:
SF_BIN=~/sf-dedup/sf SOFIA_LOG_DIR=~/t4-pilot/off SOFIA_DEDUP_WINDOW=0 \
  REPS=1 ARMS=sf TASKS=t4_dispatch bash run.sh
```
Cost from each run's `runs/sf/t4_dispatch/1.json` `.total_cost_usd`; dedup fires from `<SOFIA_LOG_DIR>/calls.jsonl` (`grep '"dedup":true'`); identical-repeat count by grouping `tool=="code"` args; judge via public `judge.sh`.

## Criteria (pre-registered)
- **primary**: median cost ON < median cost OFF (dedup reduces $).
- **mechanism**: dedup stub fires >=1x in the ON arm AND identical-repeat count(ON) < identical-repeat count(OFF).
- **carry**: exit!=0 count = 0; judge score >= 90.

## Honest null clause
The harness preamble explicitly instructs the agent to "never re-request a structure/body you already fetched." That suppresses the very identical repeats dedup catches. **If the OFF arm shows ~0 identical repeats, there is no pathology to fix under the current preamble** — the verdict is **NULL** ("mechanism has nothing to bite here"), NOT a win or a loss. The task will NOT be tuned to manufacture repeats.

## Stop-loss
- Auth dead (smoke rc!=0) -> stop, no paid run.
- n=1 each first. Escalate to n=3/arm ONLY if the mechanism is visibly at work (stub fires and reduces repeats) on n=1. A clear NULL or two criterion misses -> stop; don't burn.
- One corrected re-run only for a setup bug (SF_BIN not on HEAD / empty session id / window too short). Budget ~$1-2; cap n=3/arm (original t4 overran to ~$5 for 6 sessions).

---

## Results

**Auth smoke:** bare `claude -p` probe rc=0 (result "ok", $0.061) — OAuth token alive despite a stale `daemon-auth-status=auth_required`. Gate PASSED.

**ON arm (`SOFIA_DEDUP_WINDOW=3600`), t4_dispatch rep 1:** rc=0, cost **$0.717**, wall 291s, sid `b3200ea2`. `sf code` calls: **8**. Dedup stub fires: **0**.

### Diagnosis — genuine NULL, not a setup bug
- All 8 code calls carry a non-empty session id -> dedup was ENABLED (not disabled by a missing sid); `SOFIA_LOG_DIR` propagated (calls logged to the isolated dir); window 3600.
- The 8 calls are all distinct: four batched multi-file summaries (3+5+5+3 files) plus symbol-slices. The only same-file revisit — `calllog.go` sliced twice — requested DIFFERENT symbol sets (6 then 3), so the dedup key (which includes each `sym=`) differs -> correctly not a hit. **Zero byte-identical repeats occurred.**
- Dedup therefore had nothing to collapse. The "re-fetch hammer" (8x identical calls, H1) and batch->re-open (H4) are gone: HEAD `sf` (multi-symbol slicing, multi-file/dir batching, `--brief`) + the current preamble ("never re-request a structure/body you already fetched") produce an efficient, non-repeating trace — **8 calls vs the 47/33/50 of the 2026-07-02 baseline.**

### OFF arm skipped (frugal, airtight)
Dedup fired 0x, so it suppressed nothing -> the ON trajectory is identical to what OFF would produce; OFF cannot reveal repeats that ON's (inactive) dedup hid. Running it would spend ~$0.75 to reconfirm "0 repeats." Per the pre-registered stop-loss ("clear NULL -> stop, don't burn"), stopped at n=1.

### Verdict: NULL (as the pre-registered null clause anticipated)
Not a win, not a loss. Dedup's code is correct (unit-tested; a manual identical repeat DOES stub — 19 vs 827 tokens) but **INERT on t4 under current sf+preamble**, because the repeat pathology it targets no longer occurs on this task.
- primary (median $ ON<OFF): N/A — dedup inert, no cost delta to measure.
- mechanism (stub fires >=1, repeats ON<OFF): fails by absence — 0 repeats to fire on.
- carry: exit!=0 = 0 -> PASS; judge score -> not run (transient classifier outage during the judge call; not load-bearing for a NULL established directly from the call log).

**Spend:** ~$0.78 (auth probe $0.061 + ON rep $0.717). OFF + escalation not run.

### Implications
- The "t4 dedup re-pilot" is **retired as a way to validate H-B**: the pathology dedup targets is designed out of this task by earlier improvements + preamble discipline. A real validation would need a task/preamble that organically induces identical repeats (e.g. a long multi-turn task where context compaction forces re-fetches) — a different experiment.
- Honest read: the earlier levers (multi-symbol, batching, brief) + preamble already captured the value dedup aimed at; dedup is now a cheap, correct safety-net for the residual case, not a primary economic lever. It stays (free + correct), but its footer/telemetry won't show savings on well-behaved traces.
- Do NOT tune t4 to manufacture repeats.
