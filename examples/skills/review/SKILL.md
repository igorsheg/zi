---
name: review
description: Review the current code changes for correctness, regressions, and missing tests.
---

# Review

1. Inspect `git status` and the complete diff.
2. Read the changed code and its callers before judging behavior.
3. Run the narrowest relevant tests when available.
4. Report findings in severity order with exact file paths and line numbers.
5. If there are no findings, say so and name any testing gaps.

Do not modify files unless the user asks for fixes.
