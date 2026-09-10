# dots-hyprland

<!--
README MAINTENANCE CONTRACT

This README is a product overview and entry point, not a changelog.

When adding or substantially changing a user-visible fork feature:

1. Update "What's different so far".
   - Every major user-facing feature belongs there as its own subsection.
   - Describe capabilities and behavior, not implementation history.
   - Group related work under the existing feature instead of appending
     another unrelated section.
   - Do not let the first feature added to the repo become the implicit
     structure for everything that follows.

2. Keep workflow/reference sections separate from feature descriptions.
   - "Install" explains how to install.
   - "Updates" explains how to use the update workflow.
   - Future workflow sections should serve the same purpose.
   - Do not duplicate the full feature description in these sections.

3. Preserve the README's voice.
   - Concise, informal, technically precise, slightly opinionated.
   - Avoid corporate/product-marketing language and AI-generated filler.
   - Prefer a few useful bullets over long prose.
   - Do not turn the README into internal architecture documentation.

4. Maintain hierarchy instead of endlessly appending.
   - Reuse, rename, merge, or reorganize existing sections when the repo
     grows.
   - A new feature does not automatically deserve a new top-level heading.
   - Keep the document easy to scan as the number of features increases.

5. Document what exists now.
   - Do not use the README as a roadmap or development log.
   - Internal mechanisms, implementation slices, tests, manifests,
     fingerprints, transaction details, etc. belong elsewhere unless the
     user needs to know about them to use the repo.

6. Commands must stay consistent with the actual CLI.
   - When user-facing commands or their roles change, update the relevant
     examples and descriptions here.
   - `./setup` is the normal discovery entry point.
   - `./setup commands` is the complete command inventory.
   - Do not promote legacy/internal commands as the normal workflow.

Before editing this README, read the whole document and place information
according to this structure rather than simply appending text.
-->

Personal fork of https://github.com/end-4/dots-hyprland.
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

### Keyboard & input

Settings → Keyboard handles most of the things I used to have scattered
through Hyprland config:

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

### Updates & setup CLI

The fork has its own deployment path instead of relying on repeated full
End-4 installs or hand-copying configs between machines:

- `./setup update` brings an adopted machine to the current fork revision
  through the normal update path.
- Updates only write fork-managed state. Machine/user-owned state stays
  outside that ownership boundary.
- Unexpected local differences are not silently overwritten. The update
  stops and asks for a decision when it cannot safely choose by itself.
- Updates are previewable with `./setup update --dry-run`, and deployments
  use the same guarded snapshot/recovery machinery underneath.
- `./setup` is the short, everyday entry point. `./setup commands` exposes
  the complete command set, including lower-level inspection and recovery
  tools.
- The same workflow is available from any directory as `impulse` (a
  launcher setup installs into `~/.local/bin`): `impulse update` runs the
  same flow as `./setup update` from the repo checkout.

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
impulse update            # apply the latest fork revision
impulse update --dry-run  # preview what would change, change nothing
impulse commands          # everything else this setup system can do
```

From inside the repo checkout, `./setup` works the same
(`./setup update`, `./setup commands`, …).

`update` only touches fork-managed files. User- and runtime-owned state
is left alone, and anything locally different that needs a human call
stops and asks instead of being overwritten quietly.

Arch is the environment actually being tested. Other distros exist as
best-effort overlays.

## Upstream & license

- Upstream: [end-4/dots-hyprland](https://github.com/end-4/dots-hyprland),
  docs at [ii.clsty.link](https://ii.clsty.link).
- Desktop foundation by end-4 and illogical-impulse contributors.
- GPL-3.0 — see [LICENSE](./LICENSE); third-party copies in [`licenses/`](./licenses/).
