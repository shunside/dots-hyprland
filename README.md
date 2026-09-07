# dots-hyprland (shunside fork)

[![Hyprland](https://img.shields.io/badge/window%20manager-Hyprland-44464f)](https://hypr.land)
[![Quickshell](https://img.shields.io/badge/shell-Quickshell-44464f)](https://quickshell.org)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)](./LICENSE)

A personalized, independently maintained Hyprland desktop environment, based on
[end-4/dots-hyprland](https://github.com/end-4/dots-hyprland) (illogical-impulse).

> This is **not** an official End-4 distribution. It is a personal fork:
> End-4 is the upstream base we evaluate and borrow from — not an authority
> we track. When the best maintainable solution means changing End-4
> internals, we change them.

## Design philosophy

| Principle | Meaning |
|---|---|
| Fork is canonical | This repository is the source of truth, not any single machine. |
| Machines are deployment targets | Laptops/desktops receive this repo's state via `./setup`; machine differences are parameterized, never hardcoded. |
| Correctness over compatibility | Upstream compatibility is useful but subordinate to correctness and maintainability. |
| Incremental updates | After install, day-to-day changes reconcile without full re-runs. |

See [AGENTS.md](./AGENTS.md) for the working contract (change levels, delta classification, operating rules).

## What's implemented here

### Keyboard / Input (completed)

User-facing keyboard configuration in Settings → Keyboard, without hand-editing Hyprland files:

- **Layout picker** — human-readable XKB layouts (`Turkish (tr)`), per-layout variants, and an expert options field; draft → validate → Apply with reload, plus Reset-to-stock. State persists in `~/.config/illogical-impulse/config.json`; generated Hyprland config is reconciled at boot.
- **Semantic shortcut compatibility** — shortcuts follow the symbols shown in the active layout (verified for bare `us`/`tr`); anything else is reported as typing-supported but shortcut-unverified, never silently broken.
- **Hardware-key discovery** — press a special key and see what Hyprland actually receives (keycode, press/release counts, existing binding), including honest handling of firmware-macro chords and keys that never arrive.
- **Hardware-key assignment** — bind observable, unbound raw keycodes (`code:255`-class) to a small catalog of real End-4 actions (screenshot, recording, volume/mic, brightness, media, lock, launcher) or a custom shell command; enable/disable/remove apply immediately.
- **Shortcut guidance** — ordinary chords captured in Hardware Keys redirect to `~/.config/hypr/custom/keybinds.lua` (with copy-path affordance) instead of becoming shadow bindings. Firmware-macro remapping is deliberately out of scope: those buttons arrive through the same path as typed chords and cannot be separated safely.

Implementation lives in `dots/.config/quickshell/ii/modules/settings/InputConfig.qml`,
`dots/.config/quickshell/ii/scripts/hyprland/{input-layout-apply,hwkeys-apply}`,
`dots/.config/hypr/hyprland.lua` (generated-file loader), and the matching services.
Per-machine intent stays in the (uncommitted) local `config.json`; generated
`~/.config/hypr/custom/*-generated.lua` files are reconciled, never hand-edited.

## Installation / deployment reality

```sh
./setup install          # full (re)install: deps, setups, files
./setup install-files    # copy configs only
./setup checkdeps        # dependency check (Arch)
./diagnose               # read-only system report (writes diagnose.result, git-ignored)
```

<details>
<summary>Subcommands and notes</summary>

- `install-deps` / `install-setups` / `install-files` run individual install stages.
- `uninstall`, `resetfirstrun`, `virtmon`, `checkdeps` cover removal, first-run reset, virtual monitors, and AUR checks.
- `exp-update` / `exp-merge` are experimental; there is no finished updater/rollback system yet — updates today mean `git stash && git pull` followed by `./setup install`.
- `dots/` mirrors `$HOME`; `dots-extra/` holds optional overlays; `sdata/` holds per-distro (`arch`, `fedora`, `gentoo`, `nix`) and subcommand implementation.

</details>

Primary target is Arch Linux; other distros exist as best-effort overlays. Hardware support is per-machine and incremental — no universal-compatibility claims.

## Relationship to upstream

- Upstream: [end-4/dots-hyprland](https://github.com/end-4/dots-hyprland) — documentation at [ii.clsty.link](https://ii.clsty.link).
- This fork treats upstream as a source of changes to evaluate selectively. Deltas are classified (`portable-default`, `machine-specific`, `secret`, `generated/runtime`) before integration; machine-local hacks are reimplemented cleanly, never copied verbatim.
- Upstream code retains its own license notices; copies live under [`licenses/`](./licenses/).

## Status / roadmap

- [x] Keyboard/Input: layout management, semantic shortcuts, hardware-key discovery + assignment, guidance, cheatsheet integration
- [ ] Broader machine coverage as new hardware arrives (selectively, per above)
- [ ] Incremental update/rollback tooling (planned, not built)

## Credits & license

- Desktop shell, widgets, and dotfiles foundation: [end-4](https://github.com/end-4) and illogical-impulse contributors (see upstream for full credits).
- Fork-specific Keyboard/Input work and maintenance: shunside.
- This repository is licensed under the GPL-3.0 — see [LICENSE](./LICENSE); third-party license copies live in [`licenses/`](./licenses/).
