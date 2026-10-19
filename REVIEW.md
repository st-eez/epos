# Epos review

## Deep

`Sources/Epos/Inject/` is production code that authorizes writes into other
applications. Changes require Deep review, including target identity, focus
changes, composition ownership, and suppression of duplicate writes.

## Evidence

Use the checks in [development](docs/development.md). Distinguish simulated
Accessibility failures from live host failures, and native input-method delivery
from keystroke delivery. A successful focus lookup alone does not establish that
a recorded utterance reached its destination.
