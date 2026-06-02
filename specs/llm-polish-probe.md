# LLM Polish — Validation Probe Spec

Status: concluded · Date: 2026-05-29 · Engine: Apple FoundationModels (macOS 26 on-device `SystemLanguageModel`)

## Purpose

Decide **go/no-go** on a FoundationModels transcript-polish layer *before* any live integration, using real data instead of theory. The agreed feature shape (from discussion):

- Engine: `SystemLanguageModel.default` (OS-shared ~3B model, near-zero added RAM to Epos, on-device, free). No bundled model. Unavailable → type raw transcript.
- Leash: **"Correct, don't compose"** — fix mishearings, normalize spoken filenames/jargon, remove fillers, fix punctuation; preserve the user's words and meaning. Keep self-corrections ("no wait") **literal**.
- Insertion (Stage 2): live raw text as today, then erase-and-retype to the polished version after fn-release, via the existing guarded reconcile path.

This probe was the cheap gate. Stage 2 live integration proceeded after guided
generation passed the leash/refusal/latency checks; see `specs/baseline.md`.

## What it is / isn't

- **Is:** an offline, throwaway standalone Swift script (cf. the capitalization probe). Reads results in a terminal.
- **Isn't:** the live app. It does **not** measure the live "feel" (flash, fresh dictation, in-context latency) — that's Stage 2.
- Model-agnostic and re-runnable: WWDC 2026 (~June 8) may swap the underlying model (reportedly a distilled Gemini). This week's numbers are a **baseline**, not the final word; re-run the same script after.

## Questions it must answer (pre-registered)

1. **Leash fidelity** — does `sampling: .greedy` + tight instructions hold "correct, don't compose"? (Fixes errors, does NOT reword or change meaning, keeps self-corrections literal.)
2. **Replace vs complement** — does feeding the known-vocab list let the LLM fix private jargon (`see mux`→`CMUX`, `Stath`)? If yes, the LLM may *replace* the canonicalizer; if no, it *complements* it. (Tested via instruction variants V1 vs V2.)
3. **Refusal rate** — how often do guardrails refuse real/messy dictation, even with `.permissiveContentTransformations`? (Profanity, edgy, sensitive content.)
4. **Latency** — actual ms per call on this Mac → expected erase-and-retype flash size.

## Method

1. **Availability gate (first output).** Print `SystemLanguageModel.default.availability`. If not `.available`, report the reason (`.deviceNotEligible` / `.appleIntelligenceNotEnabled` / `.modelNotReady`) and stop. This also validates the open assumption that a **standalone script can reach the model** (FoundationModels is not TCC-permission-gated like mic/speech, so it should — but unverified). If a standalone binary can't reach `.available`, fall back to running the probe from a minimal signed harness.
2. **Session config (SDK-verified):**
   ```swift
   let model = SystemLanguageModel(useCase: .general,
                                   guardrails: .permissiveContentTransformations)
   let session = LanguageModelSession(model: model, instructions: INSTRUCTIONS)
   session.prewarm()
   let opts = GenerationOptions(sampling: .greedy, temperature: 0)
   let polished = try await session.respond(to: rawTranscript, options: opts).content
   ```
3. **Per input:** time the `respond` call; catch `GenerationError` (esp. `.guardrailViolation`, `.refusal`, `.exceededContextWindowSize`); run twice to confirm greedy determinism (identical output expected). Print raw → polished side by side, latency ms, and refusal flag.
4. **Instruction variants** (the core comparison):
   - **V1** — bare "Correct, don't compose. Fix recognition errors, spoken punctuation, and obvious filename forms (e.g. 'project dot yaml' → project.yml). Remove filler words. Do not reword, do not change meaning, do not resolve self-corrections like 'no wait' — transcribe them literally."
   - **V2** — V1 + "Known terms, prefer these exact spellings when a similar-sounding word appears: CMUX, Stath, Epos, CLAUDE.md, AGENTS.md, project.yml, /goal." (List sourced from `CorrectionStore` / `TranscriptCanonicalizer.defaultRules`.)

## Inputs

- **Real set:** re-transcribe the 6 saved `.wav`s (`~/Library/Caches/Epos/recordings`) through `SpeechTranscriber` (production preset) to get authentic raw transcripts with real mishearings (`CMOX`, `Siemux`, `yamo`, `Stas`/`stuff`). These are benign + single-sentence — they test the leash and jargon, NOT refusals or multi-sentence self-corrections.
- **Stress set (synthetic, in-script — no real PII):** hand-authored strings to exercise what the real clips can't:
  - self-corrections: "send it to bob no wait send it to alice"
  - fillers + run-ons: "um so like i think we should uh ship it you know"
  - edgy/profane/sensitive: deliberately provocative-but-benign content to probe guardrail false-positives.
  - spoken punctuation/symbols: "open paren x plus y close paren", "dash dash verbose".

## Success criteria (the user judges output by eye)

- **Leash:** on the real set, V1 removes fillers and fixes general mishearings **without rewording or changing meaning** on a strong majority; no "that's not what I meant" cases; self-corrections preserved literally.
- **Replace vs complement:** record which private-jargon fixes V2 makes that V1 can't. If V2 reliably nails `CMUX`/`Stath`, replacing the canonicalizer is on the table; otherwise the canonicalizer stays and the LLM complements it.
- **Refusals:** with `.permissiveContentTransformations`, benign-but-edgy content should **not** refuse. A non-trivial refusal rate on benign messy dictation is a red flag against the feature (silent quality cliff).
- **Latency:** report p50/p90 ms. Decision threshold = the user's tolerance for the post-release flash (rough bar: ≲2s feels acceptable; the bigger the polish diff, the bigger the flash).

## Caveats

- Underlying model may change at WWDC 2026 (~June 8); re-run the same probe after.
- A general model **cannot invent unseen private vocabulary** — only V2 (vocab-in-context) can reach private jargon. This is the whole replace-vs-complement question.
- Greedy/temperature 0 makes output deterministic but not infallible; instructions still carry the leash.
- Context window is 4096 tokens (input+output) — a non-issue for short dictation; only matters for multi-minute unbroken speech.

## Stage 2 — Live prototype follow-on

Stage 1 passed with guided generation. The resulting live integration shape:
- A `Settings` flag (opt-in) + availability gate; raw transcript when off/unavailable.
- Snapshot the toggle and correction vocabulary at `startRecording`, prewarm with that vocabulary, then on fn-release await `respond(to: finalText)` and feed polished text to the existing `ProgressiveTranscriptInsertionSession.acceptFinalTranscript` so the guarded reconcile does the erase-and-retype. No new insertion mechanism.
- This is where the user finally *feels* it (flash size, latency, real dictation). Requires the signed-app build/install loop.
- `specs/baseline.md` was updated to move LLM polish out of Non-Goals and into shipped opt-in behavior.
