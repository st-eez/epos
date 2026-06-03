# Ollama Polish Lever Files

This directory is for focused lever notes created during the local Ollama polish
optimization goal.

Do not pre-create speculative lever files. The goal agent should create a lever
file only when it has verified enough current-state evidence to name a concrete
hypothesis.

## File Naming

Use:

```text
L<sequence>-<short-slug>.md
```

Examples:

- `L1-baseline-measurement.md`
- `L2-prompt-shape.md`
- `L3-request-options.md`

## Lever File Template

```md
# L<sequence> <Lever Name>

Status: open

## Why This Lever Exists

Verified evidence or observation that made this lever worth pulling.

## Hypothesis

The falsifiable claim being tested.

## Read When Pulling This Lever

- Minimal source/test/spec files needed for this lever.

## Evidence Needed

- JSONL artifacts, commands, row counts, examples, resource checks, or tests
  required to decide this lever.

## Attempts

### YYYY-MM-DD

- Change:
- Commands:
- Results:
- Manual inspection:
- Decision:
- Follow-up:

## Decision

open
```
