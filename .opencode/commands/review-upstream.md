---
description: Review upstream End-4 changes for safe sync
agent: plan
subtask: true
---

Review `upstream/main` vs this fork for `$ARGUMENTS` (empty = full `git log upstream/main --not main --oneline` plus conflicting paths).

Report:

1. Upstream commits touching `dots/`, `sdata/`, or installer semantics.
2. Conflicts or overlaps with local fork changes.
3. Risk to portability, incremental update, and machine reconciliation.
4. Recommendation: what to port selectively, what to ignore, and — only if worthwhile — a sync approach (fast-forward, rebase via `exp-merge`, selective port) plus what must not be auto-merged. There is no obligation to merge.

Do not fetch, merge, rebase, or modify files without explicit approval. `git fetch upstream` requires approval.
