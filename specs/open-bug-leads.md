# Open Bug Leads — Triage Handoff

Date: 2026-06-09. Author: dogfood-log triage session.

## Resolution (2026-06-09, follow-up session) — all leads closed

The evidence base of this doc was itself contaminated: `swift test` wrote through
`DiagnosticLogSink.shared` into the same `~/Library/Caches/Epos/logs/` files as the
installed app. Excluding test bursts (≥3 "audio engine created" within a few seconds),
**92% of all "insertion guard decision" lines (2,812 of 3,060) and 100% of the
"dropped undecodable record" errors were synthetic test output**, not real usage.

Per-lead outcomes:

- **#1 correction-record data loss — FALSE ALARM.** The live blob in
  `com.steez.Epos` defaults decodes 35/35 with the exact production decoder logic.
  Every error line came from `CorrectionDictionaryPersistenceTests` fixtures that
  deliberately persist a `"kind": "some-future-kind"` record to exercise the
  tolerant decode. No user corrections were ever lost.
- **#2 recording fails to start — REAL, root-caused and FIXED (two bugs).**
  All 23 real occurrences were a press before "bootstrap begin". Root cause:
  `bootstrap()` hung off `.task` on the MenuBarExtra content view, which SwiftUI
  builds only when the popover first opens — so after every launch, dictation was
  dead until the user happened to click the menu icon (the "bootstrap begin 2–5s
  after the failed press" pattern is the user clicking the icon to investigate).
  Fixes: (a) bootstrap now starts from `AppCoordinator.init` at launch (completes
  in ~160ms, verified live); (b) a press landing inside that window now latches
  (`pendingStartAwaitingBootstrap`) and replays at bootstrap completion if fn is
  still held, mirroring the finalize-window latch. Not a stale-format/sleep issue —
  all 40 logged bootstraps produced a format. Tests: `CoordinatorBootstrapLatchTests`.
- **#3/#4 guard drops — ~92% SYNTHETIC.** Real residue after excluding test bursts:
  98 cmux `emptyExposed` + 6 Teams `caretMismatch` (both covered by the committed
  fixes `3fa8c39`/`5634fbf`), 5 `focusChanged`, 2 `positionedTextMismatch`. Nothing
  actionable remains.
- **#5 zero-output sessions — NOT A BUG.** All 74 real `finalChars=0` recordings
  were under 1.4s: accidental fn taps, `hadInput=false` or `results=0`. No speech
  was lost.

The contamination itself is fixed: `DiagnosticLogConfiguration.load` now disables
the file sink when the environment marks a test process (`SWIFT_TESTING_ENABLED`
under `swift test`, `XCTest*` keys under Xcode). When mining logs written **before
2026-06-09**, still exclude test bursts first.

The original doc follows for the record. Its counts are pre-decontamination —
do not re-triage from them.

---

Purpose: a starting map for a fresh session to auto-review and fix bugs. Every lead
below is **evidence-backed** by the app's own diagnostic logs (12 days of real usage),
not speculation. Investigate from the evidence; do not trust this doc over the code.

## The method (use this first)

The single highest-signal bug finder in this codebase is the **on-disk diagnostic log**,
not reading source. Two real bugs this session were found in the logs; the one hypothesis
formed by reading code alone was wrong. Start every investigation in the logs.

```sh
LOGDIR="$HOME/Library/Caches/Epos/logs"   # TSV: timestamp <TAB> level <TAB> category <TAB> message

# error-level events by subsystem (unambiguous failures):
rg --no-filename -e "\t(error|fault)\t" "$LOGDIR"/*.log \
  | sed -E 's/^[^\t]*\t//; s/[0-9a-f]{8}/<id>/g; s/[0-9]+/N/g' | sort | uniq -c | sort -rn

# insertion-guard outcomes (each abort/abortAppend = a dictation that was dropped/curtailed):
rg --no-filename "insertion guard decision" "$LOGDIR"/*.log | awk '{
  for(i=1;i<=NF;i++){ if($i ~ /^action=/) a=$i; if($i ~ /^reason=/) r=$i; if($i ~ /^app=/) p=$i }
  print a"\t"r"\t"p }' | sort | uniq -c | sort -rn
```

Diagnostic logs redact transcript text by default; relaunch the app with
`EPOS_DIAGNOSTIC_TRANSCRIPT_TEXT=1` to see the actual words when a lead needs them.

## Already fixed this session (do NOT redo) — uncommitted, pending runtime confirmation

Both are in `Sources/Epos/Inject/`. Tests in `Tests/EposTests/InsertionTargetGuardTests.swift`.

1. **Teams (`com.microsoft.teams2`) caretMismatch drop.** Electron compose boxes expose a
   *stale* AX caret, so after word one the guard returned `.abort` (caretMismatch) and
   cancelled — every later word dropped. Fix: in `ProgressiveTranscriptInsertion.reconcile`,
   a guard `.abort` now latches do-no-harm append-only instead of cancelling **when
   `target.verifiesFocusIdentity()` is true**. Tests: `testIdentityPinnedAppendSurvivesStaleElectronCaretRead`, `testIdentityPinnedDeleteRevisionLatchesAppendOnlyOnStaleCaret`.
2. **cmux (`com.cmuxterm.app`) "slash goal" → "SL" strand.** cmux advertises `kAXValue` but
   never returns content; an empty read was misclassified `.emptyExposed` (append-only), so
   a revised early partial could neither be backspaced nor corrected. Fix: `InsertionTargetObservation.read`
   now keys an empty read on `hasReflectedTextValue()` (has the field ever returned our text)
   instead of `exposesTextValue()` (merely advertises) → cmux reads `.notRead` and self-corrects.
   Test: `testAdvertisedButNeverReflectedTargetSelfCorrectsRevisedPartial`.

Both verified green (`swift test`: 277 pass) and by an independent verifier (mutation test).
Still need live runtime confirmation: dictate "slash goal" into cmux, and a sentence into Teams.

---

## Prioritized open leads

### P1 — unambiguous `error`-level failures (start here)

**1. Correction dictionary silently drops saved rules on load. [HIGH]**
- Evidence: `error corrections` × **96** — `correction dictionary dropped N undecodable record(s) on load`.
- Impact: the user's saved corrections (the app's core value-add) are being **silently
  lost** on load. This is data loss in the feature the whole product is built around.
- Where: `Sources/Epos/Speech/CorrectionStore.swift`, `CorrectionDictionary.swift`,
  `CorrectionRuleCompiler.swift`, `CorrectionDictionaryAppliedRules.swift` (Codable persistence,
  likely a `UserDefaults` key).
- Investigate: why are persisted records undecodable? Schema/format change without migration?
  Partial write? An optional/enum that stopped decoding? Find the source and stop dropping
  (migrate or version the records). Reproduce by grepping the 96 lines for the record count `N`
  over time — is it growing (ongoing loss) or a one-time legacy blob?

**2. Recording sometimes fails to start. [HIGH]**
- Evidence: `error coordinator` × **24** — `cannot start: capture format unavailable (bootstrap incomplete?)`.
- Impact: user presses fn, gets **no dictation at all**.
- Where: `Sources/Epos/Audio/AudioCapture.swift`, `Sources/Epos/App/AppCoordinator.swift`
  (`startRecording` path).
- Investigate: what is the "capture format" and when is it unavailable — a startup race
  (fn pressed too soon after launch) or a rapid start/stop teardown race? Correlate the 24
  timestamps with the preceding `recording start`/launch events. Fix is likely lazy-init,
  await-format-ready, or a one-shot retry.

### P2 — drop-the-dictation guard paths (same family as the two fixes above)

**3. `abortAppend reason=positionedTextMismatch` × 240 (+ `emptyExposed` × 79, `suffixMismatch` × 48). [MEDIUM–HIGH]**
- Impact: `abortAppend` = a pure append was **cancelled** → rest of the dictation dropped.
  This is the same shape as the Teams caretMismatch bug, via a different reason code.
- Where: `ProgressiveTranscriptInsertion.reconcile` pure-append branch (the
  `case .stopAppendOnly, .abort:` that calls `cancel()`), and `InsertionTargetGuardDiagnostics.evaluate`.
- Investigate: group these by `app=`. For identity-pinned / same-field cases, should they
  latch do-no-harm append-only (like the caretMismatch fix) instead of cancelling? Be careful:
  the abort is the *last* wrong-field backstop when identity is NOT verified — only soften
  where same-field identity is proven. Confirm whether real user words are being dropped.

**4. `abort reason=focusChanged` × 241 (+ `skipRetract focusChanged` × 76). [MEDIUM]**
- Impact: whole session aborts. Some are legitimate (user really moved focus); the question
  is **false positives** that abort while focus never left the field.
- Where: `AXInsertionTargetObserver.focusChangedSinceStart()` in `InsertionTargetGuard.swift` —
  the "focused element unreadable mid-session → treat as changed" path, the pid check, the
  `CFEqual` same-element check (can misfire on element-handle churn, the original cmux problem),
  and the opaque focus-signature path.
- Investigate: group by `app=`; if one app over-triggers, it's likely a false-positive class.

### P3 — open-ended (lower confidence, needs a scan)

**5. Transcriber/coordinator anomalies.** `info transcriber` has ~21.9k lines, `info coordinator`
~9.2k. Scan for: sessions ending `hadInput=true` but `finalChars=0` (spoke, got nothing),
results streams completing with 0 results, finalize/polish outliers, suspicious state-machine
transitions. Files: `Speech/Transcriber.swift`, `App/AppCoordinator.swift`.

**6. Latent code bugs in churned modules** (not yet seen in logs). Audit
`Inject/ProgressiveTranscriptInsertion.swift`, `Inject/InsertionTargetGuard.swift`,
`Speech/Transcriber.swift`, `Audio/AudioCapture.swift`, `App/AppCoordinator.swift` for
concurrency/actor-isolation hazards, UTF-16/index boundary errors, and trapping force-casts.

## Suggested order

Start with **#1 (correction-record data loss)** — it's an `error`-level, silently corrupts
the app's core feature, and is self-contained (Codable persistence) rather than entangled with
the AX insertion guard. Then **#2** (no-dictation startup failure). Then the P2 guard drops
(#3, #4), which need the same care as this session's fixes (soften only with proven identity).
