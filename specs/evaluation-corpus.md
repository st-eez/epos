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
