---
description: Plan a portable integration for a customization
agent: plan
---

Plan integration of `$ARGUMENTS` into this fork. Do not implement yet.

1. State the desired behavior and evidence (repo path, machine path, `file:line`).
2. Choose an implementation level per `AGENTS.md`: (1) use existing mechanism, (2) extend it, (3) modify End-4 code, (4) new fork-specific mechanism. Justify by maintainability, correctness, portability, operational simplicity.
3. Specify placement at whichever layer fits (`dots/` vs `dots-extra/` vs `sdata/` vs End-4 code vs a justified new fork component), install semantics (`sync` vs `soft-backup` vs `skip-if-exists`), machine-specific isolation, and upstream-sync impact.
4. List verification: `bash -n`, `shellcheck` if available, `git status/diff`; never `./setup install` or edits outside the repo without explicit approval.
