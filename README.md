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

## Dev machines

The `dev` role additionally clones [aldine-v2](https://github.com/cowlabs-xyz/aldine-v2)
to `~/git/cowlabs/aldine-v2` and provisions it, so the machine can build and run
Aldine over SSH:

- `gh auth login` (device flow) for the private repo clone
- `mise install` — Go, Node, pnpm, buf and golangci-lint at the versions
  `aldine-v2/mise.toml` pins. Homebrew installs none of these.
- `mise run setup` — pnpm dependencies and the Playwright browser
- `mise activate` added to `~/.zshrc`, so SSH sessions get the pinned tools

Verify with `cd ~/git/cowlabs/aldine-v2 && mise run build && mise run test`.

## Manual steps after setup

- Log in to Tailscale (disable key expiry for the node in the admin console)
- Set a hostname with `sudo scutil --set ComputerName/HostName/LocalHostName`
- Enable auto-login, so the Ollama service restarts after an unattended reboot
- Pull the Ollama models the box needs: `ollama pull <model>`
- Enable Screen Sharing in System Settings → General → Sharing, if wanted

No secrets belong in this repo — it is public.
