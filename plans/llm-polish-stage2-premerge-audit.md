# LLM Polish Stage 2 — Pre-Merge Bug Audit

## Metadata

- Date: 2026-05-31
- Branch audited: `feat/llm-polish-stage2` (merge-base `d0d6123`, tip `840cae4`)
- Scope: full branch diff vs `main` (24 files, +2299 / −60)
- Method: 7 independent dimension reviewers over the branch diff → each candidate
  finding put through a 3-lens adversarial verification panel (reproduce / find an
  upstream guard that already neutralizes it / check existing test coverage); a
  finding survived only if not refuted by a majority. 47 agents total.
- Cross-check: guard findings (ranks 1, 3, 4, 5) independently reproduced by the
  orchestrator compiling and running the real `TranscriptPolisher.polishRetainsContent`
  against adversarial input pairs (throwaway probe, since removed; suite green).
- Ground truth at audit time: `swift build -Xswiftc -warnings-as-errors` PASS;
  `swift test` 79 tests, 2 skipped, 0 failures; `swiftlint --quiet` clean.
- Result: 13 candidates → **11 confirmed**, 2 dropped.

## Overall assessment

Conditionally mergeable. The polish feature ships **opt-in and default-off**
(`Settings.polishEnabled = false`), so the default user is unaffected and nothing
here corrupts the non-polish path. But the content-retention guard — the branch's
sole documented defense against the model altering meaning — has **five independent
false-accept holes** that type altered text into the user's app when polish is
enabled. Fix the guard false-accepts (ranks 1–5) before flipping `polishEnabled`
on by default; ranks 6–7 are immediate follow-ups (rank 7 needs a one-time
wall-clock measurement on the installed signed app); ranks 8–11 are optional.

All five guard holes live in one file: `Sources/Epos/Speech/TranscriptPolisherGuard.swift`.

---

## Confirmed findings

### Rank 1 — HIGH — Guard blind to symbol-only tokens; polish can silently drop `--` / `/`

- File: `Sources/Epos/Speech/TranscriptPolisherGuard.swift` — `tokenSpans` (73-96),
  `isAlphanumeric`/`isConnector` (110-116), `polishRetainsContent` (21-52)
- Category: logic-error · Verifier: 3 confirmed / 0 refuted
- Trigger: polish enabled. `"run dash dash verbose now"` → canonicalizer → `"run -- verbose now"`;
  model drops the lone `--` → `"run verbose now"`. `polishRetainsContent("run -- verbose now",
  "run verbose now")` returns `true`, so `"run verbose now"` is typed. Same for
  `"use / as root"` → `"use as root"` and `"cd / etc / hosts"` → `"cd etc hosts"`.
- Root cause: `tokenSpans` only starts a token on an alphanumeric (81) and admits a
  connector only when flanked by two alphanumerics (83). A standalone `--`/`/`
  surrounded by spaces produces NO token, so it is invisible to `matchedContentTokens`.
  Deleting it leaves the content-token sequences identical; the punctuation budget only
  catches `,?!` and the boundary check only recognizes `.?!`. Worst case: dropped `/`
  in a path typed into a terminal.
- Fix: account for standalone symbol-only tokens — extract the multiset of significant
  non-alphanumeric runs (`--`, `/`, …) from both sides and reject when any count drops,
  or emit standalone symbol runs as tokens in the sequence comparison. Add regression
  rows: `("run -- verbose now", "run verbose now") == false`, `("use / as root", "use as root") == false`.

### Rank 2 — HIGH — Meaningful comparator `like` force-dropped when adjacent to a filler

- File: `TranscriptPolisherGuard.swift` — `isDroppableLike` (197-198), reached from `matchedContentTokens` (141)
- Category: logic-error · Verifier: 3 confirmed / 0 refuted
- Trigger: polish enabled. `"it tastes like um chicken"` → model removes `um` and `like`
  → `"it tastes chicken"`. `polishRetainsContent` returns `true`; meaning-inverted text
  typed. Same for `"it works like uh magic"` → `"it works magic"`. (NOT `"looks like um rain"`:
  `looks` is in `semanticLikePrevious` and is correctly rejected.)
- Root cause: `isDroppableLike` returns true whenever the token immediately before OR
  after `like` is a single filler or `so` (197-198), treating `like` itself as droppable.
  The `semanticLikePrevious`/`semanticLikeNext` lists (`PolishVocabulary.swift:29-42`)
  only cover pronouns and perception verbs (seem/look/sound/feel), so any other content
  verb (tastes/works/runs/smells/build) leaves a comparator `like` unprotected. A filler
  adjacent to `like` does not make `like` itself filler.
- Fix: remove the two filler-neighbor early-return clauses (197-198) so `like` is
  droppable only sentence-initially / when no semantic anchor surrounds it; or require
  BOTH neighbors (after skipping intervening fillers) to be fillers or sentence edges.
  Adjust the existing adjacent-filler `like` test; add `("it tastes like um chicken",
  "it tastes chicken") == false`.

### Rank 3 — MEDIUM — Punctuation budget covers only `, ? !`; `: ; — ( ) " …` evade it

- File: `TranscriptPolisherGuard.swift` — `punctuationAdditionsAreJustified` (219-224); `containsSentenceBoundary` (266-280)
- Category: logic-error · Verifier: 3 confirmed / 0 refuted · independently reproduced by orchestrator probe
- Trigger: polish enabled. All words kept, glyph inserted: `"the error is timeout"` →
  `"the error is: timeout"`; `"done now go home"` → `"done; now go home"`; `"we win lose it"`
  → `"we win — lose it"`. All return `true`. Control: `"ship it"` → `"ship it?"` correctly rejected.
- Root cause: `punctuationAdditionsAreJustified` iterates only `[",", "?", "!"]` (220);
  `:`, `;`, em/en-dash, quotes, ellipsis, parens are never counted and never register in
  `containsSentenceBoundary`, and they are not connectors, so they sit in inter-token gaps
  no check inspects. A model-added colon reframes phrase+clause as label:definition.
- Fix: extend the budget glyph list to include `: ; — –` (and consider `( ) " …`),
  rejecting any net addition over the raw count. Add guard-table rows for each.

### Rank 4 — MEDIUM — Added period+capital splitting one sentence into two is never checked

- File: `TranscriptPolisherGuard.swift` — `preservesRawSentenceBoundaries` (232-260), raw-only loop (241-256)
- Category: logic-error · Verifier: 3 confirmed / 0 refuted · independently reproduced by orchestrator probe
- Trigger: polish enabled. `"ship it now"` → `"ship it. Now"`; `"i ran it again"` →
  `"i ran it. Again"`. Returns `true`; two-sentence rewrite typed.
- Root cause: `preservesRawSentenceBoundaries` iterates only RAW adjacent matched pairs
  and `continue`s whenever the RAW gap has no boundary (250) — so it detects a COLLAPSED
  raw boundary but never inspects the polished gap when raw had none. An ADDED boundary
  is invisible, and `.` is intentionally unbudgeted (to allow restoring a trailing period).
- Fix: add a symmetric reverse check — for each adjacent matched pair whose raw gap has
  NO boundary, reject when the polished gap DOES contain one. Keep allowing a restored
  trailing end-of-text period (no following capitalized token). Add `("ship it now",
  "ship it. Now") == false`.

### Rank 5 — MEDIUM — Hyphen-merge collapses a dictated sentence boundary into a nonsense compound

- File: `TranscriptPolisherGuard.swift` — `hyphenMergeParts` (184-189), merge mapping (154-159), boundary loop skip (246)
- Category: logic-error · Verifier: 3 confirmed / 0 refuted · independently reproduced by orchestrator probe
- Trigger: polish enabled. `"we are done. Ship now"` → `"we are done-ship now"`;
  `"it is done. Run it"` → `"it is done-run it"`. Returns `true`; fused `done-ship` with
  erased `. ` boundary typed.
- Root cause: `hyphenMergeParts` accepts any polished hyphenated token whose split parts
  equal the next N raw tokens (188), inspecting only token TEXT, never the raw source gap.
  `matchedContentTokens` maps every spanned raw token to the same `polishedIndex` (155-156),
  and `preservesRawSentenceBoundaries` skips that pair via the `left.polishedIndex !=
  right.polishedIndex` guard (246), so a collapsed boundary inside the merge is never seen.
- Fix: reject the merge when any inter-token raw gap among the spanned tokens contains a
  sentence boundary (require whitespace-only gaps). Preserves legit `"well known"` →
  `"well-known"`. Add `("we are done. Ship now", "we are done-ship now") == false`.

### Rank 6 — MEDIUM — Polish widens the finalize window; a held fn re-press is swallowed and the next recording dropped

- File: `Sources/Epos/App/AppCoordinator.swift` — polish await (264-267), start guard (169), reset (378); `Hotkey/FnHotkey.swift` edge-trigger
- Category: ux-gap · Verifier: 3 confirmed / 0 refuted
- Trigger: polish enabled. Release fn → `.finalizing`; `runSession` blocks on
  `await polisher.polish(finalText)` up to ~2.5s before `resetToIdle` returns to `.idle`.
  During that window the user presses-and-holds fn for the next utterance; `startRecording`'s
  `guard state == .idle` silently rejects it. When polish finishes, the still-held key
  produces no new `flagsChanged` edge, so no `onPress` fires — the utterance is lost until
  physical release + re-press.
- Root cause: this branch inserts the polish `await` between recognizer drain and
  `resetToIdle`, widening `.finalizing` by up to the generation time. The pre-existing
  edge-trigger + `.idle`-only guard (no pending-intent latch) was latent on `main`; the
  widened window makes the swallow materially reachable in back-to-back dictation.
- Fix: latch a "start requested while finalizing" flag when `startRecording` is rejected
  for state, and at the `.finalizing → .idle` transition replay `onPress` (or query the
  live `.function` modifier) if fn is still down. At minimum, log the swallowed press and
  flash a brief "busy" indicator so the drop isn't silent.

### Rank 7 — MEDIUM — 2.5s timeout may not bound user-perceived latency (SDK cancellation unknown)

- File: `Sources/Epos/Speech/TranscriptPolisher.swift` — `enginePolishAttempt` (157-170)
- Category: logic-error · Verifier: 2 confirmed / 1 uncertain (gated on SDK behavior)
- Trigger: polish enabled. Dictate a long/hard utterance whose on-device decode exceeds
  2.5s, release fn. UI parks in `.polishing` awaiting `polisher.polish`. Policy intends to
  give up at 2.5s and insert raw, but if the engine doesn't abort on cancellation the user
  waits the full decode before any text lands.
- Root cause: races `session.polish` against `Task.sleep` in a NON-throwing
  `withTaskGroup`, which awaits the remaining child at scope exit; `group.cancelAll()` only
  sets the cooperative flag. The concrete engine wraps FoundationModels `respond()` with no
  cancellation handling, and the SDK swiftinterface documents no cancellation contract. The
  fallback text is still correct (raw) — this is latency, not wrong text. The unit test uses
  a `Task.sleep` fake (cancellation-aware), so it cannot catch this.
- Fix (conditional on measurement): run `session.polish` in a detached Task and resolve the
  timeout via a continuation that returns at the deadline regardless of whether `respond()`
  observes cancellation, letting the orphaned decode finish in the background (the
  per-recording session already isolates it). **First**: measure wall-clock `polish()` return
  on the installed signed app for an utterance known to exceed 2.5s — if it returns at ~2.5s
  the current code is fine; if at full-decode time, the detach fix is required.

### Rank 8 — LOW — Polish "applied" log mixes pre- and post-canonicalize char counts

- File: `AppCoordinator.swift` — `rawCount: finalText.count` (276) vs `polishedChars=result.text.count` (344)
- Category: logic-error · Verifier: 3 confirmed / 0 refuted
- Trigger: dictate text whose canonicalization changes length and is then polished. `rawChars`
  is the pre-canonicalize raw stream; `polishedChars` is `canonicalize(polished)`. A reader
  computing `rawChars − polishedChars` as "chars polish trimmed" conflates the canonicalizer's
  rewrite with the polish stage's filler removal. Diagnostic-log-only; typed text and outcome
  label are correct and privacy-safe.
- Fix: measure both counts on the same normalization (surface `canonicalRaw.count` from
  `polish()` or canonicalize `finalText` at the call site before counting).

### Rank 9 — LOW — `activePolisher ?? makePolisher()` fallback at finish is unreachable dead code

- File: `AppCoordinator.swift:264` (mirrored at `TranscriptPolisher.swift:146`)
- Category: dead-code · Verifier: 2 confirmed / 1 refuted (refuted as "not a reportable defect")
- Detail: `startRecording` unconditionally sets `activePolisher` before spawning the task;
  it is nilled only in `resetToIdle`, which every early `runSession` exit calls before
  returning. So line 264 always has a non-nil `activePolisher`. Per CLAUDE.md "no fallbacks
  for impossible internal states", replace with `guard let polisher = activePolisher else { … }`
  (log/assert) or thread the polisher into `runSession`.

### Rank 10 — LOW — `baseline.md:41` says polish "converts spoken punctuation"; code forbids it

- File: `specs/baseline.md:41`
- Category: spec-violation · Verifier: 3 confirmed / 0 refuted
- Detail: the shipped engine prompt explicitly instructs the model NOT to convert spoken
  words into symbols, and the guard rejects any model-introduced symbol (test
  `"i need the period key"` → `"i need the . key"` == false). Spoken-symbol conversion is
  owned solely by `TranscriptCanonicalizer`. Risk: a maintainer extends polish to convert
  punctuation, building behavior the guard actively rejects.
- Fix: drop "converts spoken punctuation" from `baseline.md:41`; state polish only removes
  fillers and lightly fixes capitalization/spacing, and that spoken-symbol conversion is
  owned by `TranscriptCanonicalizer` (run on both raw and polished).

### Rank 11 — LOW — Tracked files reference `probes/llm-polish`, which this branch gitignores

- File: `Tests/EposTests/PolishEvalTests.swift:20` (also `FoundationModelsPolishEngine.swift:11`)
- Category: spec-violation · Verifier: 2 confirmed / 1 refuted
- Detail: this branch adds `probes/` to `.gitignore` while two tracked files still reference it:
  PolishEvalTests.swift:20 documents an actionable refresh command (`cd probes/llm-polish && swift run …`)
  that fails on a fresh clone; the engine comment is informational. Make the documented command
  reproducible from a clean checkout, commit the harness, or note the path is local-only.

---

## Dropped (refuted by the panel)

- **insertFinalTranscript one-shot fallback** (`AppCoordinator.swift:309-316`): claimed
  impossible-state fallback; verification found it is reachable defensive code
  (`insertFinalTranscript` is also called outside the active-session path), not the forbidden
  class. No second live AX session is built in practice. 1 confirmed / 2 refuted.
- **"Filler-word detector" non-goal violation**: claimed the branch ships a non-goal;
  verification found the non-goal refers to a standalone filler *detector* feature, distinct
  from the polish stage's filler removal — no genuine contradiction. 1 confirmed / 2 refuted.

---

## Recommended sequencing

1. **Before flipping `polishEnabled` default → true:** fix guard false-accepts ranks 1–5
   (all in `TranscriptPolisherGuard.swift`, each with a regression row).
2. **Immediate follow-up:** rank 6 (swallowed re-press); rank 7 (measure wall-clock first,
   then detach the engine if needed).
3. **At leisure:** ranks 8–11 (log accuracy, dead code, two doc fixes).

---

## Post-audit follow-ups — insertion guard (found in dogfood, 2026-06-02)

Surfaced after the audit, while dictating on the installed app. Not polish-specific
(the append-only path runs regardless of `polishEnabled`).

- **FIXED (`2206cf5`) — append-only latch silently dropped the dictation tail.** Once
  the insertion guard latched append-only, the append branch only typed a tail when the
  new target byte-prefix-matched `committedText`. The recognizer re-cases/punctuates the
  prefix it already emitted ("ok …" → "OK …."), so the authoritative final stopped
  prefix-matching, insertion collapsed to "", and `committedText` (advanced only by
  appends since `2b785ce`) froze — dropping the rest of the dictation. Diagnostic log
  showed `insertedChars=0 totalChars=31` on every reconcile while `displayChars` climbed
  to 100. Fix: raw finals are now loss-proof (append past `committedText`'s LENGTH);
  partials + the polished rewrite stay conservative. Regression tests in
  `InsertionTargetGuardTests.swift`.

- **OPEN — Bug A: the append-only latch likely fires spuriously.** The latch trigger is
  the pre-delete value read finding `!onScreen.hasSuffix(committedText)`. Per `2b785ce`'s
  own message the usual cause is the AX value read racing ahead of the async-applied
  keystrokes (on-screen a few chars *behind* what we typed = lag, not divergence). If so,
  the session should never have left normal mode (where a clean delete+retype fixes the
  re-casing with no seam glitch). NOT fixed this pass: tightening the latch risks the
  blind delete it exists to prevent. Do the instrumentation below first.

- **OPEN — instrument the latch before touching it.** At the `.stopAppendOnly` decision,
  log expected-length vs on-screen-length (lengths only — privacy-safe, no transcript
  text) and the divergence reason (`.value` mismatch vs `.emptyExposed`). The next repro
  then distinguishes AX lag from genuine divergence, which is the evidence needed before
  changing the latch heuristic. Confirm production latched on `.value`-mismatch (not
  `.emptyExposed`) before considering a reason-gated narrowing of the loss-proof append.
