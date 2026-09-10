# This script is meant to be sourced by ./setup (subcommand: commands).
# It's not for directly running.
#
# Full command inventory for discovery. The landing screen (`./setup`)
# stays concise; everything lives here. Read-only.

# shellcheck shell=bash

# Styles come from sdata/lib/environment-variables.sh under real ./setup;
# default them for direct sourcing (same degradation as non-TTY output).
: "${STY_BOLD:=}" "${STY_FAINT:=}" "${STY_RST:=}"

echo -e "${STY_BOLD}Everyday:${STY_RST}
  update         Update this machine to the fork target revision.
                 Example: ${SETUP_CMD_NAME:-$0} update
  install        (Re)Install illogical-impulse (first-time setup or repair).

${STY_BOLD}Update control (advanced):${STY_RST}
  plan           Show the pending update as a table (read-only).
  decide         Record keep/replace/install choices for flagged paths.
  adopt          Baseline a machine for safe updates (first time only).
  apply          Run a fully-decided deployment; resume/abort recovery.

${STY_BOLD}Installer pieces:${STY_RST}
  install-deps   Step 1: install dependencies.
  install-setups Step 2: permissions, services, and similar setup.
  install-files  Step 3: copy config files.
  resetfirstrun  Reset firstrun state.
  uninstall      Uninstall illogical-impulse.

${STY_BOLD}Legacy:${STY_RST}
  exp-update     Update without fully reinstalling (superseded by update
                 for fork-managed machines).
  exp-merge      Merge upstream changes with local configs using git rebase.

${STY_BOLD}Development:${STY_RST}
  virtmon        Create virtual monitors for testing multi-monitors.
  checkdeps      Check whether packages exist in Arch repos or the AUR.

${STY_BOLD}Meta:${STY_RST}
  help           Show the concise landing screen (same as bare \`$0\`).
  commands       Show this inventory.

Details per command: ${SETUP_CMD_NAME:-$0} <subcommand> -h
${STY_FAINT}Note: the old ./install.sh, ./update.sh, and ./uninstall.sh
are now ./setup install, ./setup exp-update, and ./setup uninstall.${STY_RST}
"
exit 0
