# Evaluation Corpus

`scripts/corpus` creates the provenance ledger for the saved Epos recording
corpus. It reads recordings and the legacy manifest but never changes either.

## Frozen migration

The migration is bound to:

- all `347` original regular `.wav` files by privacy-safe membership digest;
- exactly `114` unique legacy manifest rows;
- legacy manifest SHA-256
  `85a0ed532a232afe20df37a05c8d973cbe890300547bbb868ab97127b7f68bc1`;
- legacy ordinals `1...35` as `human_confirmed`;
- legacy ordinals `36...114` as `inferred`;
- the other current `233` recordings as `unlabeled`.

Additional recordings are allowed and enter the ledger as `unlabeled`. The
checked-in `evaluation-corpus-frozen-recordings.sha256` contains no filenames,
paths, audio, or transcripts. Each sorted line is:

```text
SHA256(UTF8(filename) + NUL + ASCII(lowercase audio SHA256))
```

Every frozen digest must match a current filename and its current audio bytes.
This detects a deleted or changed original even if a new recording keeps the
total count at 347 or higher.

The later 79 legacy transcripts were inferred from recognizer and correction
output. They are useful candidate text, but they are not human truth. Only
`human_confirmed` rows may be used as reference transcripts for WER or for
claiming an accuracy improvement. `inferred` and `unlabeled` rows may be used
for diagnostics, review prioritization, and hypothesis discovery.

## Generate

```sh
scripts/corpus
```

The default output is
`.build/evals/evaluation-corpus-v2.jsonl`. Each current WAV appears exactly once
with:

- `schemaVersion: 2`;
- its safe basename in `file`;
- the current audio content digest in `audioSHA256`;
- the legacy text in `transcriptCandidate`, or `null` when unlabeled;
- `verificationStatus`;
- its one-based `legacyOrdinal`, or `null` when unlabeled.

Output order is deterministic by filename. Existing output is preserved unless
`--replace` is passed.

The generator fails closed if the legacy artifact changes, a label is malformed,
duplicated, or stale, a frozen membership digest is missing, fewer than 347
recordings remain, a WAV is not a regular file, a filename is unsafe, or output
resolves inside the recordings directory. New recordings do not silently become
accuracy truth: they are included with a null transcript and `unlabeled` status.

Run the isolated behavioral checks with:

```sh
scripts/corpus --test
```

## Holdout confirmation

The 35 legacy confirmed rows are the only human truth the frozen migration
carries, and they were used to develop the correction layer. Claiming an
accuracy improvement needs references that development never saw, so
`scripts/confirm` freezes a 40-recording holdout and records the transcript the
operator confirms by listening.

**A confirmed holdout row must never be used for correction development.** It
exists to compare models and to verify claims. Tuning aliases, thresholds, or
prompts against it destroys the only untouched reference set there is.

### Selection

The pool is every `unlabeled` recording. `inferred` rows were the historical
correction-tuning arm, so they are contaminated as a holdout and are never
selected. Selection is deterministic and depends on nothing but the corpus and
the audio:

1. read each pooled recording's duration from its RIFF header (Epos writes
   48 kHz mono 32-bit float, which the Python `wave` module cannot open);
2. rank by duration and cut three equal terciles;
3. within each tercile, rank by filename — filenames are recording timestamps,
   so this is chronological order — and cut four quartiles;
4. apportion 40 picks across the twelve cells by integer largest-remainder,
   ties resolved by cell order;
5. inside a cell, order members by `audioSHA256` and take the apportioned
   count, which spreads picks instead of clustering them on consecutive
   utterances.

### Freeze

The selection is written once to `holdout-selection.json` in the recordings
directory with its pool size, source corpus digest, and a `selectionSHA256`
over the picks. Later runs load that file; they never recompute. Editing it by
hand breaks the digest and is rejected. `--reselect` recomputes, and refuses
once any confirmation exists.

Regenerating the ledger changes the corpus digest. That is reported as a note,
not a failure: the holdout stands as long as every frozen pick still exists
with unchanged audio. A pick whose bytes changed is a hard failure.

### Confirming

```sh
scripts/confirm --plan   # print the selection and exit, writing nothing
scripts/confirm          # freeze, then listen and confirm
```

Each recording plays through `afplay`. The current production-pipeline
transcript is shown as an explicit candidate, prefilled from the newest
`reviewable*`/`unlabeled*` context replay artifact in `.build/evals` and only
where the artifact's `audioSHA256` still matches the recording. Enter accepts
the candidate, typed text replaces it, `r` replays, `s` skips, `q` quits.
Quitting is safe: a rerun resumes at the first unconfirmed recording.

A candidate never silently becomes truth. Every row in
`holdout-confirmations.jsonl` records the candidate that was shown, its source
artifact, and whether the operator edited it. Rows append by rewriting the
whole file through a temporary file, so an interrupted write cannot corrupt
earlier confirmations. The recording's `audioSHA256` is re-verified against the
actual bytes before anything is written.

Transcripts stay out of the repository: both files live in the recordings
directory alongside the audio.

### Ledger integration

`scripts/corpus` reads `holdout-confirmations.jsonl` when it is present. A
confirmed recording becomes `human_confirmed` with a null `legacyOrdinal`,
`designation: "holdout"`, and the confirmation source and schema version. Its
`transcriptCandidate` holds the confirmed transcript, which is what
`scripts/audit` joins on to call a signed eval row verified.

The merge fails closed: a confirmation whose audio digest no longer matches,
whose recording is missing, or whose recording is also labeled by the legacy
manifest stops the build.

`scripts/corpus_reader.py` accepts a `human_confirmed` row in exactly two
shapes — a legacy ordinal in `1...35`, or a null ordinal with holdout
designation and confirmation provenance. The frozen ordinal-set invariants are
unchanged: legacy confirmed ordinals must still be exactly `1...35` and
inferred exactly `36...114`. `schemaVersion` stays `2` because the new fields
are optional additions that leave every existing row byte-identical; an older
reader meeting a holdout row rejects it rather than misreading it.

```sh
scripts/confirm --test
```
