---
description: Audit reference machine vs repo and classify deltas
agent: dots-auditor
subtask: true
---

Compare `dots/` (plus relevant `dots-extra/`, `sdata/`) against the installed reference machine (`~/.config`, `~/.local/share`, `~/.local/state/quickshell`).

Scope filter: `$ARGUMENTS` (empty = all; otherwise only matching paths).

Output a table: repo path | machine path | delta | classification (`portable-default` | `machine-specific` | `secret` | `generated/runtime`) | note.

Rules:

- Read-only, no migration, no edits.
- `secret` rows name the key only, never values.
- Treat the machine as evidence, not canonical.
- End with items needing an explicit level 1–4 decision per `AGENTS.md`.
