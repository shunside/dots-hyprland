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

7. Document behavior users didn't explicitly invoke.
   - If setup installs, generates, or links something as a side effect
     of another command, say where users will encounter it, not how it
     is implemented.

7. Document lifecycle behavior users didn't explicitly invoke.
   - If setup installs, generates, or links something as a side effect
     of another command, say where users will encounter it, not how it
     is implemented.

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

Installing also links the `impulse` command, so later runs work from
anywhere without revisiting the checkout.

`dots/` mirrors `$HOME`; machine differences are parameterized, not hardcoded.

## Updates

A machine this repo has adopted stays synchronized with it — no reinstalling:

```sh
impulse update            # apply the latest fork revision
impulse update --dry-run  # preview what would change, change nothing
impulse commands          # everything else this setup system can do
```

From inside the repo checkout, `./setup` works the same
(`./setup update`, `./setup commands`, …). The first successful
`adopt` or `update` also installs the `impulse` launcher itself, so
later runs work from anywhere.

The launcher is a symlink in `~/.local/bin` plus per-shell `PATH`
integration, all project-owned and reversible: a fish drop-in
(`~/.config/fish/conf.d/impulse-path.fish`), and one hook line in
`~/.bashrc`, `~/.profile`, and — when zsh is installed — `~/.zshrc` /
`~/.zprofile`, sourcing one owned env file. Bash login uses whichever of
`~/.bash_profile`, `~/.bash_login`, `~/.profile` it would read first, so a
pre-existing login file never suppresses the integration. Every new shell
picks it up with no reload or restart (the shell you ran the install from
needs a fresh session). Uninstall removes only what it owns; anything
else is left alone. Nushell is not auto-managed (no interpreter here to
validate against) — manually prepend `~/.local/bin` to its `PATH` once.

`update` only touches fork-managed files. User- and runtime-owned state
is left alone, and anything locally different that needs a human call
stops and asks instead of being overwritten quietly. A machine already at
the target answers steady-state runs immediately; anything changed since
the last verified run takes the full evaluation path again.

> [!NOTE]
> `impulse update` checks your branch's tracking remote for the latest
> revision first. Fully offline instead with `impulse update --at HEAD`.

### One-time bridge for checkouts older than the updater handoff

Checkouts that predate the self-update handoff cannot bootstrap
themselves: their updater fetches the latest revision but has no code to
run it with, so `update` may report "Already up to date" while the
`impulse` launcher is still missing. That wording describes the payload,
not the updater itself. If that is your machine, run once from anywhere (same in Bash and Fish):

```sh
git -C ~/Projects/dots-hyprland fetch origin main
git -C ~/Projects/dots-hyprland show FETCH_HEAD:sdata/lib/update-bridge.sh > /tmp/ii-bridge.sh
bash /tmp/ii-bridge.sh --repo ~/Projects/dots-hyprland
```

The bridge fetches (remote-tracking refs only, like `update`), then tries
to fast-forward your branch to the fetched target — this refuses rather
than harms, so dirty, diverged, and local-ahead checkouts stay exactly as
they are. On a clean checkout the branch advances and the checkout's own
updater finishes the job, including the launcher. Otherwise the target
revision's updater still runs pinned to deploy payload and launcher, and
tells you how to finish migrating after reconciling the branch. Either
way nothing is reset, and afterwards plain `impulse update` stays current
by itself: every update executes the target revision's updater, so no
future checkout needs this bridge again.

### Adopting a machine

Adoption records what a machine looks like against one fork revision —
which files match, which drifted, which are missing. It changes nothing;
it just gives every future update an honest baseline to compare against:

```sh
./setup adopt              # preview the baseline, change nothing
./setup adopt --apply      # record it
```

Coming from stock End-4? Clone this repo next to your setup and adopt.
Your files stay where they are; `impulse update --dry-run` then shows
exactly what the fork would change before anything moves.

### When files differ

| Situation | Choices |
|---|---|
| You changed a file the fork also changed | `replace` (take fork version) or `keep` (leave mine) |
| The fork dropped a file you still have | `accept-removal` or `reinstall` |
| The fork wants to delete a file you changed | `delete` or `keep` |
| The fork added a file you don't have | `install` or `preserve-absence` |

```sh
impulse decide --set path=choice [...]  # record choices
impulse decide --list                   # review them
```

Choices stick to the exact state you decided on; edit the file
afterwards and the update just asks again.

<details>
<summary>Advanced controls, offline use, and recovery</summary>

- `impulse plan` shows the full pending-change table behind the summary.
- `impulse apply --preflight` checks every gate without applying.
  `--resume ID` / `--abort ID` recover an interrupted run;
  `--break-lock` clears a dead lock file only (never transaction state).
- `impulse adopt --status` reports baseline health.
- Fully local or offline: `impulse update --at HEAD` never touches the
  network. With no tracking branch configured, a bare `update` says so
  and uses the local checkout.

</details>

Arch is the environment actually being tested. Other distros exist as
best-effort overlays.

## Upstream & license

- Upstream: [end-4/dots-hyprland](https://github.com/end-4/dots-hyprland),
  docs at [ii.clsty.link](https://ii.clsty.link).
- Desktop foundation by end-4 and illogical-impulse contributors.
- GPL-3.0 — see [LICENSE](./LICENSE); third-party copies in [`licenses/`](./licenses/).
