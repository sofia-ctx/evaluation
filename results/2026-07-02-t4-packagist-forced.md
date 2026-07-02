# t4_packagist A/B: does `sf` earn its tokens once it's actually used?

A follow-up to the **invalid** [`t1_calllog` run](./2026-07-02-t1-calllog.md).
That run tried to measure `sf` vs `plain` on a multi-file comprehension task,
but `sf` was **never invoked** in any of the three `sf`-arm reps: the task was
grep-shaped, and the `sf hook pre` PreToolUse hook only gates a *full*
`Read`/`cat` of a big source file — it never touches `Grep` (deliberate, for
parity with `rg`). A grep-shaped task gives the hook zero chances to fire, so
the system-prompt "prefer `sf`" nudge alone lost to the zero-friction native
`Grep`/`Read` tools. You can't attribute a cost delta to a tool that was never
used, so that run measured nothing about `sf`.

This run fixes the **mechanism gap** and re-measures. The fix has three parts,
all aimed at the same thing — making `sf` actually get exercised so the arms
differ by tool *usage*, not just availability:

1. **A task the hook can engage.** `t4_packagist` is single-file comprehension:
   understand the retry/backoff/version-selection logic of one ~12KB file
   (`internal/common/packagist/packagist.go`) well enough to answer four
   non-trivial questions about its actual behaviour. A full-file `Read` is the
   obvious first move — exactly the call the hook gates — and the questions are
   about internal control flow (not "find all mentions of X"), so `Grep` and
   chunked `offset`/`limit` reads don't obviously suffice.
2. **`SOFIA_HOOK_MODE=strict` on the `sf` arm** (new `SF_HOOK_MODE` knob in
   `run.sh`; the `plain` arm still forces `off`). In `strict` the hook *always*
   denies a qualifying full `Read`/`cat` of a big source file — no
   second-chance pass-through like `nudge` gives.
3. **A structural-first line added to the `sf`-arm preamble** ("to understand a
   source file's logic, go structural-first: `sf code <file>` for the map, then
   `sf code <file> <Symbol>` for each body you need, before a full Read") —
   consistent with the project's own `sf-context` skill ("структурный read →
   узкий поиск → точечное тело").

**Commands:**

```
# free mechanical proof first (Step 2 below), then:
REPS=1  ARMS=sf    TASKS=t4_packagist SF_HOOK_MODE=strict bash run.sh   # pilot = sf rep 1
REP_START=2 REPS=3 ARMS=sf    TASKS=t4_packagist SF_HOOK_MODE=strict bash run.sh   # sf reps 2-3
REPS=3  ARMS=plain TASKS=t4_packagist bash run.sh                        # plain reps 1-3
bash judge.sh
bash aggregate.sh
```

**Date:** 2026-07-02. **Model:** sonnet (both arms). **REPS:** 3.
**BASE_SHA:** `257718bfc4d6fee74322c24f4c90e8db02c99efa` (sofia-ctx/sofia) —
confirmed an ancestor of the `../sofia` clone's HEAD (`35c34ee`) at run time.
Run window 10:27–10:31 UTC.

## TL;DR

1. **`sf` was genuinely exercised this time.** 27 `sf` invocations across the
   three `sf`-arm reps (rep 1: 9× `sf code`; rep 2: 8× `sf code` + 1× `sf grep`;
   rep 3: 9× `sf code`), and **zero** full `Read` calls in any `sf` rep. The
   `plain` arm did the opposite: exactly one full `Read` of `packagist.go` per
   rep, zero `sf`. The arms now differ by tool *usage* — the thing that failed
   in `t1_calllog`. Cross-checked against `calls.jsonl` and every session
   transcript (verification section below).
2. **And it still lost — but this time it's a real loss.** On every metric the
   `sf` arm is *more* expensive: **+8.6% cost, +93.6% billed tokens, +134%
   `cache_read`, +18% output, +33% turns, +29% wall.** Unlike `t1_calllog`
   (where "`sf` lost" was meaningless because `sf` was unused), this is an
   honest measurement: forced onto the structural-first workflow, `sf` cost
   roughly **2× the tokens** of a single full `Read` and did not pay off.
3. **Why:** the task needs most of one not-actually-huge file (8+ of its ~20
   functions). "Structure + 8 separate symbol bodies" pulls roughly the whole
   file's interesting content *anyway*, but across more tool round-trips (more
   turns → more cache-creation/read cycles) and with the structural map on top.
   A single `Read` of a 12KB (~3.1k-token) file is just cheaper than drilling it
   symbol-by-symbol. This matches `sf`'s own documented boundary: drill-down
   pays off on comprehension across **many / unfamiliar** files, not a single
   file you end up needing in full.
4. **Quality is equal.** All 6 runs passed the judge (plain 100/98/98, sf
   98/98/98); no files were modified in any run (empty diffs), as the task
   required.

## Step 2 — mechanical proof the hook engages (free, before any `claude -p`)

Before spending, a throwaway Go program called `hook.Decide` directly on the
exact target file, mode `strict`, `minBytes=4096` (the real defaults):

```
strict: full Read of target              -> action=deny     path=/tmp/sf-base-wt/internal/common/packagist/packagist.go bytes=12411
nudge:  full Read of target              -> action=deny     path=/tmp/sf-base-wt/internal/common/packagist/packagist.go bytes=12411
strict: Read w/ offset+limit (chunked)   -> action=(allow)  path=  bytes=0
strict: Grep (never gated)               -> action=(allow)  path=  bytes=0
off:    full Read of target              -> action=(allow)  path=  bytes=0
```

So a full `Read` of `packagist.go` (12411 B > 4096) under `strict`
**is denied** — and, note lines 3–4, a chunked `offset`/`limit` read and a
`Grep` both pass through untouched. That pass-through is *exactly* why
`t1_calllog`'s grep-shaped task never engaged the hook; the whole point of
choosing a full-file-comprehension task is to make the gated full `Read` the
natural move. Also confirmed for free: `sf code packagist.go` produces a clean
structural summary and `sf code packagist.go <Symbol>` returns single bodies —
the fallback path the agent is pushed onto actually works.

## Step 3 — pilot (1 rep, `sf` arm, strict)

`sf` rep 1: `rc=0`, cost \$0.2075, 9× `sf code` (1 structural read of the file,
then 8 `sf code <file> <Symbol>` bodies chained in one Bash call:
`fetchPackagistLatest`, `fetchWithRetry`, `backoff`, `doP2Request`,
`retryAfter`, `retryAfterError.Error/.Unwrap`, `Collect`), **zero full Reads**,
empty diff, judge pass (98). This is the thing that failed in `t1_calllog` — so
the pilot confirmed the mechanism before the remaining 5 sessions were run, and
the pilot's data point is reused as `sf` rep 1 (via the new `REP_START` knob).

## Results (medians, n=3, passing runs only — all 6 passed)

| task | metric | `sf` | `plain` | Δ (`sf` vs `plain`) |
|---|---|---:|---:|---:|
| T4 packagist | cost $ | 0.2056 | 0.1894 | **+8.6%** |
| | tokens (`billed_in`) | 155,170 | 80,138 | **+93.6%** |
| | `cache_read` | 135,094 | 57,641 | +134.4% |
| | output tokens | 3,575 | 3,028 | +18.1% |
| | turns | 4 | 3 | +33% |
| | wall, s | 54.5 | 42.3 | +28.9% |
| | quality (judge) | 3/3 pass, 98/98/98 | 3/3 pass, 100/98/98 | = |

### Per-rep spread (so the n=3 noise stays visible)

| arm | rep | cost $ | billed_in | cache_read | out | turns | wall (s) | judge |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| sf | 1 | 0.2075 | 155,170 | 135,089 | 3,654 | 4 | 58.7 | pass, 98 |
| sf | 2 | 0.2055 | 233,965 | 215,152 | 2,430 | 6 | 49.6 | pass, 98 |
| sf | 3 | 0.2056 | 155,055 | 135,094 | 3,575 | 4 | 54.5 | pass, 98 |
| plain | 1 | 0.2119 | 80,138 | 57,641 | 4,532 | 3 | 63.6 | pass, 100 |
| plain | 2 | 0.1894 | 80,140 | 57,641 | 3,028 | 3 | 42.3 | pass, 98 |
| plain | 3 | 0.1694 | 80,137 | 57,641 | 1,697 | 3 | 33.0 | pass, 98 |

Medians (cross-checked by hand against `runs/_records.jsonl`, not just
`aggregate.sh`'s printed CSV): `sf` cost sorts to
`[0.2055, 0.2056, 0.2075]` → median `0.2056`; `plain` to
`[0.1694, 0.1894, 0.2119]` → median `0.1894`. `sf` `billed_in` sorts to
`[155055, 155170, 233965]` → median `155170`; `plain` to
`[80137, 80138, 80140]` → median `80138`. All match `aggregate.sh` exactly. All
6 runs had `rc=0` and an empty `git diff`.

Two things stand out in the spread:

- **`plain` is almost perfectly stable in token volume**: `billed_in`
  80137/80138/80140 and `cache_read` an *identical* 57641 across all three reps.
  The single-full-`Read` path (read `CONTRIBUTING.md`, then read `packagist.go`
  in full, 3 turns) processes the same token volume every time; its only real
  variance is output tokens (1.7k–4.5k), which drives the dollar/wall spread.
- **`sf` is higher and noisier**: rep 2 is a 234k-token, 6-turn outlier (the rep
  that also did 2 `Grep` + 1 `sf grep` on top of the 8 bodies). Even its two
  tighter reps (~155k) are ~2× `plain`.

## `sf`-tool-usage verification: this time `sf` *was* exercised

The failure mode of `t1_calllog` was that `sf` went unused, so this is verified
the same rigorous way — `calls.jsonl` cross-checked against every transcript:

- **Calllog cross-check.** `sf`'s shared log
  (`~/.local/state/sofia/calls.jsonl`) tags each invocation with the worktree
  basename. `sf`-arm tags `sf-t4_packagist-{1,2,3}` carry **27** entries: rep 1
  = 9× `code`; rep 2 = 8× `code` + 1× `grep`; rep 3 = 9× `code`. Zero entries
  tagged to any `plain` worktree (the `plain` arm has no `Bash(sf:*)` allowance
  and is told not to use `sf`).
- **Transcript cross-check.** Each session transcript (located via `session_id`
  in `runs/<arm>/t4_packagist/*.json`) was read and every `tool_use` enumerated:
  - `sf` rep 1: 3 `Bash` (all `sf code …`), **0 `Read`**.
  - `sf` rep 2: 3 `Bash` (`sf code …`), 2 `Grep`, **0 `Read`**.
  - `sf` rep 3: 3 `Bash` (all `sf code …`), **0 `Read`**.
  - `plain` reps 1–3: exactly 2 `Read` each — `CONTRIBUTING.md` then a full
    `Read` of `packagist.go` (`offset=0, limit=0`) — **0 `Bash`, 0 `sf`**.
  Every `sf` rep followed the intended structural-first workflow (`sf code`
  structure → `sf code <file> <Symbol>` bodies); every `plain` rep took the
  single-full-read path.
- **The strict hook was an armed backstop, not the trigger.** No `hook.nudge`
  (deny) entries were logged for any `sf` rep — the agent went straight to
  `sf code` on the preamble's instruction and never *attempted* a full `Read`,
  so `strict`'s deny path had nothing to deny. Step 2 proves it *would* have
  denied a full `Read`; in practice the preamble was enough that the hook didn't
  need to. Either way the outcome that matters — `sf` actually used — held in
  3/3 reps.

Net: this run really does compare "navigate one file via `sf code` + symbol
bodies" against "read the file once" — the comparison `t1_calllog` failed to
make.

## Verdict

**No — `sf` did not earn its tokens here, and this time that's a real result.**
Genuinely exercised (27 calls, structural-first, zero full Reads), `sf` came out
worse on every metric: +8.6% dollars, +93.6% tokens, +134% `cache_read`, +33%
turns, +29% wall. The dollar gap is smaller than the token gap because most of
`sf`'s extra volume lands in cheap `cache_read` — the same volume→cache shift
`micro.md` saw on `t1_deal` — but here it wasn't enough to flip dollars: `sf`
was more expensive on cost too. The cause is structural: the task requires
understanding most of a single 12KB file, and "structure + eight symbol bodies"
reconstructs roughly the whole file across more round-trips than reading it
once. This is consistent with `sf`'s own `sf-context` skill, which says the
structural drill-down pays off on comprehension across *many / unfamiliar*
files and on larger models — not on a single file you end up needing in full,
where a plain `Read` is cheaper. `t4_packagist` was designed to *force* `sf`
usage (and it did); it turns out that forcing `sf` onto a task at the wrong end
of that boundary makes it lose honestly, rather than lose vacuously as in
`t1_calllog`.

This is a real, narrow data point (N=3, one file, one model, one operator), not
a general verdict on `sf`. It says: *when* `sf` gets used, it has to be used on
the right shape of task; strong-arming it onto single-file comprehension via a
`strict` hook costs tokens without buying quality. See
[`micro.md`](https://github.com/sofia-ctx/sofia/blob/main/docs/measurements/evaluation/micro.md)
and
[`macro.md`](https://github.com/sofia-ctx/sofia/blob/main/docs/measurements/evaluation/macro.md)
in `sofia-ctx/sofia` for the larger private-codebase study, including the
many-file comprehension tasks where `sf` *did* show a dollar win.

## Caveats

- N=3/cell, one task, one file, one model (sonnet), one operator — a trend on a
  demo task, not a law about `sf`. Consistent with `README.md`'s stated caveats.
- **The a-priori "favors `sf`" guess was wrong.** The task was picked so the
  hook could engage on a big source file; the expectation that engaging it would
  also *help* did not survive contact with the measurement. Reported as-is.
- **A behavioural asymmetry that works *against* `sf`, not for it:** the `plain`
  arm read `CONTRIBUTING.md` (3.8KB, ~960 tok) every rep as instructed; the `sf`
  arm skipped it in all 3 reps. That extra file *inflates* `plain`'s tokens, so
  `sf`'s real token penalty is if anything slightly *understated* here, not
  flattered.
- `strict` mode made the full `Read` a hard denial in principle, but in these
  sessions the strengthened preamble alone was enough to route the agent to
  `sf code`; the hook's deny path was never actually hit. So this measures
  "preamble + armed strict hook," not "strict-hook-deny in isolation."
- Cost is noisy from cache warm-up between sequential runs (see `README.md` and
  `micro.md`); `billed_in` is the more stable signal and it agrees strongly with
  the dollar direction (`plain`'s `billed_in` is near-constant; `sf`'s is ~2×).
- Harness state for reproducibility: `sf` arm run with `SF_HOOK_MODE=strict`;
  `plain` arm `SOFIA_HOOK_MODE=off` (unchanged); `sf`-arm preamble carries the
  new structural-first line; the pilot was reused as `sf` rep 1 via `REP_START`.
