# bootstrap-mac

Bootstrap new Mac devices for Aldine.

## New machine

Open Terminal and run:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/cowlabs-xyz/bootstrap-mac/main/bootstrap.sh)"
```

This installs Homebrew (and Xcode Command Line Tools), clones this repo to
`~/git/cowlabs/bootstrap-mac`, and runs `setup.sh`.

## Converge an existing machine

Re-run the same one-liner, or:

```bash
cd ~/git/cowlabs/bootstrap-mac && git pull && ./setup.sh
```

Everything is idempotent.

## What's in here

- `bootstrap.sh` — curl-able entry point (Homebrew + clone + hand-off)
- `setup.sh` — main setup: `brew bundle`, macOS defaults, Remote Login (SSH),
  mise global runtimes, Tailscale
- `Brewfile` — declarative package list (CLI tools, apps)

## Manual steps after setup

- Log in to Tailscale from the menu bar item (enable "Start on login")
- Enable Screen Sharing in System Settings → General → Sharing, if wanted
- Sign in to the App Store before uncommenting the `mas` entries in the Brewfile

No secrets belong in this repo — it is public.
