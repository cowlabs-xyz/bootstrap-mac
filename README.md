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

- a deploy key for the clone (see below)
- `mise install` — Go, Node, pnpm, buf and golangci-lint at the versions
  `aldine-v2/mise.toml` pins. Homebrew installs none of these.
- `mise run setup` — pnpm dependencies and the Playwright browser
- `mise activate` added to `~/.zshrc`, so SSH sessions get the pinned tools

Verify with `cd ~/git/cowlabs/aldine-v2 && mise run build && mise run test`.

## GitHub access

These machines never hold an account-wide GitHub credential. `gh auth login`
would grant one: OAuth scopes such as `repo` cover every repository the account
can reach, and they cannot be narrowed to one repo. `gh` is therefore not
installed. Run it from your laptop.

Instead `setup.sh` generates a **deploy key** per machine, at
`~/.ssh/aldine_deploy`, and prints the public half for you to add at
[aldine-v2 → Settings → Deploy keys](https://github.com/cowlabs-xyz/aldine-v2/settings/keys/new).
Allow write access so the machine can push. The key reaches that one repository
and nothing else, and you revoke it per machine from that same page. A deploy
key must be unique across GitHub, so each machine needs its own.

The key sits behind an SSH host alias, so it never competes with a forwarded
agent:

```
Host github.com-aldine        # the deploy key, IdentitiesOnly
Host github.com               # untouched: a forwarded agent serves this
```

The Aldine remote is therefore `git@github.com-aldine:cowlabs-xyz/aldine-v2.git`.

### Agent forwarding for everything else

For work beyond Aldine — other repos, other hosts — forward your laptop's agent
rather than putting more keys on the machine:

```bash
ssh -A dev-box
```

Nothing is stored on the box and access ends with the session. `sshd` allows
agent forwarding by default, so no server-side change is needed. Make it
automatic from your laptop's `~/.ssh/config`:

```
Host dev-box prod-box
  ForwardAgent yes
```

Forward the agent only to machines you trust: root on the far end can use it
while you are connected.

## Remote Login and Full Disk Access

`systemsetup -setremotelogin` fails without Full Disk Access, which no script can
grant itself — only a person at the GUI or an MDM profile can. `setup.sh`
therefore enables the `com.openssh.sshd` LaunchDaemon through `launchctl`, which
carries no such requirement.

If that ever fails, turn Remote Login on by hand in System Settings → General →
Sharing. Run the first setup at the machine itself, since SSH is not available
until this step succeeds.

## Manual steps after setup

- Log in to Tailscale (disable key expiry for the node in the admin console)
- Set a hostname with `sudo scutil --set ComputerName/HostName/LocalHostName`
- Enable auto-login, so the Ollama service restarts after an unattended reboot
- Pull the Ollama models the box needs: `ollama pull <model>`
- Enable Screen Sharing in System Settings → General → Sharing, if wanted

No secrets belong in this repo — it is public.
