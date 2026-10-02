# Epos Specs

> Keyword lookup table. Search keywords to find the right spec.

@baseline - fn key hotkey, SpeechTranscriber, push-to-talk, recording indicator, final-only guarded insertion, baseline scope, post-baseline backlog
@reliability-audit - scripts/audit, schema-1 recording outcomes, delivery readback, legacy log partition, signed-corpus error buckets, latency
@recording-stage-timing - first recognizer result, cleaned display publication, acknowledged mark, startup stages, accepted write, readback, p50 and p95
@analyzer-preparation-experiment - prepareToAnalyze, prewarming, paced saved audio, first result, memory cost, preparation decision
@intended-transcript-accuracy - ground-truth .wav WER, ASR context eval, Apple alternatives, confidence diagnostics, canonicalizer wins, dogfood residual direction
@correction-candidate-gate - scripts/correct, frozen signed transcript arm, confirmed development and holdout, zero-regression WER gate
@raw-stt-benchmark-results - raw saved .wav STT benchmark, Apple vs Whisper large-v3-turbo vs Parakeet vs IBM Granite, WER, RTFx, memory footprint
@correction-dictionary-foundation - CorrectionDictionary, CorrectionRecord, compiler-to-canonicalizer, Wispr Flow dictionary comparison, slice 1 proof/equivalence plan, future correction evidence path
