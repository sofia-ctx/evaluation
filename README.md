# evaluation

A generic, self-contained A/B harness: does the [`sf`
CLI](https://github.com/sofia-ctx/sofia) actually earn its tokens for an AI
coding agent, or is it ceremony?

Two headless Claude Code sessions (`claude -p`), each in its own throwaway
`git worktree` of the same target repo at the same frozen commit, solve the
same task. One arm has `sf` available (its tools plus the `sf hook pre`
PreToolUse nudge and the `sf-context` skill); the other arm is Read/Grep/
Glob/Edit only, with the nudge switched off. The thing measured is **real
billed cost and tokens** from `claude -p --output-format json`
(`total_cost_usd`, `usage.*`) — not a heuristic, not a token estimate.

This repo is the reusable tool, not a single result. It ships demo
tasks that run against `sofia-ctx/sofia`'s own public Go code, so a stranger
can clone both repos and run a real (if tiny) A/B session end to end with no
private access. For the full methodology writeup and the original
(private-codebase) results this design was extracted from, see
[`docs/measurements/evaluation/micro.md`](https://github.com/sofia-ctx/sofia/blob/main/docs/measurements/evaluation/micro.md)
and
[`macro.md`](https://github.com/sofia-ctx/sofia/blob/main/docs/measurements/evaluation/macro.md)
in `sofia-ctx/sofia`.

## Design

- **2 arms:**
  - `sf` (treatment) — `sf` on `PATH`, told to prefer `sf code`/`sf grep`/
    `sf changed` over raw Read/Grep for source files, pointed at the target
    repo's own `CONTRIBUTING.md`. If you've run `make install` in your
    `sofia-ctx/sofia` clone, the global `sf hook pre` PreToolUse hook and
    the `sf-context` skill (registered in `~/.claude/settings.json` /
    `~/.claude/skills/`) are live for this arm too — that's what actually
    nudges the agent away from a full `Read`.
  - `plain` (control) — same repo, same task, standard tools only
    (Read/Grep/Glob/Edit); the preamble explicitly forbids `sf`;
    `SOFIA_HOOK_MODE=off` silences the nudge hook for this arm even though
    it's registered globally.
- **Tasks**, chosen at or across the break-even boundary (see
  [`tasks/`](./tasks)):
  - `t1_composer` — add one optional field to a Go struct in
    `internal/common/composer/show.go`, matching the file's existing style.
    Single file, moderate, needing only a small part of it — the shape
    `sf code <file> <Symbol>` is nominally built for. Run with
    `SF_HOOK_MODE=strict` so the arms differ by tool *usage*. A-priori guess
    was **Neutral**; **measured outcome — `sf` lost even on genuinely
    targeted point-read usage (+29.1% $, +44.6% tokens) — is in
    [`results/2026-07-02-t1-composer.md`](./results/2026-07-02-t1-composer.md).**
  - `t2_pricing` — add one map entry to a 68-line file
    (`internal/cc/pricing.go`), reusing an existing helper. A plain `Read` of
    the whole (small) file is already cheap; a structural-summary-then-body
    round trip is extra ceremony for no win. Run with the default `nudge`
    hook mode — the file is under the hook's size gate either way, so the
    hook is a non-factor by design. **Favors `plain`; measured outcome — `sf`
    lost (+9.0% $, +29.2% tokens); the hook never engaged (confirmed
    mechanically and live), but the agent reached for `sf code` anyway on
    2 of 3 reps — over-application, not hook-forcing — is in
    [`results/2026-07-02-t2-pricing.md`](./results/2026-07-02-t2-pricing.md).**
  - `t3_packagist` — comprehend the retry/backoff/version-selection logic of
    one ~12KB file (`internal/common/packagist/packagist.go`) well enough to
    answer four questions about its actual behaviour. A full-file `Read` is
    the obvious first move — exactly what `SF_HOOK_MODE=strict`'s PreToolUse
    hook denies — so the `sf` arm is routed onto `sf code`/`sf code <Symbol>`.
    This is the task that makes the treatment arm differ by tool *usage*, not
    just availability — a grep-shaped multi-file task doesn't work for this,
    since the hook never gates `Grep` at all, only a full `Read`/`cat`.
    **Designed to force real `sf` usage; measured outcome — `sf` lost on single-file
    comprehension — is in
    [`results/2026-07-02-t3-packagist-forced.md`](./results/2026-07-02-t3-packagist-forced.md).**
  - `t4_dispatch` — map the CLI's command-dispatch architecture across 13
    files in 12 packages: each file's declared types/struct fields and
    function signatures, plus the shared `main → calllog.Run → NewCommand →
    Run(Options)` spine. Answerable from `sf code <file>`'s one-shot
    structural summary (no bodies); the control arm reads the files in full.
    The many-file / need-only-the-shape regime `micro.md`'s `t1_deal` found
    favored `sf`. **Measured outcome — `sf` won on dollars (−18.6%) via the
    cache-read cost-shift, while using +56% more tokens — is in
    [`results/2026-07-02-t4-dispatch.md`](./results/2026-07-02-t4-dispatch.md).**
- **N repeats** per (arm × task) → median (an LLM is not deterministic).
- Isolation: every run is a fresh `git worktree --detach` off a frozen
  `BASE_SHA`, removed after. Model is fixed across both arms (`MODEL`,
  default `sonnet`) — otherwise the comparison isn't valid.
- Guarded by default: a tool allowlist, no arbitrary shell, edits land only
  in the disposable worktree. `PERM=bypass` switches to
  `--dangerously-skip-permissions` (faster, unguarded) — opt-in only.

## Requirements

- `claude` (Claude Code CLI) on `PATH`, logged in — this harness spends real
  money on real API calls.
- `git`, `jq`, `go` (for `go vet` on the diff), `bash`.
- A clone of [`sofia-ctx/sofia`](https://github.com/sofia-ctx/sofia) next to
  this repo (or point `TARGET_REPO` at it). For the `sf` arm to actually
  exercise the hook/skill nudge (not just the raw CLI), also run
  `make install` inside that clone.

## Run

```bash
git clone https://github.com/sofia-ctx/sofia.git ../sofia
git clone https://github.com/sofia-ctx/evaluation.git
cd evaluation

# smoke (cheapest possible unit): one task, one rep, one arm —
# proves worktree setup -> headless invocation -> judge -> aggregate works.
REPS=1 ARMS=sf TASKS=t2_pricing bash run.sh
bash judge.sh
bash aggregate.sh

# full study (real cost — a deliberate decision, not a default):
bash run.sh            # 2 arms x TASKS x REPS reps
bash judge.sh
bash aggregate.sh
```

Artifacts land in `runs/<arm>/<task>/<rep>.{json,diff,vet,meta,verdict}`
(gitignored — this repo ships the harness and the tasks, not run history).
`aggregate.sh` writes `runs/_records.jsonl` (one JSON record per run) and
prints a CSV summary to stdout.

### Knobs (env vars, all optional)

| var | default | meaning |
|---|---|---|
| `TARGET_REPO` | `../sofia` | path to the `sofia-ctx/sofia` checkout under test |
| `BASE_SHA` | `257718bfc4d6fee74322c24f4c90e8db02c99efa` | frozen commit worktrees are cut from (current `sofia-ctx/sofia` `main` HEAD at the time these tasks/rubrics were written — override only if you also re-verify the rubrics against the new commit) |
| `ARMS` | `sf plain` | space-separated arms to run |
| `TASKS` | `t1_composer t2_pricing` | space-separated task names (must have matching `tasks/<name>.task`/`.rubric`; `t1_composer`/`t3_packagist` need `SF_HOOK_MODE=strict` to reproduce their published results, `t4_dispatch` uses the default `nudge`, see below) |
| `REPS` | `5` | repeats per (arm × task) |
| `REP_START` | `1` | first rep index to run — resume a partial run (e.g. run rep 1 as a pilot, then `REP_START=2` to finish) without redoing completed reps |
| `MODEL` | `sonnet` | model, fixed across both arms |
| `RUN_TIMEOUT` | `600` | seconds before a single run is killed |
| `WTBASE` | `/tmp/ab-sofia-wt` | scratch dir for worktrees |
| `PERM` | `allowlist` | `allowlist` (guarded) or `bypass` (`--dangerously-skip-permissions`) |
| `SF_HOOK_MODE` | `nudge` | `SOFIA_HOOK_MODE` for the `sf` arm's `sf hook pre` nudge: `nudge` (deny first full read of a big source file, repeat passes — production default), `strict` (always deny full reads of big source files), `suggest` (advise only), `off`. The `plain` arm is always `off`. |
| `JUDGE_MODEL` | `sonnet` | model used by `judge.sh` |

## Metrics

- **Primary:** `cost_usd` (`total_cost_usd`) and `billed_in` (=
  `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`),
  medians taken **only over judge-passed runs** — a cheap run that fails the
  rubric isn't a win.
- Secondary: `cache_read`, `out` (output tokens), `num_turns`, `wall_ms`.
- Quality gate: `judge.sh` scores each completed run against that task's
  frozen `.rubric` with one more `claude -p` call (no tools) and writes
  `{pass, score, notes}`. A `.rubric` pins reference facts about the target
  repo's *actual current state* at `BASE_SHA` — not invented facts — so the
  judge has something concrete to check against.

## Adding a task

Drop a `tasks/<name>.task` (the prompt handed to the agent) and a matching
`tasks/<name>.rubric` (frozen reference facts + pass/fail criteria for the
judge). Verify every fact in the rubric against the real file at `BASE_SHA`
before writing it down — an invented fact makes the judge unreliable in
either direction.

## Caveats

- Small N per cell, one target codebase, one operator, one model (`sonnet`,
  fixed to control cost) — a trend on this harness's own demo tasks, not a
  general law about `sf`. See `micro.md`/`macro.md` in `sofia-ctx/sofia` for
  the larger, private-codebase study this design is drawn from, including
  where `sf` won and where it didn't.
- "Treatment" = `sf`-availability plus the hook/skill nudges together, not
  isolated from each other.
- Cost is noisy across runs: the system-prompt cache has a short TTL and
  bleeds between sequential runs, so an identical token volume can land at
  very different dollar cost depending on whether the cache was warm. Token
  volume (`billed_in`) is the more stable signal; dollars are a signal, not
  a verdict, especially at N=1–5.
- Runs are guarded by default (tool allowlist, disposable one-shot
  worktrees pinned to a frozen base commit); `PERM=bypass` trades that away
  for speed.
