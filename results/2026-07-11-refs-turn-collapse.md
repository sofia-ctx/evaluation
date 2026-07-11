# refs turn-collapse pilot — pre-registration + results

**Pre-registered 2026-07-11 BEFORE any paid run.** Do not edit the pre-registration section after the first run; results are appended below.

## Hypothesis
`sf refs <symbol>` returns every definition/use of a symbol across the tree, each hit carrying its **enclosing function**, in ONE call. On a task that needs the per-site enclosing context (not just line hits), this collapses the agent's tool-call turns: the sf arm answers from one `sf refs` call, while the plain arm must `grep` (line hits only, no enclosing function) and then **open each file** to recover the enclosing context and spot deviations. The footer (`sf refs` ≈ raw `grep -rn` in tokens, sometimes slightly costlier) undersells this because it counts only the one call's bytes, not the fan of downstream reads the plain arm needs.

Two ways sf can win: **fewer turns** (primary) and **higher completeness** (it surfaces all enclosing contexts at once, so it's less likely to miss a deviation that lives in a file the plain arm never opened).

## Task (t5_refs, tool-agnostic)
"Map every use of `calllog.Counter`: the uniform construction pattern, every deviation (with file + enclosing function), and counts." Ground truth (`tasks/t5_refs.rubric`, frozen at BASE_SHA via `sf refs Counter --max 100`): 1 def + 31 uses = 32 refs; 22 uniform `&calllog.Counter{W: w}` sites in a `Run(…, w io.Writer)`; deviations = the def+2 methods in calllog.go, hook/cmd.go's `W: cmd.OutOrStdout()`, github.go:238 runCIAggregate (only site with a `*Tracker` param), and two non-production test constructions. The two structural deviations (hook, runCIAggregate) are the discriminating signal — easy to miss without per-site enclosing context.

## Design
Standard harness A/B, one HEAD `sf` binary pinned via SF_BIN, same BASE_SHA=257718b, model sonnet.
- **sf arm**: `Bash(sf:*)` + Read/Grep/Glob, sf preamble (now names `sf refs`), `SF_HOOK_MODE=nudge`.
- **plain arm**: Read/Grep/Glob only, plain preamble (sf forbidden), hook off.
The task text is identical and names no tool; each arm solves it with its own kit. Fresh worktree + native session id per rep, isolated `SOFIA_LOG_DIR` per arm.

### Exact commands
```
SF_BIN=/home/l0gic/www/sofia-ctx/sofia/bin/sf SOFIA_LOG_DIR=~/refs-pilot/sf \
  REPS=1 ARMS=sf    TASKS=t5_refs bash run.sh
SF_BIN=/home/l0gic/www/sofia-ctx/sofia/bin/sf SOFIA_LOG_DIR=~/refs-pilot/plain \
  REPS=1 ARMS=plain TASKS=t5_refs bash run.sh
```
Turns + cost from each `runs/<arm>/t5_refs/1.json` (`.num_turns`, `.total_cost_usd`, `.usage`); sf-tool calls from `~/refs-pilot/sf/calls.jsonl`; quality via public `judge.sh` against the rubric.

## Criteria (pre-registered)
- **primary (turn-collapse)**: num_turns(sf) < num_turns(plain), materially (target ≥ ~30% fewer).
- **mechanism**: sf arm actually issues an `sf refs Counter` call (else it's a discovery miss, not a mechanism test — noted, not scored as a win).
- **quality carry**: judge(sf) ≥ judge(plain) − small margin, AND sf finds ≥ as many of deviations (b)+(c) as plain. A quality WIN (sf catches a deviation plain misses) is a bonus signal.
- **cost**: report; not gating (turn-collapse can lower cost via a smaller context integral even when the one refs call ≈ grep in tokens).
- **carry**: exit==0 both arms.

## Honest-null clause
If the **plain arm also solves it in ~1–2 turns** — e.g. a single `grep -rn Counter` plus reasoning, without a real fan of file reads — then there is no turn fan to collapse and the verdict is **NULL** ("the task doesn't force the per-site reads refs saves"), NOT a loss. If the **sf arm never calls `sf refs`** (uses grep/code instead), the run tests tool discovery, not the refs mechanism — reported as an inconclusive/discovery result, and I fix the preamble rather than the tool. The task will NOT be tuned to manufacture a fan.

## Stop-loss
- Auth dead (smoke rc≠0) → stop, no paid run. (Gate already PASSED 2026-07-11: bare `claude -p` → "ok", rc=0.)
- n=1 each arm first. Escalate to n=3/arm ONLY if rep-1 shows a real turn gap (sf uses refs, plain fans out) worth confirming. A clear NULL, a discovery miss, or a quality regression → stop; don't burn.
- One corrected re-run only for a setup bug (SF_BIN not HEAD / task file missing / auth blip). Budget ~$1–2; cap n=3/arm.

---

## Results (2026-07-11, sonnet, SF_BIN=daily 0.19.0, BASE_SHA=257718b, n=3/arm)

Auth smoke rc=0 (gate passed). One plain rep-1 was killed by a 600s timeout collision (my wrapper == RUN_TIMEOUT); re-run at RUN_TIMEOUT=900 (the one allowed setup-bug re-run). All final runs exit==0, is_error=false.

| metric (median n=3) | sf | plain | Δ |
| --- | ---: | ---: | ---: |
| **turns** (`num_turns`) | **18**  [13, 23, 18] | **42**  [42, 26, 46] | **−57%** |
| cost $ | 0.557  [.557,.950,.529] | 0.971  [.971,1.019,.832] | −43% |
| cache_read (context integral) | 587K  [587,834,438] | 1226K  [1226,1530,782] | −52% |
| output tokens | 10401 | 15115 | −31% |
| judge score | 48  [48,42,48] | 38  [38,22,38] | sf +10 |

### Verdict — CONFIRMED (positive), the program's first clean win
- **primary (turn-collapse ≥30% fewer): MET.** sf median 18 turns vs plain 42 → **−57%**. reps 1 & 3 show the big gap (13v42, 18v46); rep-2 was the near-parity outlier (23v26) — the median absorbs it. The effect is real but **high-variance** (both arms' turn counts swing per rep), so it lives at the median, not every rep.
- **mechanism: MET.** The sf arm actually issued `sf refs Counter` (rep-1: 3 refs calls). Note it did NOT collapse to one call — it used refs to locate + a `sf code` fan (10 calls) to read enclosing bodies, so 13–23 sf calls, not 1. refs cuts turns **vs plain's grep-fan**, it doesn't make this a one-call task.
- **quality carry: MET (and a small win).** sf 48 > plain 38 median. But **both fail the rubric (pass=false all 6 reps)** — the task (find every `calllog.Counter` deviation across 32 refs) is hard; sf typically caught the `hook cmd.OutOrStdout()` deviation + both test constructions but missed `runCIAggregate:238` (the `*Tracker`-param site); plain missed more. So refs makes the map **cheaper and slightly more complete**, not correct.
- **cost / context integral: sf −43% / −52%** — the real story. Plain's 42-turn grep-then-read fan re-reads its whole context each turn (cache_read balloons to ~1.2M); sf's refs-anchored 18 turns keep the integral to ~590K. This is exactly what the `sf refs` footer (bytes of the one call) can't see, and why it **undersold** refs.

### Honest caveats
- n=3, high variance; the win is a median, not a guarantee per run. A quality task both arms *pass* would test the quality axis better (here both fail, so the +10 is "less wrong," not "right").
- Spend: sf $2.04 + plain $2.82 + judge ≈ **$5.0** (within the "cap n=3/arm", over the optimistic "$1–2" — this task is token-heavy at ~0.6–1.5M cache_read/run).

### Consequence
`refs.md` overstated the footer's pessimism: the footer is honest about the single call's bytes but structurally blind to the downstream read-fan refs removes. Update refs.md to cite this measured turn/cost collapse (−57% turns, −43% $ median vs a grep-fan baseline) instead of "unmeasured". No code change — refs already ships; this validates it.

---

## Follow-up (2026-07-11): can guidance widen the win?

**Pre-registered BEFORE the re-run.** The n=3 diagnosis (`calls.jsonl` of a captured sf rep) showed the sf arm **over-fetched**: 2 `sf refs Counter` calls returned everything (all deviations are visible in the enclosing signature + hit text; the header gives the def/use totals), yet the agent then made ~8 redundant calls — 6 `sf code <file>` re-reads of hit files already labelled by refs, plus 2 `grep` calls to re-count constructions refs had already totalled. It fetched no function *bodies*. So `--bodies` is the wrong lever; the loss is **trust in the refs output**, addressable by guidance.

### Change under test (guidance only — no binary change)
Shipped guidance sharpened to state refs' self-sufficiency (`skills/sf-context/SKILL.md`, `internal/common/initcmd/agents_block.md`) and mirrored into the harness sf preamble (`run.sh`): *"After `sf refs`, that output IS the usage map — don't re-open each hit's file or grep to re-count; only `sf code <file> <func>` a body you actually need."*

### Hypothesis / criteria
Guidance pulls the sf arm's turns from the 18 median toward the refs-only floor (~3–6), widening the win vs the unchanged plain baseline (42). **win**: median sf turns(guided) < 18 materially (target ≤ ~10) with judge score not regressing (≥ 45). **null**: turns unchanged (~18) → the over-fetch is not guidance-addressable (agents don't obey the completeness note) — reported honestly, consistent with the program's finding that preamble nudges are fragile.

### Design / stop-loss
Only the **sf arm** re-runs (guidance can't touch the sf-less plain arm); compare to plain's frozen 42 and old-sf's 18. n=3, sonnet, same task/BASE_SHA. Budget ~$1.5. A clear null at n=3 → stop (don't tune the wording to win).

### Results (2026-07-11, sf arm reps 5–7, guidance in the preamble)

| sf arm | turns (median) | cost (median) | judge (median) |
| --- | ---: | ---: | ---: |
| old (no completeness note) | 18  [13,23,18] | $0.557 | 48 |
| **guided** | **20**  [20,15,23] | **$0.844** | 38  [38,38,48] |
| plain baseline (frozen) | 42 | $0.971 | 38 |

Tool-call mix across the 3 guided reps: **50 `code` + 8 `refs` + 2 `grep`** ≈ 16.7 `code`/rep — the over-fetch did **not** drop (old diagnostic rep: ~8 `code` + 2 `refs` + 2 `grep`; if anything the structure re-reads went up).

### Verdict — NULL for the guidance lever
Guidance telling the agent "refs output IS the usage map, don't re-open" did **not** widen the win: guided turns median 20 ≈ old 18 (indistinguishable, and not even directionally better), cost slightly higher, judge within the judge's own ±20 noise (old sf reps re-judged this run to 52–78 for the same answers — the score axis is too noisy to read). The trace confirms the mechanism of the null: **the agent kept re-opening the hit files with `sf code` (structure reads refs had already given as enclosing signatures) regardless of the completeness note.** The `--bodies` lever was already ruled out (the agent never fetched bodies — it re-fetched *structures*).

**Consequence / what this means for "developing the refs win":**
- The refs turn-collapse vs plain (**~18–20 vs 42 turns**, −55%) is real and robust — that's the confirmed product win, and it stands.
- It is **bounded by agent behaviour, not by refs' capability**: the agent over-fetches (re-scans files refs already covered) and neither guidance nor a `--bodies`/more-context feature addresses that — refs is already self-sufficient for the task; the agent just doesn't trust it. Consistent with the program's standing finding (H1/H4/H-A) that preamble nudges don't reliably move tool-use.
- **Action taken:** the guidance additions (SKILL.md, agents_block.md, harness preamble) were **reverted** — an unearned completeness note that taxes every session's context for no measured benefit is exactly the over-nudge the program avoids. refs.md keeps the (earned) turn-collapse numbers. Net: refs is validated and its win documented; there is no cheap way to make it bigger, and we don't pretend otherwise.

Total follow-up spend ≈ $2.9 (diagnostic rep $0.54 + 3 guided reps + judge).
