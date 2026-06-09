# Local Polish Model Benchmark

## CONCLUSION (2026-06-07)

**Do NOT ship an LLM polish engine. Add a guarded adjacent-duplicate-word dedup rule to
`TranscriptDeterministicCleaner` instead.** The benchmark's real finding is not "which
model" — it is that **no local model has a safe operating point above deterministically-
expressible transforms.** The exhaustive sweep + unbiased panel proved both halves of that:

1. *The safe configs add nothing an LLM is needed for.* Decomposing every e2b/conservative
   (the winner) clean transform-by-transform (23 unique disfluent cells): **12/23 are
   byte-identical to a deterministic baseline of {live um/uh removal + adjacent-dup dedup};
   10/23 only additionally strip an ambiguous phrase filler (`you know`/`like`/`so`)** —
   which the cleaner deliberately skips as unsafe and which the model itself does
   *inconsistently* (leaves `you know` in most rows); **1/23 is `Package dot swift`→
   `Package.swift`, the canonicalizer's job.** Zero genuinely-novel safe transforms.
2. *The instant a model does more, it breaks.* The only way to lift engagement (the relaxed
   prompt) produced real content damage — e2b dropped `damn`, qwen3:4b invented `file`
   (confirmed by 3 independent judging mechanisms, 0 dead judges). Safe ≈ deterministic;
   above-deterministic ≈ unsafe.

And the costs are real and were under-stated: gemma4:e2b is **7.3 GB resident** (measured
via `ollama ps`, NOT "low-memory" — the MatFormer E2B still loads ~E4B-class weights;
qwen3:1.7b is 1.9 GB), adds **~680ms** post-fn-release latency (`AppCoordinator.swift:365`),
and is **largely inert on cmux** — the primary target — because the append-only insertion
latch can't apply shortening/interior edits (`AppCoordinator.swift:367-370`). A dedup rule
costs 0 GB, 0 ms, and works on cmux.

*The model-SELECTION result still stands, conditionally:* IF an LLM polish is ever shipped
(e.g. opt-in, deletion-capable apps only), **`gemma4:e2b` + `conservative`** is the right
choice — reached by unbiased convergence (manual token-check + single trap-aware judge +
12-judge majority panel + a blind synthesis agent all agree: conservative safe for e2b &
e4b; relaxed unsafe for both). e4b/conservative is the higher-engagement, heavier, slower
alternative. But the bar to justify shipping any of them over a dedup rule is now very high.

**Recommended action (refined by the round-3 steelman, F27):** extend
`TranscriptDeterministicCleaner.clean` with **case-insensitive adjacent-dup dedup AND
phrase-level repeat collapse** (`send it to send it to`→`send it to`), GUARDED against
legitimately-doubled words (`is is`/`the the` safe, but `had had`/`that that` valid). This
subsumes ALL the safe value both rounds found the 7.3 GB model offer — on every target, for
free. Keep `polishEnabled` default OFF, keep the guard. The LLM's ONLY non-deterministic
value is self-correction resolution (`merge no rebase`→`rebase`), which is provably the same
generative act that garbles `doesn't`→`doesn: t` and drops `can you` — not shippable at this
tier. Re-eval the LLM path after the next on-device model swap, not before.

**Rejected models:** qwen3:4b/conservative (11 empty outputs = utterance deletion);
e2b/relaxed & qwen3:4b/relaxed (content-damage fails); qwen3:1.7b (near-inert, 15/16 no-op);
FoundationModels (prior, example-bleed).

Full reasoning trail in the findings log (F1–F26) below; methodology + exit condition follow.

---


Autonomous, long-running investigation. **Goal: decide whether a local model can do
Epos's transcript polish well enough to (a) ship polish on by default, and/or (b)
shrink or retire the 1048-line `TranscriptPolisherGuard`.** The guard exists only to
babysit a bad model; if a model is good *raw*, the guard is dead weight.

Local-only is a hard constraint (no cloud). Candidates are on-device-class Ollama
models. FoundationModels is **out** — already judged too weak (deterministic
example-bleed; see [[epos-llm-polish-probe-status]]).

**Optimization target: speed + accuracy + low memory pressure, jointly.** This runs on
live push-to-talk dictation, so a model that's accurate but slow or heavy fails the
product even if it wins on quality. Every cell records latency and the model's on-disk
size (memory proxy), not just correctness. Model sizes so far: qwen3:1.7b 1.4GB,
qwen3:4b 2.5GB, gemma4:e2b ~2GB, gemma4:e4b 9.6GB (heavier than qwen3:4b — e4b is the
accuracy-ceiling probe; e2b is the low-memory candidate).

**What polish must actually do (NET of the free deterministic floor).** The shipped
`TranscriptDeterministicCleaner.clean()` already removes `um/uh/er/hmm`, numeric
ordinals, comma-`so`/`like` openers, and one grammar miss — deterministically, no model.
A model that only removes `um` adds **zero** product value. The engine's entire reason to
exist is the residual `clean()` documents it cannot do: stutters (`the the`, `is is`),
self-corrections (`Tuesday no wait Wednesday`), and phrase fillers (`you know`, `I mean`,
`basically`, bare `like`/`so`). The headline metric is residual handling; filler-token
removal is zero-credit table stakes.

## Methodology (the point, not a footnote)

- **Never stop at the first symptom.** One cell of the matrix is a data point, not a
  conclusion. Every surprising result gets a designed follow-up that tries to *refute*
  it before it's believed.
- **Challenge inherited conclusions.** Two from the prior session already fell:
  "qwen hallucinates" (it doesn't — it no-ops under the conservative prompt) and
  "the model is the problem" (a dead-simple prompt makes qwen3:1.7b clean correctly —
  it's the prompt). Treat every remaining belief as equally suspect.
- **Determinism.** temp=0 / greedy → one run is the full truth for a fixed
  (model, prompt, known-terms, input). So variation must come from changing a
  *variable*, not re-running. Re-running the same cell proves nothing.
- **Test raw, no guard.** The guard masks model behavior; benching through it tells us
  nothing about the model. All cells run the engine directly.

## Variables

| Axis | Values |
|---|---|
| model | qwen3:1.7b, qwen3:4b, gemma4:e2b, gemma4:e4b |
| prompt | strict, conservative (prod default), relaxed, + simple (new, see finding F3) |
| known-terms | polluted (current prod), cleaned, none — isolate the pollution variable |

Corpus, tagged by what each row tests:
- **disfluent** — stutters / self-corrections / phrase fillers the deterministic floor
  CAN'T do. The engine must improve on `det = clean(canon)` here.
- **bait-clean** — already-clean / command / code / path / spoken-punctuation rows. Must
  stay byte-identical.
- **bait-jargon** — the real-clip rows (`Stas`, `CMOX`, `Siemux`, `project.yamo`). A model
  that "corrects" `Siemux`→`Linux` is an instant disqualifier; the current corpus can't
  catch that, so these are folded in.

Each cell is fed `canon = canonicalize(raw)` (jargon already in canonical form), so the
bait-jargon test is "does the engine preserve correct jargon," and is scored against
`det` (the free floor), not against `raw`.

## Scoring (no guard, so we judge directly)

Per row: two deterministic axes plus one judged axis.

1. **Residual handling** (disfluent rows): did the engine improve on `det` by removing a
   stutter / self-correction / phrase filler `det` left — `out != det` in the right
   direction? This is the headline. (`um/uh` removal is zero-credit — `det` already did it.)
2. **Bait preservation** (bait-clean + bait-jargon): `out == canon`? deterministic. Any
   change is a defect, categorized by severity: *cosmetic drift* (added period, casing —
   survivable with a small guard) vs *meaning destruction* (content word changed /
   invented / reordered / jargon corrupted — disqualifying).
3. **Meaning preservation** (any changed row): did the edit preserve meaning, or
   paraphrase / invent / reorder? **Judged by a skeptical Claude subagent with a binary
   per-axis rubric (all content words present? anything invented? anything reordered?),
   NOT a local model** — a lenient local judge would relocate the "1 run = factual" trap
   into the scorer. Close calls get flagged into this log, not silently bucketed.

## Exit condition (so "don't stop at the first symptom" ≠ "never stop")

Stop when EITHER:
- a concrete `(model, prompt, known-terms)` config holds **100% bait preservation
  including jargon rows** AND cleanly handles a majority of the disfluent residual cases,
  at acceptable latency and memory — a shippable candidate; OR
- a documented conclusion that no local candidate clears that bar, with the per-model
  failure mode recorded, so the decision (keep guard / drop polish / wait for a new model)
  is evidence-backed.

## Findings log (append-only)

- **F1** — qwen3:1.7b, conservative prompt, raw: **no-op on all 14 rows** (byte-identical
  in==out, including rows it's allowed to clean). Not hallucination — the opposite.
- **F2** — Prior "qwen hallucinates / empty outputs" conclusion **not reproduced**; retired.
- **F3** — qwen3:1.7b CAN remove fillers: dead-simple direct prompt ("remove um/uh/er/hmm,
  return only the cleaned sentence") → `um so like we should uh ship it you know` became
  `so like we should ship it you know`. So F1 is a **prompt artifact**, not model
  incapacity. The conservative prompt's "prefer returning unchanged when uncertain" line
  is the prime suspect. → motivates adding a `simple` prompt style to the sweep.
- **F4** — qwen sweep (252 cells, 21-row corpus, scored vs `det`). Two distinct profiles:
  **qwen3:1.7b** is fast (350–476ms) and safe (0–2 bait defects/13) but under-cleans
  (2–5 residual/8). **qwen3:4b** cleans more (4–7/8) but breaks bait badly under the
  `strict` prompt (5/13 defects) and is slower (593–1244ms). No qwen cell is both
  high-residual AND zero-defect — the safety/coverage tension is real.
- **F5** — *Pollution hypothesis challenged.* Removing known-terms (`none`) frequently
  *increased* bait defects vs the polluted list (1.7b conservative 0→2; 1.7b strict 0→1).
  Reading: the legit jargon terms in the list PIN jargon (prevent "correction"), and that
  help outweighs the junk-phrase harm. So "pollution causes hallucination" is not
  supported by the deterministic counts — needs per-row judge confirmation, but the naive
  fix (just empty the list) looks like it would make things *worse*.
- **F6** — gemma4:e4b envelope PASSES: `think:false` accepted, format schema honored
  (valid `{"cleaned":…}`). On first contact it cleaned the disfluent row AND preserved
  `Stath`/`Siemux` byte-identical — passed the jargon disqualifier qwen sometimes fails.
  Warm inference ~400–800ms; one-time 9.7s cold load (9.6GB).
- **F7** — `residual+` counts *any* change on a disfluent row (could be a clean fix OR a
  mangle); `baitDefect` counts *any* change on a bait row (could be cosmetic OR
  meaning-destruction). Both are necessary-not-sufficient — the skeptical judge pass is
  what converts them into verdicts. Do not rank models on the raw counts alone.
- **F8** — num_ctx=2048 truncation confound NOT triggered: largest prompt is
  conservative/polluted at 3293 chars (~820 tokens), well under 2048.
- **F9** — *Empty-output collapse, reproduced and localized to (qwen3:4b, conservative).*
  Returns an EMPTY `cleaned` on disfluent rows (total data loss): none=6/8, polluted=4/8.
  **SELF-CORRECTION:** my first read claimed the polluted known-terms list *caused* the
  empties ("none doesn't show it") — I had only looked at the polluted column and never
  checked none. The honest scorer shows none is WORSE (6 vs 4). So pollution does NOT
  drive the collapse; it's a qwen3:4b + conservative-prompt failure. This is the same
  "concluded from one look" error the whole exercise is meant to catch — caught here by
  forcing the directional re-score instead of trusting the glance. (F5's jargon-pinning
  observation stands on its own; it was never about empties.)
- **F10** — *The deterministic `residual+` metric is unreliable by construction* —
  `out != det` fires for under-performance (1.7b relaxed left `um/uh` raw → worse than
  `det`, still counted +) and for empties (F9). The raw counts are TRIAGE ONLY. Authoritative
  scoring is post-hoc on the JSONL (canon/det/out are all stored): classify each cell as
  no-op / empty / improved-on-det / regressed-from-det / mangled, then judge quality.
  No harness change needed.
- **F11** — qwen3:4b `strict`'s 5 "bait defects" are a single uniform behavior: a trailing
  period appended to every sentence (cosmetic drift, guard-fixable) — NOT meaning
  destruction. Its disfluent cleans are genuinely good (`the the build is is broken` →
  `the build is broken`). Severity matters: strict's defect ≠ conservative/polluted's empties.
- **F12** — Ambiguous spoken-punctuation bait: on `…to dana comma then ping…`, 1.7b
  *deletes* the word "comma" (meaning loss) while 4b *converts* it to "," (arguably
  correct, and the canonicalizer's job anyway). Flag for judge; it's a corpus-design seam,
  not a clean pass/fail.
- **F13** — *gemma4:e4b is the only model that always engages*: honest scorer shows
  0 no-op / 0 empty / 0 left-fillers, 8/8 "changed" under EVERY prompt. Bait cleanliness
  by prompt: conservative best (10 identical / 2 cosmetic / 1 content-defect), strict mid
  (8/4/1), relaxed worst (6/5/2). **Robust to known-terms pollution** — polluted and none
  rows are byte-identical, so gemma ignores the junk list entirely (unlike qwen). Latency
  ~1020–1100ms, model 9.6GB — the accuracy candidate, NOT the low-memory one. Quality of
  the 8 "changed" rows is unconfirmed until the judge pass (could be clean or over-edit).
- **F14** — *Current standings (pre-judge, pre-e2b):* gemma4:e4b/conservative is the only
  config that both engages on every disfluent row AND keeps bait near-clean — frontrunner
  IF the judge confirms the changes are real cleans. qwen3:1.7b is fast+safe but lazy
  (no-op). qwen3:4b is disqualified under conservative (empty collapse) and only relaxed/none
  is workable but with cosmetic bait drift. The speed/memory winner hinges entirely on
  whether gemma4:e2b (running) keeps e4b's engagement at lower cost.
- **F15** — *gemma4:e2b/conservative is the speed+memory+accuracy frontrunner.* 6/8 engage
  (2 no-op), bait 12/13 identical (0 cosmetic, 1 content-defect), **~680ms** — ~35% faster
  than e4b (~1050ms) and lower runtime memory, while being *cleaner* on bait than e4b
  (12 identical vs 10). Tradeoff vs e4b: 6 engaged not 8. e2b/strict adds heavy cosmetic
  drift (7 cosmetic = period/comma spray); e2b/conservative does not. KT pollution again
  makes ~no difference. Pending judge on the 6 changed rows.
- **F16** — *The "1 content-defect" is near-universal across configs* (cDef=1 in almost
  every row of the combined table). Strong signal it's a SINGLE bait row everyone trips on
  — the spoken-`comma` row (F12). If the judge rules it BENIGN (comma→"," is faithful),
  then most configs are effectively bait-clean and the real model separators collapse to:
  engagement (does it clean at all), cosmetic drift (strict's period spray), and latency.
  → next challenge: confirm via verdicts, then decide if that row is a corpus artifact.

- **F17** — *Determinism assumption VERIFIED* (not just asserted): gemma4:e2b and qwen3:4b
  each returned byte-identical output across 3 / 2 repeated temp-0 runs of the same input.
  So one run per cell is the full truth; no multi-sampling needed. Bonus: on a hard
  technical-disfluent probe (`so the the AudioCapture um needs to like buffer the the
  samples you know`) gemma4:e2b produced `The AudioCapture needs to buffer the samples.` —
  every disfluency gone, `AudioCapture` jargon preserved, casing+period fixed. Encouraging
  for the e2b frontrunner beyond the thin 21-row corpus.

- **F18** — *Judge batch1 (qwen + gemma4:e4b, 120 cells): 100 GOOD / 13 BENIGN / 7 HARMFUL
  / **0 MANGLE**.* The headline: when these models change a disfluent row they clean it
  CORRECTLY — zero meaning-destruction on the cleaning side, across every config. All
  failure is on bait (helpful-corruption) or laziness (no-op). Confirmed:
  - **gemma4:e4b/conservative = clean frontrunner**: 8/8 GOOD, 0 HARMFUL, fewest cosmetic
    drift (2 vs strict's 4). strict also 0-HARMFUL but sprays more trailing periods.
  - **gemma4:e4b/relaxed DISQUALIFIED**: corrupts proper noun `Stath`→`Stanth`/`Stan` in
    BOTH kt conditions. The permissive prompt invites the model to "fix" names. Lesson:
    the prompt's restraint is what protects jargon, not the known-terms list.
  - **qwen harmful failures all in `/none`**: 1.7b drops command verb `Edit`; 4b/conservative
    empties a clean row. → the known-terms list (even polluted) HELPS qwen pin content
    (F5 confirmed by judge). Naive "empty the polluted list" would REGRESS qwen.
  - comma row (F16 refined): BENIGN when converted to ",", HARMFUL when the word is dropped
    — model-dependent, not one uniform artifact.

- **F19** — *Judge batch2 (gemma4:e2b, 48 cells): 0 MANGLE, 0 HARMFUL under conservative
  AND relaxed.* e2b/conservative = 6 GOOD / 1 BENIGN(comma) / 0 HARMFUL; e2b/relaxed =
  7 GOOD / 1 BENIGN / 0 HARMFUL; e2b/strict = 8 GOOD but 1 HARMFUL (drops "comma"). **Size
  inversion:** e2b/relaxed is clean where e4b/relaxed was DISQUALIFIED (Stath corruption) —
  the smaller model is *less* eager to "fix" a real-looking name. Bigger ≠ safer.
- **F20** — *DECISION (pre-round-2): gemma4:e2b/conservative is the speed+accuracy+memory
  pick.* 6/8 good cleans, 0 harmful, 0 cosmetic drift, ~680ms, low-memory gemma variant.
  e2b/relaxed trades +1 clean for ~2 cosmetic drifts. e4b/conservative is the accuracy
  ceiling (8/8) but 1.5× slower and 9.6GB. qwen3:4b/relaxed/polluted is a mid contender
  (7/8, 0 harmful) but heavier and prompt-fragile (collapses under conservative). NOT YET
  FINAL — the 21-row corpus is thin; round 2 must try to break the e2b frontrunner before
  this ships.

- **F21** — *Round 2 (adversarial, 4 shortlist configs × 16 trap rows): the e2b frontrunner
  SURVIVES.* My manual read (token-check + reasoning): **zero negation losses** anywhere
  (doesn't/never/no longer/don't/isn't all survived in all 4 configs — the deadliest
  silent error never fired); **zero jargon/name corruption** anywhere (CMUX, Stas,
  SpeechAnalyzer, xcodegen, AXInsertionTargetObserver, entitlements, Package.swift all
  preserved); both hard-bait technical sentences byte-identical for every config. The
  round-1 `Stath`→`Stan` scare did NOT generalize. Only content dings, both in the
  *aggressive* relaxed configs: e2b/relaxed dropped `damn` (euphemizing); qwen3:4b/relaxed
  invented "file" once. **e2b/conservative: 0 harm across all 16**, but leaves `you know`
  in ~6 rows (quality miss, not safety). Concrete tradeoff: conservative = maximally safe +
  lazy; relaxed = cleaner + tiny content-drop risk.
- **F22** — *Unbiased verification (workflow `polish-unbiased-panel`):* because the judge is
  the keystone and my own read is biased toward e2b, the adversarial round is being
  re-judged by 3 INDEPENDENT judges per config (majority vote) + a synthesis agent that
  re-derives the ranking from the majority verdicts and the raw engagement/latency data,
  blind to this doc's preference. The recommendation below is pending that panel's verdict.

- **F23** — *4th-judge cross-check (independent single trap-aware judge, 64 cells): 62 PASS
  / 2 FAIL, confirming the manual read EXACTLY.* conservative configs (e2b AND e4b) = 16/16
  SAFE; relaxed configs both NOT SAFE (e2b/relaxed dropped `damn`; qwen3:4b/relaxed invented
  `file`). Clean through-line: **the conservative prompt's restraint is the safety
  mechanism; relaxed invites content damage.** All negations preserved everywhere; all
  jargon recognizable everywhere; all 8 bait rows byte-identical. Decision narrows to two
  SAFE configs: e2b/conservative (~680ms, low-mem, leaves "you know") vs e4b/conservative
  (~1050ms, 9.6GB, cleans 2 more). Awaiting the 12-judge panel for unbiased confirmation.

- **F24** — *Unbiased 12-judge panel (workflow, 3 independent judges/config, majority vote,
  0 dead judges) CONFIRMS F23 and the manual read with full agreement:* e2b/conservative 0
  fails, e4b/conservative 0 fails, e2b/relaxed 1 fail (`damn`), qwen3:4b/relaxed 1 fail
  (`file`). The blind synthesis agent independently recommended e2b/conservative on the
  strict priority order. Three independent mechanisms converging on the same verdict is the
  unbiased confirmation the conclusion rests on. See top-of-file CONCLUSION.

- **F25** — *THE decisive finding (advisor-prompted, the question I hadn't asked): what does
  the SAFE winner actually do beyond deterministic rules?* Decomposed all 23 unique
  e2b/conservative disfluent transforms vs a baseline of {live um/uh removal + adjacent-dup
  dedup}: 12 identical to baseline, 10 only strip an ambiguous phrase filler (cleaner skips
  these by design; model does them inconsistently), 1 is canonicalizer territory
  (`Package.swift`). **Zero novel safe transforms.** Combined with F21/F23/F24 (relaxed = the
  only way to engage more = content damage), this proves: safe ≈ deterministic. The benchmark's
  real output is "extend the deterministic cleaner," not "ship a model." Flipped the headline.
- **F26** — *"e2b is low-memory" was WRONG — measured, not asserted (advisor-flagged).*
  `ollama ps` shows gemma4:e2b resident at **7.3 GB** (MatFormer E2B loads ~E4B-class
  weights), vs qwen3:1.7b 1.9 GB. So e2b fails the priority-3 (low memory) goal outright —
  heavier than qwen3:4b. My earlier "low-memory candidate" framing (F13/F15/F20) was an
  unverified assumption; corrected here. Strengthens the don't-ship-the-LLM conclusion.

- **F27** — *Round 3 / steelman ("is LLM polish useless?" — challenged the conclusion itself).*
  14 hard rows the deterministic floor provably can't clean (false-starts, phrase repeats,
  meta-filler, hedge piles, run-ons), shortlist run, judged by a 2-axis unbiased panel
  (3 judges/config, 0 dead, `polish-hard-niche-panel`). Per-config (unsafe / valueAdd of 14):
  e2b/conservative **0 / 1**, e2b/relaxed **1 / 8**, e4b/conservative **1 / 5**, qwen3:4b/relaxed
  **1 / 8**. Conclusions: **(a) "useless" was an OVERCLAIM** — every config had valueAdd>0;
  the LLM safely does things det can't (clean filler-dense run-ons, remove meta-clarifiers
  `the bug the one in the parser`→`the bug in the parser`, resolve self-corrections). **(b) But
  value and damage are ONE mechanism, proven by idx 12:** the identical operation (resolve
  `friday no wait thursday`) is a value-add for e4b/conservative & qwen3/relaxed but the
  *unsafe* cell for e2b/relaxed (garbled to incoherent `Thursday no wait Thursday`). The
  unique value (self-correction / clarifier resolution) is the SAME generative act that
  produced every damage cell (idx 6 dropped `can you`; idx 10 garbled `doesn't`→`doesn: t`).
  Can't keep one without the other — **inseparable at this tier.** (c) The only unsafe=0 config
  (e2b/conservative) has exactly 1 value-add — the phrase-repeat collapse — which is itself a
  deterministic rule waiting to be written (value in all 4 configs, damage in none). **(d) The
  panel REFINED the rule recommendation:** the current cleaner left deterministically-winnable
  cases on the table — extend it to **case-insensitive + phrase-level dedup** (not just
  adjacent-word), which subsumes the safe value at 0 GB / 0 ms / works-on-cmux. Net: the LLM's
  only non-deterministic value is self-correction resolution = its own damage vector. **Ship the
  extended deterministic rule; ship the LLM to nobody at this tier;** hold the LLM path
  default-off, re-eval after the next model swap.

## Combined honest table (4 models × 3 prompts × 2 KT, scored vs det)

See `.build/evals/sweep-*.jsonl` + `scripts/score-polish-sweep.py`. Headline cells:

| config | engage(chg/8) | bait ident/cosm/cDef | ms |
|---|---|---|---|
| gemma4:e2b conservative | 6 (2 noop) | 12 / 0 / 1 | ~680 |
| gemma4:e4b conservative | 8 | 10 / 2 / 1 | ~1050 |
| qwen3:1.7b conservative/polluted | 1 (7 noop) | 13 / 0 / 0 | ~420 |
| qwen3:4b relaxed/none | 8 | 10 / 2 / 1 | ~670 |
| gemma4:e2b/e4b strict | 8 | period-spray cosmetic | ~750–1050 |
| qwen3:4b conservative | empty collapse (4–6/8) | — | ~650 |

## Open questions to drive the sweep

- Does gemma4 (newer, on-device class) clean correctly out-of-the-box where qwen needs
  prompt coaxing? (the "gemma gets it easier" hypothesis — test before optimizing qwen)
- Is the known-terms pollution causing any model to inject junk phrases? (isolate it)
- Which prompt style maximizes filler-removal WITHOUT breaking bait, per model?
- Does `think:false` in the Ollama request break non-thinking gemma4? (verify on pull)
