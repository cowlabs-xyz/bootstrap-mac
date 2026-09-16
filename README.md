# bootstrap-mac

Bootstrap new Mac devices for Aldine.

## New machine

Open Terminal and run:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/cowlabs-xyz/bootstrap-mac/main/bootstrap.sh)"
```

This installs Homebrew (and Xcode Command Line Tools), clones this repo to
`~/git/cowlabs/bootstrap-mac`, and runs `setup.sh`, which prompts for the
machine's role: `dev` (remote development: builds, tests, evals) or `prod`
(Aldine production deployment). The role is persisted to `~/.mac-role`.

## Converge an existing machine

Re-run the same one-liner, or:

```bash
cd ~/git/cowlabs/bootstrap-mac && git pull && ./setup.sh
```

Everything is idempotent.

## What's in here

- `bootstrap.sh` — curl-able entry point (Homebrew + clone + hand-off)
- `setup.sh` — main setup: `brew bundle`, macOS defaults, security lockdown,
  headless server behaviour, Remote Login (SSH), Tailscale
- `Brewfile` — packages for all machines
- `Brewfile.dev` — development toolchain, dev role only

## Manual steps after setup

- Log in to Tailscale from the menu bar item (enable "Start on login")
- Enable Screen Sharing in System Settings → General → Sharing, if wanted
- Sign in to the App Store before uncommenting the `mas` entries in the Brewfile

No secrets belong in this repo — it is public.
