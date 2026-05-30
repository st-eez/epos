# LLM Polish — Stage 2 Live Prototype — Design Spec

## Metadata

- Status: ready for /tdd (open questions resolved)
- Date: 2026-05-29
- Bead: none (repo does not use beads; tracked via `specs/` + session tasks)
- Topic slug: `llm-polish-stage2`
- Planning truth: this doc. Shipped truth: `specs/baseline.md` (updated during implementation).
- Stage 1 source: `specs/llm-polish-probe.md` + probe at `probes/llm-polish/` (concluded). See memory `epos-llm-polish-probe-status`.

## Context

Stage 1 (offline probe) concluded that on-device transcript polish is viable **only** with FoundationModels **guided generation** (`SystemLanguageModel` + `respond(to:generating:)` into a `@Generable` field). Plain instruction-only prompting fails (composition, in-band refusals, ``` fences, 54s context blowups). Guided generation structurally eliminated all of those: 0/13 composed, 0/13 refusals, flat ~1.4s, fully deterministic. The deterministic `TranscriptCanonicalizer` still runs downstream and complements the LLM on private jargon (`CMOX`/`Siemux`→CMUX, `cloud.md`→CLAUDE.md) that the LLM misses.

Residual today's-model limitation: long multi-clause command sentences can be over-compressed (content loss), e.g. `"run the script with --verbose and point it at $HOME/bin"` → `"dollar home slash bin"`. This is the main risk the design must defend against. Spoken-punctuation conversion is unreliable but low stakes (SpeechTranscriber already punctuates real speech).

Today the pipeline is: fn key → AudioCapture → Transcriber (SpeechTranscriber) → live progressive insertion (`ProgressiveTranscriptInsertionSession`, which canonicalizes + reconciles each partial/final). Stage 2 inserts an opt-in polish step between the recognizer's final transcript and the final reconcile.

## Goals

- Opt-in, on-device LLM polish that, after fn-release, erases-and-retypes the live raw dictation to a cleaned version, reusing the existing guarded reconcile (`acceptFinalTranscript`). No new insertion mechanism.
- Zero behavior change when the flag is off or the model is unavailable (today's raw-transcript path, byte-for-byte).
- Never lose the user's words: any polish failure, unavailability, or suspected over-compression falls back to the raw transcript.
- Keep the canonicalizer as the downstream complement (jargon).

## Non-goals

- Per-recording toggle (v1 is a single global Settings flag; per-recording is future).
- Streaming/partial polish during recording (polish runs once on the final transcript at fn-release).
- Bundling a model or supporting non-FoundationModels engines (MLX/Qwen etc. — explicitly dropped; the baseline backlog's "MLX" wording is corrected to FoundationModels).
- Tuning the model to fix the residual over-compression / spoken-punctuation limits — those are deferred to the post-WWDC model re-tune (re-run the probe).
- A deterministic-only filler stripper (considered; see Alternatives).

## Constraints & assumptions

- macOS 26+, Swift 6 strict concurrency. FoundationModels API verified against the SDK swiftinterface in Stage 1.
- `SystemLanguageModel.default.availability == .available` is reachable from the app process without a special entitlement (probe-verified on this machine; re-checked at runtime).
- LLM polish is currently an explicit **Non-Goal** in `specs/baseline.md` (lines 5, 24, backlog 208). This spec's implementation MUST update `baseline.md` (Non-Goal → opt-in shipped feature; correct "MLX" → FoundationModels).
- Live insertion / erase-and-retype flash is **not** unit-testable (memory `epos-insertion-not-unit-testable`): correctness requires the installed signed app dictating into a real app. The policy logic around the model call IS unit-testable behind a seam.
- Privacy: no transcript text in diagnostic logs (`EposLogger`).
- Module size: keep `TranscriptPolisher` < ~250 LOC (CLAUDE.md).

## Requirements

R1. A persisted, default-off Settings flag `polishEnabled`.
R2. A `TranscriptPolisher` that, given the final raw transcript, returns either a polished string or the raw string, deciding via: flag on AND engine available AND polish succeeds AND output passes the content-retention guard — else raw.
R3. The model call is behind a `PolishEngine` seam (protocol) so policy logic is unit-testable with a fake; the real engine wraps FoundationModels guided generation with the Stage-1 tuned prompt + `@Generable CleanedTranscript`.
R4. `AppCoordinator` prewarms the engine at `startRecording` (when enabled+available) and, at end-of-session, replaces the raw final via `acceptFinalTranscript(polished)` (reuses canonicalize + reconcile). Live insertion during recording is unchanged.
R5. Content-retention guard: reject (keep raw) when polished is empty, or when the polished content-token sequence differs from the raw sequence after allowed filler removal and raw spoken-symbol conversion. Pure, unit-testable.
R6. A MenuBar toggle wired like the existing `launchAtLogin`/`saveAudioSamples` toggles.
R7. `baseline.md` updated to reflect the shipped opt-in feature.

## Proposed design

### Data flow (polish ON + available)
1. `startRecording`: existing setup, plus snapshot the current `settings.polishEnabled` and correction vocabulary into a per-recording `TranscriptPolisher`, then `polisher.prewarm()`.
2. During recording: unchanged — live raw partials/finals stream via `acceptPartialTranscript`/`acceptFinalTranscript`, each canonicalized + reconciled.
3. End of session (`runSession` after the event loop), where today it does `if hasTranscribedText { insertFinalTranscript(finalText) }`:
   - `let result = await polisher.polish(finalText)` → returns polished-or-raw.
   - feed `result` to `textInsertionSession.acceptFinalTranscript(result)` → canonicalize + reconcile erases-and-retypes to the final text.
   - `finishTextInsertionSession()`.
4. Polish OFF or unavailable: identical to today (`acceptFinalTranscript(finalText)`).

### Modules / seams
- `PolishEngine` (protocol): `var isAvailable: Bool { get }`, `func prewarm(knownTerms: [String])`, `func polish(_ raw: String, knownTerms: [String]) async throws -> String`.
- `FoundationModelsPolishEngine: PolishEngine` — wraps `SystemLanguageModel(useCase:.general, guardrails:.permissiveContentTransformations)`, a fresh `LanguageModelSession` per polish (stateless), the Stage-1 tuned system prompt, `@Generable CleanedTranscript { @Guide … var cleaned: String }`, `respond(to:generating:options:)` with greedy/temp-0/maxTokens 512. `isAvailable` reflects `SystemLanguageModel.default.availability == .available`. Ported from `probes/llm-polish/Sources/LLMPolishProbe/{Polish,Inputs}.swift`.
- `TranscriptPolisher` — holds `enabled`, the per-recording known terms, and a `PolishEngine`; `polish(_ raw:)` applies the gate/guard/fallback policy; owns the content-retention guard. Unit-tested with a fake engine.
- `AppCoordinator` wiring: construct a per-recording `TranscriptPolisher` (from current `settings.polishEnabled`, current correction vocabulary, and `FoundationModelsPolishEngine`), `setPolishEnabled(_:)`, prewarm at start, polish at end with the same snapshot.

### Content-retention guard (R5)
`func polishRetainsContent(raw:polished:) -> Bool`: tokenize both to lowercased word sequences, drop only recognized fillers (`um`, `uh`, `er`, `hmm`, sentence-opening `so`, filler `like`, `you know`, `I mean`, `sort of`, `kind of`, `basically`) and raw spoken-symbol tokens (`dash dash`, `open paren`, `question mark`, `slash`, `dollar`, etc.) from the raw side, then require the polished token sequence to match exactly. This rejects drops, additions, duplicate loss, and reordering. Errs toward keeping raw (safe, since fallback is the raw text).

### Polishing indicator (OQ2 resolved: show it)
The recording indicator stays visible through the polish window. Mechanism: the polish `await` happens in `runSession` while `state == .finalizing`, *before* `resetToIdle()` hides the indicator — so keeping the existing sequencing (polish → `acceptFinalTranscript` → `finish` → `resetToIdle`) means the indicator is naturally shown during polish. No new coordinator state required; a distinct "polishing" visual is optional future polish.

## Interface contracts

- `protocol PolishEngine: Sendable { var isAvailable: Bool { get }; func prewarm(knownTerms: [String]); func polish(_ raw: String, knownTerms: [String]) async throws -> String }`
- `TranscriptPolisher.polish(_ raw: String) async -> PolishResult` — never throws; returns raw on any disabled/unavailable/throw/guard-fail path; returns engine output otherwise. Empty/whitespace raw returns raw unchanged without calling the engine.
- `Settings.polishEnabled: Bool` (default false), persisted under `settings.polishEnabled`.
- `AppCoordinator.setPolishEnabled(_:)` mirrors `setSaveAudioSamples` (guard-equal, persist, log).

## Acceptance criteria

- Flag off → output identical to current raw path (no engine call).
- Flag on + unavailable → raw path; logged once.
- Flag on + available + engine throws → raw path.
- Flag on + available + over-compressed output → raw path (guard).
- Flag on + available + good output → polished text reconciled into the field; canonicalizer still applied.
- Flag on + available → recording indicator stays visible from fn-release until the polished text is reconciled (does not hide during the polish wait).
- No transcript text in logs.
- `swift build -Xswiftc -warnings-as-errors`, `swift test`, `swiftlint --quiet` all green.
- E2E (signed app): dictating a benign declarative sentence with `polishEnabled` shows raw text live, then a single erase-and-retype to the cleaned text within ~2s; toggling off reverts to today's behavior.

## Verification commands

- `swift build -Xswiftc -warnings-as-errors`
- `swift test`
- `swiftlint --quiet`
- E2E manual: `scripts/build-signed-app.sh && scripts/install-signed-app.sh && open /Applications/Epos.app` then dictate with the toggle on/off.

## Alternatives considered

- Deterministic filler stripper (no LLM): simpler, no flash/latency/content-loss risk, but cannot do context-aware mishearing correction the probe valued. Rejected as the *primary* mechanism; could be a future cheap complement.
- Plain `respond(to:)` (no guided generation): rejected — Stage 1 proved it composes/refuses/blows context.
- Per-recording toggle: deferred (future).

## Cross-cutting concerns

- Latency/UX: the erase-and-retype flash lands ~1.4s after fn-release; indicator stays visible through it (resolved above).
- Concurrency: `polish` is `async`; `TranscriptPolisher`/engine must be `Sendable`-safe; fresh session per call (no shared mutable model state).
- WWDC model swap (~2026-06-08): re-run the probe; the residual limits may clear.

## Resolved decisions

- OQ1 → strict content-token preservation guard (conservative).
- OQ2 → show the polishing indicator (keep recording indicator through the polish window via existing `.finalizing` sequencing).
- OQ3 → MenuBar toggle label "Polish dictation (on-device AI)" (default; tweakable during the UI slice).

## Implementation slices

Seams under test are public API + pure functions; the live wiring and `FoundationModelsPolishEngine.polish` model call are E2E/manual (insertion + real model not unit-testable — memory `epos-insertion-not-unit-testable`). A `FakePolishEngine` test double (configurable `isAvailable`, `result`/`throwError`, `polishCallCount`) backs S3–S8.

### S1 — Settings.polishEnabled persists
- Goal: the opt-in flag round-trips through UserDefaults and defaults off.
- Behavior under test: `save` then `load` yields the saved value; absent key → `false`.
- Seam: `Settings.load(from:)` / `save(to:)` (public).
- Boundary: an ephemeral `UserDefaults(suiteName:)`, never `.standard`.
- Files: `Sources/Epos/App/Settings.swift`, `Tests/EposTests/SettingsTests.swift`.
- Red test name: `testPolishEnabledPersistsThroughSaveAndLoad`.
- Fixture/harness: per-test ephemeral suite; `removePersistentDomain` in teardown.
- Isolation rule: no `.standard`, no shared defaults.
- Determinism rule: no clock/random in assertion.
- Assertion contract: `load(...).polishEnabled == true` after `save`; fresh suite → `false`.
- Green condition: add `polishEnabled` field, `Key`, and load/save lines.
- Refactor target: none.
- Smoke budget: none.
- Verification command: `swift test --filter SettingsTests`.

### S2 — Content-retention guard
- Goal: distinguish legit filler-removal (apply) from clause-drop (keep raw).
- Behavior under test: empty polished → false; clause-drop (probe strings) → false; filler-removal → true; spoken-symbol conversion → true; near-identical cleanup → true; additions/reordering → false.
- Seam: pure `TranscriptPolisher.polishRetainsContent(raw:polished:)` (static/pure).
- Boundary: pure string→bool; no I/O.
- Files: `Sources/Epos/Speech/TranscriptPolisher.swift`, `Tests/EposTests/TranscriptPolisherGuardTests.swift`.
- Red test name: `testGuardRejectsClauseDropAndKeepsFillerRemoval`.
- Fixture/harness: table of (raw, polished, expected) incl. `"run the script with dash dash verbose and point it at dollar home slash bin"`→`"dollar home slash bin"` (false) and `"um so like i think we should uh ship it you know"`→`"we should ship it"` (true).
- Isolation rule: pure function.
- Determinism rule: pure.
- Assertion contract: each case equals its expected bool.
- Green condition: tokenize, drop only allowed fillers and raw spoken-symbol tokens, require exact sequence equality.
- Refactor target: extract the filler set + threshold constants.
- Smoke budget: none.
- Verification command: `swift test --filter TranscriptPolisherGuardTests`.

### S3 — Disabled → raw, engine not called
- Goal: flag off skips the engine entirely.
- Behavior under test: `polish(raw)` with `enabled=false` returns raw and never calls the engine.
- Seam: `TranscriptPolisher.polish(_:)` (public, async).
- Boundary: `FakePolishEngine` (no FoundationModels).
- Files: `Sources/Epos/Speech/TranscriptPolisher.swift`, `Tests/EposTests/TranscriptPolisherTests.swift`.
- Red test name: `testPolishReturnsRawAndSkipsEngineWhenDisabled`.
- Fixture/harness: `FakePolishEngine`.
- Isolation rule: fake engine; no model, no network.
- Determinism rule: fake returns fixed value.
- Assertion contract: result == raw; `fake.polishCallCount == 0`.
- Green condition: gate on `enabled` before calling engine.
- Refactor target: none.
- Smoke budget: none.
- Verification command: `swift test --filter TranscriptPolisherTests`.

### S4 — Unavailable → raw, engine not called
- Goal: model unavailable falls back to raw.
- Behavior under test: `enabled=true`, `fake.isAvailable=false` → returns raw, `polish` not called.
- Seam: `TranscriptPolisher.polish(_:)`.
- Boundary: `FakePolishEngine`.
- Files: same as S3.
- Red test name: `testPolishReturnsRawWhenEngineUnavailable`.
- Fixture/harness: `FakePolishEngine(isAvailable:false)`.
- Isolation rule: fake engine.
- Determinism rule: fixed availability.
- Assertion contract: result == raw; `polishCallCount == 0`.
- Green condition: check `engine.isAvailable` before calling.
- Refactor target: none.
- Smoke budget: none.
- Verification command: `swift test --filter TranscriptPolisherTests`.

### S5 — Engine throws → raw
- Goal: any polish error falls back to raw, never propagates.
- Behavior under test: `enabled+available`, fake throws → returns raw.
- Seam: `TranscriptPolisher.polish(_:)`.
- Boundary: `FakePolishEngine(throwError:)`.
- Files: same as S3.
- Red test name: `testPolishReturnsRawWhenEngineThrows`.
- Fixture/harness: `FakePolishEngine` configured to throw.
- Isolation rule: fake engine.
- Determinism rule: deterministic throw.
- Assertion contract: result == raw; no thrown error escapes.
- Green condition: `do/catch` around `engine.polish`, return raw on catch.
- Refactor target: none.
- Smoke budget: none.
- Verification command: `swift test --filter TranscriptPolisherTests`.

### S6 — Over-compressed output → raw (guard wired)
- Goal: the retention guard is applied to engine output.
- Behavior under test: `enabled+available`, fake returns a clause-dropped string → returns raw.
- Seam: `TranscriptPolisher.polish(_:)` (composes S2 guard).
- Boundary: `FakePolishEngine(result: "dollar home slash bin")` for the probe raw.
- Files: same as S3.
- Red test name: `testPolishReturnsRawWhenOutputFailsRetentionGuard`.
- Fixture/harness: `FakePolishEngine`.
- Isolation rule: fake engine.
- Determinism rule: fixed result.
- Assertion contract: result == raw.
- Green condition: apply `polishRetainsContent` to engine output; raw on fail.
- Refactor target: none.
- Smoke budget: none.
- Verification command: `swift test --filter TranscriptPolisherTests`.

### S7 — Good output → polished
- Goal: the happy path applies the polished text.
- Behavior under test: `enabled+available`, fake returns a guard-passing clean string → returns that string.
- Seam: `TranscriptPolisher.polish(_:)`.
- Boundary: `FakePolishEngine(result:)`.
- Files: same as S3.
- Red test name: `testPolishReturnsPolishedWhenAvailableAndGuardPasses`.
- Fixture/harness: `FakePolishEngine`.
- Isolation rule: fake engine.
- Determinism rule: fixed result.
- Assertion contract: result == fake result; `polishCallCount == 1`.
- Green condition: return engine output when guard passes.
- Refactor target: none.
- Smoke budget: none.
- Verification command: `swift test --filter TranscriptPolisherTests`.

### S8 — Empty/whitespace raw short-circuits
- Goal: don't spend a model call on empty input.
- Behavior under test: `polish("   ")` returns the input and never calls the engine.
- Seam: `TranscriptPolisher.polish(_:)`.
- Boundary: `FakePolishEngine`.
- Files: same as S3.
- Red test name: `testPolishReturnsRawForEmptyInputWithoutCallingEngine`.
- Fixture/harness: `FakePolishEngine`.
- Isolation rule: fake engine.
- Determinism rule: deterministic.
- Assertion contract: result == input; `polishCallCount == 0`.
- Green condition: early-return on trimmed-empty raw.
- Refactor target: none.
- Smoke budget: none.
- Verification command: `swift test --filter TranscriptPolisherTests`.

### S9 — Live wiring (E2E / manual; the single allowed smoke)
- Goal: real app prewarms at start and replaces raw with polished at fn-release, indicator held through polish.
- Behavior under test: with `polishEnabled` on and the model available, dictating a benign declarative sentence shows raw live, then one erase-and-retype to the cleaned text within ~2s; indicator visible until the retype; toggling off reproduces today's behavior exactly.
- Seam: `AppCoordinator.startRecording`/`runSession` + `FoundationModelsPolishEngine` + `MenuBarView` toggle.
- Boundary: full app, real FoundationModels model, real Accessibility insertion.
- Files: `Sources/Epos/App/AppCoordinator.swift`, `Sources/Epos/Speech/{TranscriptPolisher,FoundationModelsPolishEngine}.swift`, `Sources/Epos/UI/MenuBarView.swift`, `Sources/Epos/App/Settings.swift`.
- Red test name: n/a (manual E2E — insertion + model not unit-testable).
- Fixture/harness: installed signed app (`scripts/build-signed-app.sh` + `scripts/install-signed-app.sh`).
- Isolation rule: manual; explicit smoke exemption (real model + AX by necessity).
- Determinism rule: n/a (manual observation).
- Assertion contract: observed raw→polished single retype with toggle on; unchanged behavior with toggle off.
- Green condition: wiring compiles, `swift build -Xswiftc -warnings-as-errors` green, and the manual observation holds.
- Refactor target: keep `TranscriptPolisher` < ~250 LOC; engine separate.
- Smoke budget: single allowed smoke (this slice only).
- Verification command: `scripts/build-signed-app.sh && scripts/install-signed-app.sh && open /Applications/Epos.app` then dictate with toggle on/off.

### Non-slice implementation tasks (shipped truth, no red test)
- Update `specs/baseline.md`: move LLM polish from Non-Goal (lines 5, 24) to a "Shipped Since Baseline" opt-in entry; correct backlog line 208 "MLX" → FoundationModels guided generation. Done within S9.
- Port the Stage-1 tuned prompt + `@Generable CleanedTranscript` from `probes/llm-polish/` into `FoundationModelsPolishEngine` (S9).

---

## Hardening pass (post-review) — scope, residuals, default-flip checklist

A code review + independent verifier + adversarial review workflow hardened the
polish stage so it can eventually ship on by default. The guard's contract is now:
**keep the polished text only when the same content-token sequence survives after
filler removal (plus the hyphen-merge of an already-spoken compound), with no
added `,`/`?`/`!` and no collapsed sentence boundary; reject every other change.**
A false reject is harmless (raw words kept); a false accept types altered meaning
into the user's app, so every ambiguous case rejects.

### Deliberate scope reduction (do NOT "re-add" these as missing features)
- Polish does **filler removal + capitalization/spacing + an optional trailing
  period only.** The prompt is scoped to match the guard; instructing more would
  make the guard discard the whole polish (including the filler removal).
- **Mishearing / known-term correction and spoken-symbol conversion are the
  canonicalizer's job** (`TranscriptCanonicalizer`), applied to both the raw and
  polished text so its deterministic results match on both sides. The guard does
  NOT do fuzzy word substitution (no string distance separates `epic`→`Epos` from
  `ethos`→`Epos`), and spoken `comma`/`period`/`dash`/`slash`/etc. are left as the
  words the user said — convert them by adding a canonicalizer rule, not in polish.

### Accepted harmless false-rejects (raw kept; documented, not bugs)
- `main dot py`→`main.py` and similar arbitrary spoken filenames the canonicalizer
  does not rule (the canonicalizer covers the common ones; users can add rules).
- A dictation consisting solely of a spoken-symbol word (`question mark` alone).
- A polish that keeps a period but lowercases the following word (`stop. Go`→
  `Stop. go`) — the abbreviation/version-dot heuristic can't tell it from `fig. 3`.

### Installed-app checks that gate flipping `polishEnabled` default → true
These are NOT unit-testable (need the signed app / on-device model):
1. **Insertion guard (#1, always-on):** clear a native text field mid-dictation →
   confirm NO blind backspace into adjacent content; dictate into cmux → confirm
   self-correction still works. If cmux advertises `kAXValueAttribute`, its
   self-correction degrades to append-only (safe, not corrupting) — verify which.
2. **Canonicalize-both-sides:** real `see mux…` / `dash dash verbose…` dictations
   accept and insert correctly, with no double-application.
3. **Timeout (finding 5):** does a timed-out polish return at ~2.5s, or does
   `withTaskGroup` block on a non-cancellable decode? If it blocks, reconsider
   returning at the timeout (a fresh per-call session makes an orphaned decode
   harmless).
4. **Polish quality:** filler removal + casing reads correctly across real
   dictations before flipping the default.
