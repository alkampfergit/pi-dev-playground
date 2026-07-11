---
description: Review one local file with a chosen focus
argument-hint: "<path> [focus]"
---
TEMPLATE-MARKER: REVIEW-FILE

Review the local file at `$1`.
Focus on: `${2:-correctness and edge cases}`.

Return exactly these sections:

## Findings
## Suggested checks

Do not modify files. If the path is empty or cannot be read, say so clearly.
