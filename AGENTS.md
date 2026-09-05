# AGENTS.md — dots-hyprland fork

Personal fork of `end-4/dots-hyprland` (`origin` = this fork, `upstream` = `end-4/dots-hyprland`).
This repo is the canonical source of a personalized Hyprland environment.

## Primary goals

1. Bootstrap a new machine cleanly from this repo.
2. Adapt to different machines where necessary.
3. Update incrementally after install (no full re-run for every change).
4. Reconcile repo state with an already-installed machine safely.
5. Stay understandable, maintainable, and resilient over time.
6. Treat upstream as a source of changes to evaluate selectively, not as an authority to merge; compatibility is subordinate to fork quality.

The reference machine is evidence of desired behavior, not a canonical implementation.
Do not copy machine-local hacks verbatim; reimplement them cleanly.

## Architecture (actual)

* Entry: `./setup <subcommand>` (`install`, `install-deps|setups|files`, `uninstall`, `exp-update`, `exp-merge`, `resetfirstrun`, `checkdeps`).
* Implementation: `sdata/subcmd-<name>/`, shared helpers in `sdata/lib/`, per-distro deps in `sdata/dist-{arch,fedora,gentoo,nix}/` + `sdata/uv/`.
* Payload: `dots/` mirrors `$HOME` (`dots/.config`, `dots/.local`); `dots-extra/` holds optional overlays (`fontsets/`, `fedora/`, `via-nix/`, `fcitx5/`, …).
* Install tracking: `~/.config/illogical-impulse/installed_listfile`, `installed_true`, backups in `~/ii-original-dots-backup/`. `cache/`, `diagnose.result`, `.update-lock` are generated.
* Known customization points (not exhaustive): `hypr/custom/` loaded after `hypr/hyprland/*` by `hyprland.lua`; `hypridle.conf`/`hyprlock.conf` use `.new` backup semantics; `fish/conf.d` excluded from sync; `quickshell/ii` installs with `--delete` (high overwrite risk).

## How to change things

Prefer existing End-4 mechanisms when they are already good. Otherwise you may modify,
extend, replace, or add fork-specific code. For each change, decide explicitly:

1. Use existing mechanism as-is.
2. Extend existing mechanism.
3. Modify End-4's own implementation.
4. Introduce a new fork-specific mechanism.

Choose by maintainability, correctness, portability, and operational simplicity.
Do not force everything through `custom/` or old hooks if a cleaner level 3/4 solution exists.
Prefer evolving `setup`/`sdata`/`dots` in place; allow a new component only when it
genuinely yields a better long-term architecture, not merely to avoid touching End-4.

Classify every delta before integrating:

* `portable-default` → implement at whichever layer fits (usually `dots/`/`dots-extra/`/`sdata/`, but End-4 code, setup internals, or a new fork component when justified).
* `machine-specific` → parameterize or isolate (hostname/hardware conditional), never hardcode.
* `secret` → never commit (tokens, keys, machine IDs).
* `generated/runtime` → never commit (`cache/`, `installed_listfile`, `.qmlls.ini`, editor backups).

## Operating rules

* Do not run `./setup install`, `uninstall`, `exp-update`, `exp-merge`, `sudo`, `systemctl`, package upgrades, or any system-mutating command without explicit user approval.
* Do not edit files outside this repo (`~/.config`, `~/.local`, `/etc`) — read them as evidence only. Portable changes land in this repo.
* Do not migrate reference-machine customizations until asked; audit/read-only work is separate from integration.
* Do not commit or push unless explicitly requested.
* Verify shell changes with `bash -n` (and `shellcheck` if available); inspect `git status`/`git diff` before finishing. `./diagnose` is read-only evidence only.

## Code style

Prefer clear code, names, and structure over commentary. Do not narrate obvious code.
Comments are only for non-obvious intent, constraints, workarounds, invariants, or
important reasoning. Keep such comments brief and purposeful.
