#!/bin/bash
#
# Main machine setup. Idempotent: safe to re-run anytime to converge
# a machine to the current config ("git pull && ./setup.sh").
#
# All machines are headless servers accessed over Tailscale. Roles:
#   dev  — remote development: builds, tests, evals; full dev toolchain
#   prod — Aldine production deployment; minimal tooling
# Pass the role as $1 on first run, or you'll be prompted; it is
# persisted to ~/.mac-role and reused on later runs.

set -euo pipefail
cd "$(dirname "$0")"

# --- Role ---------------------------------------------------------------
ROLE_FILE="$HOME/.mac-role"
ROLE="${1:-$(cat "$ROLE_FILE" 2>/dev/null || true)}"
while [ "$ROLE" != "dev" ] && [ "$ROLE" != "prod" ]; do
  read -rp "Machine role [dev/prod]: " ROLE
done
echo "$ROLE" > "$ROLE_FILE"
echo "==> Role: $ROLE"

eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"

echo "==> Installing packages from Brewfile"
brew bundle --file Brewfile
if [ "$ROLE" = "dev" ]; then
  brew bundle --file Brewfile.dev
fi

echo "==> macOS defaults: customisation"
# Dock: auto-hide
defaults write com.apple.dock autohide -bool true
# Stage Manager: off
defaults write com.apple.WindowManager GloballyEnabled -bool false
# Desktop widgets: hidden (both standard desktop and Stage Manager modes)
defaults write com.apple.WindowManager StandardHideWidgets -bool true
defaults write com.apple.WindowManager StageManagerHideWidgets -bool true
killall Dock &>/dev/null || true
# WindowManager changes may only fully apply after logout/restart

echo "==> macOS security"
# Application firewall on, plus stealth mode (don't answer probes/pings)
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode on
# Guest account off
sudo defaults write /Library/Preferences/com.apple.loginwindow GuestEnabled -bool false
# No password hints at the login window
sudo defaults write /Library/Preferences/com.apple.loginwindow RetriesUntilHint -int 0
# Updates: always check + download + security responses on all machines
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool true
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool true
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool true
sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool true
# macOS updates auto-install only on dev (tolerable reboots); prod applies
# them manually in a maintenance window — never surprise-reboot production
if [ "$ROLE" = "dev" ]; then
  sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool true
else
  sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
fi
# Gatekeeper: warn if someone disabled it
if ! spctl --status 2>/dev/null | grep -q "enabled"; then
  echo "    WARNING: Gatekeeper is disabled"
fi
# SSH: uncomment to require key auth once authorized_keys are deployed
# sudo tee /etc/ssh/sshd_config.d/100-cowlabs.conf >/dev/null <<'SSH'
# PasswordAuthentication no
# KbdInteractiveAuthentication no
# SSH

echo "==> Server behaviour (headless)"
# Never sleep; restart automatically after power failure or freeze
sudo pmset -a sleep 0 disksleep 0 displaysleep 10 autorestart 1 womp 1
sudo systemsetup -setrestartfreeze on
# FileVault must be OFF for unattended reboots (boot blocks on password);
# rely on physical security of the machines instead
if fdesetup status | grep -q "FileVault is On"; then
  echo "    WARNING: FileVault is ON — this machine cannot reboot unattended"
  echo "    (use 'sudo fdesetup authrestart' for manual reboots, or disable FileVault)"
fi

echo "==> Enabling Remote Login (SSH)"
if [ "$(sudo systemsetup -getremotelogin | awk '{print $NF}')" != "On" ]; then
  sudo systemsetup -setremotelogin on
fi

if [ "$ROLE" = "dev" ]; then
  echo "==> Global mise runtimes"
  mise use -g node@22 python@3.12
fi

echo "==> Tailscale"
if ! pgrep -x Tailscale &>/dev/null; then
  open -a Tailscale
  echo "    Log in via the Tailscale menu bar item, and enable 'Start on login'."
fi

echo
echo "Done. Remaining manual steps:"
echo "  - Tailscale: log in (or 'tailscale up --auth-key=...' for unattended);"
echo "    disable key expiry for this node in the admin console"
echo "  - Set a hostname: sudo scutil --set ComputerName/HostName/LocalHostName"
echo "  - Enable Screen Sharing (System Settings > General > Sharing) if wanted"
echo "  - Consider auto-login (System Settings > Users & Groups) so launchd user"
echo "    agents / GUI apps come back after an unattended reboot"
