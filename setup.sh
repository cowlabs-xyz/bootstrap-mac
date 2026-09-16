#!/bin/bash
#
# Main machine setup. Idempotent: safe to re-run anytime to converge
# a machine to the current config ("git pull && ./setup.sh").

set -euo pipefail
cd "$(dirname "$0")"

eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"

echo "==> Installing packages from Brewfile"
brew bundle --file Brewfile

echo "==> Applying macOS defaults"
# Key repeat: fast, no press-and-hold accent popup
defaults write NSGlobalDomain KeyRepeat -int 2
defaults write NSGlobalDomain InitialKeyRepeat -int 15
defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool false
# Finder: show extensions, path bar
defaults write NSGlobalDomain AppleShowAllExtensions -bool true
defaults write com.apple.finder ShowPathbar -bool true
# Screenshots to ~/Screenshots instead of Desktop
mkdir -p "$HOME/Screenshots"
defaults write com.apple.screencapture location -string "$HOME/Screenshots"
killall Finder SystemUIServer &>/dev/null || true

echo "==> Enabling Remote Login (SSH)"
if [ "$(sudo systemsetup -getremotelogin | awk '{print $NF}')" != "On" ]; then
  sudo systemsetup -setremotelogin on
fi

echo "==> Global mise runtimes"
if command -v mise &>/dev/null; then
  mise use -g node@22 python@3.12
fi

echo "==> Tailscale"
if ! pgrep -x Tailscale &>/dev/null; then
  open -a Tailscale
  echo "    Log in via the Tailscale menu bar item, and enable 'Start on login'."
fi

echo
echo "Done. Remaining manual steps:"
echo "  - Tailscale: log in (or 'tailscale up --auth-key=...' for unattended)"
echo "  - System Settings > General > Sharing: enable Screen Sharing if wanted"
