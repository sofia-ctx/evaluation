# dir-brief / dir-passthrough pilot (§2.1.3) — pre-registration + results

**Pre-registered 2026-07-11 BEFORE any measurement.** Do not edit the pre-registration section after the first measurement; results are appended below.

## Question (parked in extra-plan §2.1.3)
`sf code <dir>` emits a per-file map. Files under the raw-passthrough threshold (8K, `SOFIA_CODE_RAW_BELOW`) are emitted **verbatim**, not summarised. The note in §2.1.3 was that this bloats directory maps (e.g. `pack/` ≈ 15K tokens of raw file bytes), and asked: should `--brief` be the **default** for directory mode?

## Hypothesis
If per-file raw-passthrough dominates a directory map's tokens, then `--brief` — which drops member/field/tag detail from **summarised** files — cannot shrink the passthrough'd files, so brief-by-default would **not** meaningfully reduce dir-map size. The real lever would be the dir-mode passthrough policy, not brief.

## Design (free — pure token accounting, no paid agent run)
Measure the map size sf actually emits for representative package dirs, raw-default vs `--brief`, with **dedup disabled** (`SOFIA_DEDUP_WINDOW=0`, so repeated measurement calls aren't collapsed to the 19-token stub — a contamination caught on the first pass). Footer `# sf ≈N tok` is the emitted size. A dir whose files are all < 8K reports `raw passthrough` and is the clean control: brief must change nothing there.

## Criteria (pre-registered)
- **confirm** (brief is the wrong lever): on all-small dirs, brief size == raw-default size (0 saving); on mixed dirs, brief saves < ~5% of the total map.
- **refute** (brief-by-default is worth it): brief saves >= ~20% on typical dirs → make it the dir-mode default.

## Honest-null / no-paid-run clause
The downstream question ("does a smaller dir map lower the agent's context integral") only matters if brief actually produces a smaller map. If the free measurement shows brief barely moves the map (confirm case), a paid A/B would only re-confirm "no downstream win because the map is the same" — so it is **deliberately skipped** (airtight inference, same discipline as the t4 OFF arm). The finding is a **reframe**, not a win or loss.

## Stop-loss
Free measurement only unless it refutes the hypothesis (brief saves >= 20%); only then author a paid brief-default A/B. No paid run otherwise.

---

## Results (2026-07-11, daily sf 0.19.0, `SOFIA_DEDUP_WINDOW=0`)

Footer `# sf ≈N tok` = map sf emitted; `raw` = the same files as raw bytes→tokens.

| dir | files (<8K) | raw-default sf | --brief sf | brief saving |
| --- | --- | ---: | ---: | ---: |
| internal/common/changed | all small | 5215 (raw passthrough) | 5215 | **0%** |
| internal/common/worktrees | all small | 2958 (raw passthrough) | 2958 | **0%** |
| internal/common/code | 2 (1) | 19678 | 19225 | 2.3% |
| internal/plugin | 12 (5) | 21274 | 21146 | 0.6% |

### Verdict — CONFIRMED (brief is the wrong lever), no paid run
- On all-small dirs (`changed`, `worktrees`) the whole map is raw-passthrough, so `--brief` changes **nothing** — 0 saving, exactly as predicted.
- On mixed dirs (`code`, `plugin`) brief trims only the summarised large files; the passthrough'd small files dominate what's left, so brief saves **0.6–2.3%** — far below the 20% refute bar.
- Therefore **brief-by-default for directories would not reduce dir-map bloat.** The lever that would is the **dir-mode passthrough policy** (e.g. summarise small files instead of passing them through when mapping a whole dir, or a lower/zero passthrough threshold in dir mode) — a deliberate design decision with its own quality trade-off (raw small files are often exactly what a reader wants), NOT a free default flip.
- Paid downstream A/B on `--brief` **skipped**: the map is ~unchanged by brief, so there is no smaller-map to lower an agent's context integral. §2.1.3 resolves to "reframe": the open design question is a **dir-mode passthrough threshold**, not `--brief`.

**UPDATE (same day):** that "real lever" — force-summarising small files in dir maps — was then A/B'd directly (`2026-07-11-dirmap-passthrough-ab.md`) and **REFUTED**: it's cost-neutral and *worse* on turns/integral (the agent re-fetches the bodies anyway). So neither `--brief` nor a dir-mode passthrough threshold helps; the current raw-passthrough default is right. §2.1.3 is closed — no change to make.
