---
description: Map a dots-hyprland subsystem without modifying anything
agent: dots-auditor
subtask: true
---

Map subsystem `$ARGUMENTS` in this repo (e.g. `hypr`, `quickshell/ii`, `sdata/subcmd-install`).

Report concisely:

1. Repo paths involved (`dots/`, `dots-extra/`, `sdata/`).
2. Entry points and how files flow to the installed system (`$XDG_CONFIG_HOME`, `$XDG_DATA_HOME`).
3. Install mode per path (`sync`, `soft-backup`, `skip-if-exists`, excluded) and overwrite risk.
4. Known customization points and upstream coupling.

Read-only. Do not propose changes.
