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

---

## Model axis (2026-07-11): opus vs the sonnet baseline

**Pre-registered BEFORE the opus run.** First point on the `MODEL` re-calibration axis (see the benchmark section in README): the over-fetch is a model/harness property, not an `sf` property — so re-run the *same* frozen probe under a stronger model.

### Question
Does opus over-fetch less than sonnet? Sonnet's sf arm, given a self-sufficient `sf refs` answer, still fanned out to ~5–10 `sf code` re-reads (median 18 turns). A stronger model might trust the structured answer more (fewer re-reads → the refs win widens), or over-fetch is robust across tiers (same behaviour → the win is model-agnostic). Either result is informative.

### Design
Same task `t5_refs`, same BASE_SHA=257718b, same preambles/arms — only `MODEL=opus`. Compare to the sonnet n=3 baseline (sf turns 18 / plain 42; sf code-call fan 5–10). Primary read = the sf arm's **turns + `sf code` re-read count** (the over-fetch signal) from `calls.jsonl`; plain arm for the turn-collapse delta on opus; cost/judge reported.

### Stop-loss (opus is ~5× sonnet's per-token price)
n=1 each arm FIRST; inspect the sf trace (does opus fan out after `sf refs`?). Escalate to n=3 ONLY if the n=1 direction is worth confirming AND the cost is acceptable — flag spend before escalating. No claim beyond "trace + direction" at n=1.

### Results (2026-07-11, MODEL=opus, n=3/arm, reps 10–12; sonnet baseline = the n=3 above)

| median n=3 | opus sf | opus plain | (sonnet sf) | (sonnet plain) |
| --- | ---: | ---: | ---: | ---: |
| turns | **11**  [11,11,14] | **13**  [13,12,13] | 18 | 42 |
| cost $ | 0.550 | 0.643 | 0.557 | 0.971 |
| cache_read (integral) | 207K | **188K** | 587K | 1226K |
| judge | 70  [90,70,38] | 38  [38,38,*] | 48 | 38 |

*judge is badly noisy here (opus sf rep10 scored 45 on the first pass, 90 on a re-judge of the same answer — ±45; one plain rep hit the judge's parse-fail fallback). Treat quality as "sf ≈ or somewhat better, both imperfect" and rest the verdict on the judge-independent metrics.* opus sf over-fetch across the 3 reps: 9 refs + 14 code + 3 grep ≈ 4.7 code re-reads/rep (sonnet: 6–16/rep).

### Verdict — the refs win is MODEL-DEPENDENT and shrinks with model strength
The turn-collapse that was **−57%** on sonnet (sf 18 vs plain 42) is **~−15% and near-parity on opus** (sf 11 vs plain 13), and the context integral is even slightly *higher* for opus-sf than opus-plain (207K vs 188K). Two compounding reasons, both confirming the benchmark's thesis:
1. **opus's plain (grep) baseline is already efficient** — 13 turns / 188K, versus sonnet-plain's 42 turns / 1.23M. A strong model doesn't fan out with bare grep, so `sf refs` has almost no read-fan left to collapse.
2. **opus over-fetches less in the sf arm too** — ~4.7 `sf code` re-reads/rep vs sonnet's 6–16; it trusts `sf refs` more. (This half is the direction the "develop the win" guidance null predicted couldn't be forced — a stronger model just does it.)

**Strategic reading (first point on the MODEL axis):** `sf`'s value is **inversely proportional to model capability** on this probe. It buys the most for **weaker/cheaper agents** (sonnet — and by extension haiku), whose plain baseline over-fetches; for the **strongest** models (opus) the plain baseline is already lean, so `sf`'s structural tools are roughly break-even. Honest consequence for positioning: pitch `sf` as a token-economy lever for high-volume work on cheaper models, **not** as a universal win — on a top model the agent doesn't need the crutch. (Cost footnote: opus was *not* ~5× dearer per run — $0.55–0.64 vs sonnet's $0.56–0.97 — because its lower turn count offsets the higher per-token price.)

Caveat: n=3, one task, one strong model. The direction (win shrinks as the model strengthens) is clean and mechanistically sound; the exact opus break-even point isn't pinned. Next axis point that would sharpen it: **haiku** (predict the *largest* refs win, since the weakest baseline fans out most). opus spend ≈ $3.7.

### haiku — the weak end of the axis (2026-07-11)

**Pre-registered before the run.** Completes the weak→strong curve haiku → sonnet → opus. **Prediction:** haiku (weakest) shows the **largest** refs turn-collapse — a weak model's plain-grep baseline should fan out the most (sonnet-plain already hit 42 turns; haiku-plain should be ≥ that), while `sf refs` gives it the same one-call map, so sf−plain gap widens. Confounder to watch: a weak model may also **mis-use** `sf refs`/over-fetch *more* in the sf arm, or fail the task (low judge) — if the sf arm doesn't hold quality, "cheaper" is hollow. Same task/BASE_SHA/arms, `MODEL=haiku`, n=3 (reps 20–22), haiku ≈ 1/12 sonnet's price so full n=3 is ~$1.

#### Results (MODEL=haiku, n=3, reps 20–22)

| median n=3 | haiku sf | haiku plain |
| --- | ---: | ---: |
| turns | **30**  [28,30,30] | **15**  [15,15,21] |
| cost $ | 0.190 | 0.155 |
| cache_read (integral) | 1027K  [1027,1225,762] | 601K  [601,262,757] |
| judge | 38  [38,52,38] | 30  [45,22,30] |

**Prediction WRONG — and the miss is the finding.** haiku's sf arm is **2× worse** than its plain arm (30 vs 15 turns, 1027K vs 601K integral), for a marginal quality bump (38 vs 30, both failing). The confounder won: a weak model **can't wield the richer toolset** — the trace shows haiku flailing (mixing native Reads and sf calls, fumbling absolute vs `./` paths, tripping the hook nudge), making ~30 turns but only ~4 productive sf calls/rep. With plain grep it's *constrained* to a simpler 15-turn path. **The rich sf toolset HURTS a model too weak to drive it** (more ways to go wrong), so `sf` is a net loss on haiku.

## Model-axis synthesis (t5_refs, n=3 each) — an inverted-U, not "inverse to strength"

| model | sf turns | plain turns | sf vs plain | verdict |
| --- | ---: | ---: | --- | --- |
| **haiku** (weak) | 30 | 15 | **+100% (worse)** | sf LOSES — too weak to use the tools |
| **sonnet** (mid) | 18 | 42 | **−57%** | sf WINS big — the sweet spot |
| **opus** (strong) | 11 | 13 | ~−15% (parity) | sf ≈ break-even — doesn't need it |

The opus point alone read as "sf value is inversely proportional to model strength." Haiku **corrects** that to a **Goldilocks / inverted-U**: `sf`'s value peaks in the *middle*. Both extremes lose it — the **strong** model's plain baseline is already efficient (nothing to collapse), the **weak** model can't drive the richer toolset (it flails and over-fetches *more* with sf than without). `sf` pays off for the band of models **capable enough to use it correctly, yet weak enough that their plain baseline over-fetches** — sonnet-class here.

**Positioning consequence (revised):** not "sf for cheap models" — it's **"sf for the mid-tier workhorse"** (sonnet-class), the model you actually run high-volume coding on. On a frontier model it's roughly free; on the cheapest/weakest it can *backfire*, so a plugin that force-nudges a weak agent toward structural tools may cost more than it saves. Worth a per-deployment check (the `MODEL` axis is exactly that instrument), not a blanket "always on".

Caveats: one task, n=3, judge noisy (±20–45; rest the verdict on turns/integral, which are clean and monotone-per-model). The inverted-U is three points — the *shape* is robust (loss / big-win / parity is a large, mechanistically-explained spread), the exact peak/breakeven isn't pinned. Total model-axis spend: opus ≈ $3.7 + haiku ≈ $1.1 (haiku cheap despite more turns).
