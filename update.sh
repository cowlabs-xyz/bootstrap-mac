#!/bin/bash
#
# Keep a machine current. Idempotent, and safe to re-run anytime:
#   ./update.sh          — packages, and this repo's own config
#   ./update.sh --macos  — also install macOS software updates
#
# This is the routine counterpart to setup.sh: setup.sh converges a machine to
# the config in this repo, update.sh moves the config forward. Run setup.sh
# after this if a pull brought new setup steps.
#
# Every step is optional: this runs on a machine setup.sh has never touched,
# doing what it can and naming what it skipped.

set -euo pipefail
cd "$(dirname "$0")"

MACOS=false
[ "${1:-}" = "--macos" ] && MACOS=true

SKIPPED=()
skip() { SKIPPED+=("$1"); echo "    skipped: $1"; }

# Is this session arriving over the tailnet? Tailscale hands out 100.64.0.0/10,
# so the SSH client address says so. Restarting tailscaled or rebooting cuts
# such a session — and takes this script down with it.
over_tailnet() {
  local ip="${SSH_CONNECTION%% *}"
  [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]
}

ROLE="$(cat "$HOME/.mac-role" 2>/dev/null || true)"
if [ "$ROLE" = "dev" ] || [ "$ROLE" = "prod" ]; then
  echo "==> Role: $ROLE"
else
  ROLE=""
  echo "==> Role: none — this machine has not run ./setup.sh"
fi

echo "==> This repo"
if [ -d .git ] && git remote get-url origin &>/dev/null; then
  git pull --ff-only
else
  skip "no git remote to pull from"
fi

echo "==> Homebrew"
BREW=""
for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  [ -x "$candidate" ] && BREW="$candidate" && break
done
if [ -n "$BREW" ]; then
  eval "$("$BREW" shellenv)"
  brew update
  brew upgrade
  brew cleanup -s
  brew autoremove
else
  skip "Homebrew not installed — run ./bootstrap.sh"
fi

echo "==> Aldine toolchain"
ALDINE_DIR="$HOME/git/cowlabs/aldine"
if [ "$ROLE" != "dev" ]; then
  skip "dev machines only: a deploy updates a prod box"
elif [ ! -d "$ALDINE_DIR/.git" ]; then
  skip "aldine not cloned — run ./setup.sh"
else
  # Tool versions are pinned in the repo's mise.toml, so the update is a pull
  # plus a re-install: never `mise upgrade`, which would drift off the pins.
  (cd "$ALDINE_DIR" && git pull --ff-only && mise install && mise run setup)
fi

# Restart tailscaled last, so its new binary runs. launchd itself does the
# restart, so a session over the tailnet that drops during it cannot cut it
# halfway, as `brew services restart` can. The session drops for a few seconds:
# reconnect. A macOS update restarts the machine anyway, so it skips this.
restart_tailscaled() {
  if [ "$MACOS" = true ] || ! sudo launchctl print system/sh.brew.tailscale &>/dev/null; then
    return
  fi
  echo "==> Restarting tailscaled"
  if over_tailnet; then
    echo "    This session drops now. Reconnect in a few seconds."
    trap "" HUP
  fi
  sudo launchctl kickstart -k system/sh.brew.tailscale
}

echo "==> macOS software updates"
if [ "$MACOS" = true ]; then
  # A machine with FileVault on stops at the pre-boot password prompt, where it
  # has no network: nobody remote can reach it again. setup.sh keeps FileVault
  # off for exactly this reason, so refuse rather than strand the machine.
  if fdesetup status | grep -q "FileVault is On"; then
    echo "    FileVault is ON — a reboot would halt at the pre-boot prompt with"
    echo "    no network, and this machine would not rejoin the tailnet."
    echo "    Reboot it by hand instead: sudo fdesetup authrestart"
    exit 1
  fi
  # The install runs for minutes and the connection may not outlive it, so
  # ignore SIGHUP: losing the session should not leave macOS half-installed.
  trap "" HUP
  echo "    This closes the session. The machine rejoins the tailnet on boot:"
  echo "    tailscaled is a system daemon and the node's tagged key never expires."
  # On Apple silicon a full macOS update needs a volume owner to authorise it;
  # add --user/--stdinpass if an update ever installs nothing over SSH.
  sudo /usr/sbin/softwareupdate -i -a --restart
else
  skip "listing only; pass --macos to install"
  softwareupdate -l 2>&1 | sed 's/^/    /' || true
fi

echo
if [ ${#SKIPPED[@]} -eq 0 ]; then
  echo "Done."
else
  echo "Done, with ${#SKIPPED[@]} step(s) skipped:"
  printf '  - %s\n' "${SKIPPED[@]}"
fi
restart_tailscaled
