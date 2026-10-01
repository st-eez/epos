# Corrections

## Dictionary and editor

Open Corrections from the menu. Entries map heard phrases to canonical text, with
optional context phrases and Literal or Name matching mode. Add, delete, and
reorder rows, then Save Changes. Revert reloads saved rows. Restore Defaults
replaces the draft rows; saving applies that replacement. Incomplete entries
disable Save Changes.

Literal matching recognizes token boundaries and tolerates selected separators
inside a phrase. Longer aliases take precedence; rule order resolves remaining
conflicts. Context phrases constrain ambiguous matches. Name mode uses person
cues around an ambiguous alias; its optional always-safe aliases retain literal
matching. These checks are deterministic heuristics, not semantic understanding.

Built-in records include developer terms and spoken commands such as `agents dot
md`, `dot env`, `dash dash`, `slash goal`, and `dollar home`. They compile through
the same matching engine as user entries. The editor presents executable active
entries; internal record kinds also preserve metadata for disabled, suggested,
rejected, and unsupported entries.

`dash dash` followed by a flag word is a separate built-in transform. For example,
`dash dash fix` becomes `--fix`. Removing the dictionary's bare `dash dash` entry
does not disable that transform.

The coordinator snapshots compiled rules at each recording start. Those rules
clean provisional text and the final transcript. Pronounceable canonical entries
also provide best-effort recognition vocabulary; error aliases are excluded.

## Persistence

Dictionary records have stable IDs, source, kind, and status. They persist as a
versioned JSON envelope in UserDefaults. Migration retains custom rules and
disabled built-ins, updates surviving built-in definitions, and appends only
built-ins introduced after the saved version. An intentionally removed entry
from the saved version stays removed.

A newer envelope or unsupported record makes the editor read-only so this build
cannot overwrite data it cannot understand. Readable records can still compile.
Saving ordinary editor changes preserves records outside the visible rows.

## Learning and suggestions

Learn corrections defaults off. Enabling it records local raw, canonicalized,
and delivered transcript text, applied rule IDs, recording ID, and available
application and window context for an accepted final write.

For an AX-readable insertion span, Epos checks for edits after 2, 6, 12, and 15
seconds. It records the first edit accepted by a conservative filter and stops
the watch. The next recording cancels outstanding checks because later text can
no longer be attributed safely to the previous dictation. Opaque fields cannot
provide this edit evidence. The store retains at most 200 records.

Suggestions appear when Corrections reloads. Each shows a phrase replacement,
evidence count, phrase and scope risks, blockers, and an example when available.
Accept is enabled only when the assessment clears at least two distinct positive
examples, conflict, negative
example, risk, and locked corpus checks. Reject persists the resolution so the
same suggestion stays dismissed. Suggestions do not silently become active rules.

The locked baseline loads human-confirmed reference transcripts from local
recordings storage. A missing or malformed manifest blocks acceptance. The app
rechecks the live dictionary before accepting. This check protects existing
references; proving a recognition improvement on held-out audio requires the
separate signed [candidate evaluation](diagnostics.md#evaluation-tools).

## Evidence

Core code lives in
[CorrectionDictionary](../Sources/Epos/Speech/CorrectionDictionary.swift),
[TranscriptCanonicalizer](../Sources/Epos/Speech/TranscriptCanonicalizer.swift),
[CorrectionRuleCompiler](../Sources/Epos/Speech/CorrectionRuleCompiler.swift),
[CorrectionStore](../Sources/Epos/Speech/CorrectionStore.swift), and
[CorrectionsEditorView](../Sources/Epos/UI/CorrectionsEditorView.swift).
Learning uses [CorrectionEvidenceRecorder](../Sources/Epos/App/CorrectionEvidenceRecorder.swift),
[CorrectionEvidence](../Sources/Epos/Speech/CorrectionEvidence.swift), and
[CorrectionPromotionGate](../Sources/Epos/Speech/CorrectionPromotionGate.swift).

Regression coverage includes [matching](../Tests/EposTests/CorrectionSmokeTests.swift),
[compilation](../Tests/EposTests/CorrectionDictionaryCompilerTests.swift),
[persistence](../Tests/EposTests/CorrectionDictionaryPersistenceTests.swift),
[editor integrity](../Tests/EposTests/CorrectionEditorRecordIntegrityTests.swift),
[edit evidence](../Tests/EposTests/CorrectionEvidenceTests.swift),
[promotion gates](../Tests/EposTests/CorrectionPromotionGateTests.swift), and
[suggestion review](../Tests/EposTests/CorrectionSuggestionReviewTests.swift).
Real edit observation needs installed app verification.

Design context is in
[the dictionary foundation](../specs/correction-dictionary-foundation.md),
[recognition bias decision](../specs/recognition-bias-decision.md), and
[evaluation corpus](../specs/evaluation-corpus.md).
