#!/bin/bash
#
# Bootstrap a new Mac. Run with:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/cowlabs-xyz/bootstrap-mac/main/bootstrap.sh)"
#
# Installs Homebrew, clones this repo, then hands off to setup.sh.
# Idempotent: re-run anytime to pull the latest config and re-converge.

set -euo pipefail

REPO_URL="https://github.com/cowlabs-xyz/bootstrap-mac.git"
DEST="$HOME/git/cowlabs/bootstrap-mac"

# --- Homebrew (its installer also installs Xcode Command Line Tools) ---
if ! command -v brew &>/dev/null; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"

# --- Clone (or update) this repo, then hand off ---
if [ -d "$DEST/.git" ]; then
  git -C "$DEST" pull --ff-only
else
  mkdir -p "$(dirname "$DEST")"
  git clone "$REPO_URL" "$DEST"
fi

exec "$DEST/setup.sh"
