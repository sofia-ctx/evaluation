# dir-map passthrough A/B — pre-registration + results

**Pre-registered 2026-07-11 BEFORE any paid run.** Do not edit the pre-registration section after the first run; results are appended below.

## Context
Follow-up to the free dir-brief measurement (`2026-07-11-dir-brief-passthrough.md`), which found `--brief` can't shrink dir maps because per-file **raw-passthrough** (files < 8K emitted verbatim) dominates them, and forcing summarisation instead cuts the map **73–87%**. This A/B asks the downstream question that free measurement can't: does a smaller dir map actually lower an agent's cost on a real "map this package" task, and at what quality?

## Hypothesis
On a package-structure comprehension task (`sf code <dir>` is the natural first move), summarising small files instead of passing them through gives a ~75% smaller map, lowering the agent's cost and context integral, with **equal** answer quality — because a package map's value is signatures/types, and the one place a small file's *body* matters (the categoriser rules) is reachable by a single targeted `sf code <file>` slice.

## Design (isolates the threshold, t4-style — one HEAD binary vs itself)
Both arms are the **sf** arm; they differ ONLY by the raw-passthrough threshold:
- **RAW** = default `SOFIA_CODE_RAW_BELOW` (8192) — small files come back verbatim.
- **SUM** = `SOFIA_CODE_RAW_BELOW=1` — every file is summarised (signatures/types).

Same task `t6_dirmap` (map `internal/cc`: 11 files, 6 < 8K), same BASE_SHA=257718b, model sonnet, `SF_HOOK_MODE=nudge`, same preamble. Isolated `SOFIA_LOG_DIR` per arm; fresh worktree + native session id per rep. Free tool-output baseline for this dir at BASE_SHA: RAW 15595 tok vs SUM 3829 tok (−75%).

### Exact commands
```
SF_BIN=…/bin/sf SOFIA_LOG_DIR=~/dirmap/raw                       REPS=1 ARMS=sf TASKS=t6_dirmap bash run.sh
SF_BIN=…/bin/sf SOFIA_LOG_DIR=~/dirmap/sum SOFIA_CODE_RAW_BELOW=1 REPS=1 ARMS=sf TASKS=t6_dirmap bash run.sh
```
Cost/turns/usage from each `runs/sf/t6_dirmap/<rep>.json`; sf calls from each arm's `calls.jsonl`; quality via public `judge.sh`.

## Criteria (pre-registered)
- **primary (cheaper)**: median cost SUM < RAW, AND median cache_read (context integral) SUM < RAW.
- **quality carry**: judge(SUM) ≥ judge(RAW) − ~8 (summarising must not cost correctness). A quality TIE at lower cost = the win.
- **mechanism**: the SUM arm's `sf code internal/cc` really returns the compact map (no raw bodies); if the SUM agent then targeted-slices `category.go` for Q4, that's expected and fine (still cheaper overall if primary holds).
- **carry**: exit==0 both arms.

## Honest-null / honest-loss clause
- If **cost doesn't drop** (the dir map is a small fraction of the run's context integral — the agent spends its tokens elsewhere), the 75% map saving doesn't translate → **NULL** ("the map isn't the cost driver here"), not a win.
- If **SUM quality drops materially** (the agent needed the raw small-file bodies and a summarised map + targeted slices didn't recover them) → **honest LOSS for summarise-by-default**: the trade-off is real, raw small files carry content a map loses. Reported as such; the task will NOT be re-tuned to hide it.

## Stop-loss
- Auth already green today. n=1 each arm first; inspect. Escalate to n=3/arm ONLY if rep-1 shows cheaper-at-equal-quality worth confirming. A clear null (no cost delta) or a quality loss → stop; don't burn. One corrected re-run for a setup bug only. Budget ~$2; cap n=3/arm.

---

## Results (2026-07-11, sonnet, BASE_SHA=257718b, n=3/arm)

RAW = reps 1,3,5 (default threshold 8192); SUM = reps 2,4,6 (`SOFIA_CODE_RAW_BELOW=1`). All exit==0.

| median n=3 | RAW (default) | SUM (summarise) |
| --- | ---: | ---: |
| turns | **7**  [6,14,7] | 10  [7,10,13] |
| cost $ | 0.414  [.371,.590,.414] | 0.414  [.326,.414,.459] |
| cache_read (context integral / North Star) | **263K**  [198,705,263] | 436K  [230,436,479] |
| judge | 90  [90,90,90] | 90  [90,90,85] |

Rep-1 trace (the mechanism, verified in `calls.jsonl`): **RAW = 5 `sf code` calls** — 1 whole-package map (its 7 small files raw) + re-reads of only the 4 *large* summarised files (cc/candidates/show/value). **SUM = 10 calls** — 1 all-summarised map + individual re-reads of 9 files to recover the bodies the map omitted. Same answer (judge 90=90).

### Verdict — the flip is REFUTED; keep raw-passthrough
Summarising the dir map does **not** lower cost (tied at $0.414) and is **worse** on the two behavioural metrics — turns 10 vs 7, context integral 436K vs 263K (SUM +66%) — at equal quality (90 vs 90). So the earlier free-measurement conclusion ("force-summarise cuts the map 73–87% → make it the dir default") is **wrong downstream**: that measurement counted only the *initial map*, not the re-fetches. The agent re-fetches the bodies it needs regardless (the refs-pilot lesson again), so summarising just moves the same content from **one efficient upfront batch (the raw map)** to **a fan of individual re-reads (higher integral)**. Raw-passthrough of small files is doing real work — front-loading what the agent would otherwise re-request.

- **Do NOT build summarise-by-default / a lower dir-mode threshold.** No code change. `SOFIA_CODE_RAW_BELOW` stays 8192; the current `sf code <dir>` behaviour is right.
- **Calibration point worth keeping:** raw output size is **not** a proxy for agent cost — a 75%-smaller map produced a *higher* context integral. Free tool-output measurements bound the map, never the downstream integral; only a turn-level A/B sees that. (Same trap the `sf refs` footer falls into.)
- High variance (RAW rep3 spiked to 14 turns / 705K — a bad RAW run), so neither arm is dramatically better; the honest read is "summarising is no win and a mild integral/turn loss — leave it alone."

Spend ≈ $2.5 (6 reps + judge). This A/B **prevented shipping a feature that would have made dir maps worse**, which is the whole point of measuring before building.
