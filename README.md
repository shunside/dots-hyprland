# dots-hyprland

Personal fork of [end-4/dots-hyprland](https://github.com/end-4/dots-hyprland).
End-4, except I gave a bunch of AI agents permission to touch things.

I run this on my own machines and work on it for fun, mainly to make my
desktop less annoying. Sometimes this works disturbingly well.

## Why a fork

I had several machines with hand-edited End-4 configs drifting apart in
`~/.config`, and no record of why any of it existed. The point of this repo
is to turn those mystery edits into real, reusable changes — or delete them.

Upstream is genuinely useful, but its internals are not sacred. If the clean
fix means changing End-4 code instead of working around it, that's what
happens here.

## How it's built

Most of the fork-specific code is written by AI agents through OpenCode.
I decide what we're changing and test whatever comes out the other end on
actual hardware.

Hence `AGENTS.md` and `.opencode/`.

`AGENTS.md` has the boring details.

## What's different so far

Keyboard/Input, in Settings → Keyboard:

- Layout picker with real names, variants, and expert options — no manual
  Hyprland edits.
- Shortcuts follow the symbols in your active layout (verified for bare
  `us`/`tr`, reported as unverified otherwise).
- Hardware keys: press a special key to see what Hyprland actually gets,
  then bind the unbound ones to real actions or a custom command.
- Ordinary shortcuts don't belong there — captured chords point at
  `~/.config/hypr/custom/keybinds.lua`, and custom binds show up in the
  cheatsheet.
- Some laptop buttons (screen-share, lock, …) arrive exactly like typing
  those chords, so there's no safe way to give them their own action.
  They keep doing whatever the chord does.

## Install

```sh
./setup install          # full install: deps, setups, files
./setup install-files    # configs only
./diagnose               # read-only system report
```

`dots/` mirrors `$HOME`; machine differences are parameterized, not hardcoded.

## Updates

A machine this repo has adopted stays synchronized with it — no reinstalling:

```sh
./setup update            # apply the latest fork revision
./setup update --dry-run  # preview what would change, change nothing
./setup                   # the short version: what you can do from here
```

`update` only touches fork-managed files. User- and runtime-owned state
is left alone, and anything locally different that needs a human call
stops and asks (via `decide`) instead of being overwritten quietly.
`./setup commands` lists everything else, including the lower-level
deployment and recovery tools.

Arch is the environment actually being tested. Other distros exist as
best-effort overlays.

## Upstream & license

- Upstream: [end-4/dots-hyprland](https://github.com/end-4/dots-hyprland),
  docs at [ii.clsty.link](https://ii.clsty.link).
- Desktop foundation by end-4 and illogical-impulse contributors.
- GPL-3.0 — see [LICENSE](./LICENSE); third-party copies in [`licenses/`](./licenses/).
