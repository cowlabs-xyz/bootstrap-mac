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
# `systemsetup -setremotelogin` refuses to run without Full Disk Access, which
# only a person at the GUI or an MDM profile can grant. Enable the sshd
# LaunchDaemon directly instead: launchd needs no such privilege.
if sudo launchctl print system/com.openssh.sshd &>/dev/null; then
  echo "    already on"
else
  sudo launchctl enable system/com.openssh.sshd || true
  sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true
  if sudo launchctl print system/com.openssh.sshd &>/dev/null; then
    echo "    on"
  else
    echo "    FAILED to enable Remote Login. Turn it on by hand:"
    echo "      System Settings > General > Sharing > Remote Login"
    echo "    Or grant Full Disk Access to Terminal (System Settings > Privacy &"
    echo "    Security > Full Disk Access), then: sudo systemsetup -setremotelogin on"
  fi
fi

echo "==> Ollama"
# User-level service, so models live in ~/.ollama. Needs a login session:
# enable auto-login (see manual steps) so it survives an unattended reboot.
brew services list | grep -qE "^ollama +started" || brew services start ollama

if [ "$ROLE" = "dev" ]; then
  echo "==> Aldine toolchain"
  # Activate mise in the login shell, so SSH sessions get the pinned tools
  if ! grep -q "mise activate" "$HOME/.zshrc" 2>/dev/null; then
    echo 'eval "$(mise activate zsh)"' >> "$HOME/.zshrc"
  fi
  ALDINE_DIR="$HOME/git/cowlabs/aldine-v2"
  DEPLOY_KEY="$HOME/.ssh/aldine_deploy"
  SSH_ALIAS="github.com-aldine"

  # A deploy key reaches aldine-v2 and nothing else, so this machine holds no
  # account-wide GitHub credential. It lives behind a Host alias, so plain
  # github.com stays free for a forwarded agent (ssh -A) to serve.
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  if [ ! -f "$DEPLOY_KEY" ]; then
    ssh-keygen -t ed25519 -f "$DEPLOY_KEY" -N "" -C "aldine-deploy-$(hostname -s)"
  fi
  if ! grep -q "^Host $SSH_ALIAS\$" "$HOME/.ssh/config" 2>/dev/null; then
    cat >> "$HOME/.ssh/config" <<EOF

Host $SSH_ALIAS
  HostName github.com
  User git
  IdentityFile $DEPLOY_KEY
  IdentitiesOnly yes
EOF
    chmod 600 "$HOME/.ssh/config"
  fi

  # Wait until the public key is registered on the repo
  until ssh -T -o StrictHostKeyChecking=accept-new "git@$SSH_ALIAS" 2>&1 |
    grep -q "successfully authenticated"; do
    echo
    echo "    Add this deploy key to aldine-v2, with write access:"
    echo "    https://github.com/cowlabs-xyz/aldine-v2/settings/keys/new"
    echo
    cat "$DEPLOY_KEY.pub"
    echo
    read -rp "    Press enter once it is added: "
  done

  if [ ! -d "$ALDINE_DIR/.git" ]; then
    mkdir -p "$(dirname "$ALDINE_DIR")"
    git clone "git@$SSH_ALIAS:cowlabs-xyz/aldine-v2.git" "$ALDINE_DIR"
  fi
  # mise refuses to run an untrusted config file
  mise trust "$ALDINE_DIR/mise.toml"
  # Go, Node, pnpm, buf and golangci-lint at the versions the repo pins,
  # then pnpm deps and the Playwright browser
  (cd "$ALDINE_DIR" && mise install && mise run setup)
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
echo "  - Enable auto-login (System Settings > Users & Groups) so the Ollama"
echo "    service and other user agents come back after an unattended reboot"
echo "  - Pull the Ollama model(s) this box needs: ollama pull <model>"
if [ "$ROLE" = "dev" ]; then
  echo "  - Verify the toolchain: cd ~/git/cowlabs/aldine-v2 && mise run build && mise run test"
fi
