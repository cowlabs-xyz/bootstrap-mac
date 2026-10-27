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

## Keep a machine current

```bash
cd ~/git/cowlabs/bootstrap-mac && ./update.sh
```

Pulls this repo, upgrades Homebrew packages and, on `dev`, the Aldine
toolchain. Whatever a machine hasn't got is skipped and listed, so this runs
before `setup.sh` as well as after. macOS updates are listed but not installed
unless you pass `--macos`, which reboots.

## What's in here

- `bootstrap.sh` — curl-able entry point (Homebrew + clone + hand-off)
- `update.sh` — routine updates: this repo, Homebrew, the toolchain, macOS
- `setup.sh` — main setup: `brew bundle`, macOS defaults, security lockdown,
  headless server behaviour, Remote Login (SSH), Tailscale, Ollama
- `Brewfile` — packages for all machines
- `Brewfile.dev` — development toolchain, dev role only
- `mise.toml` — `setup` and `update` as mise tasks, dev machines only

## Dev machines

The `dev` role additionally clones [aldine](https://github.com/cowlabs-xyz/aldine)
to `~/git/cowlabs/aldine` and provisions it, so the machine can build and run
Aldine over SSH:

- a deploy key for the clone (see below)
- `mise install` — Go, Node, pnpm, buf and golangci-lint at the versions
  `aldine/mise.toml` pins. Homebrew installs none of these.
- `mise run setup` — pnpm dependencies and the Playwright browser
- `mise activate` added to `~/.zshrc`, so SSH sessions get the pinned tools

Verify with `cd ~/git/cowlabs/aldine && mise run build && mise run test`.

`mise` also wraps this repo's own scripts, so both are driven the same way:
`mise run setup`, `mise run update` and `mise run update-macos`. Only dev
machines install `mise`; elsewhere run the scripts directly.

## GitHub access

These machines never hold an account-wide GitHub credential. `gh auth login`
would grant one: OAuth scopes such as `repo` cover every repository the account
can reach, and they cannot be narrowed to one repo. `gh` is therefore not
installed. Run it from your laptop.

Instead `setup.sh` generates a **deploy key** per machine, at
`~/.ssh/aldine_deploy`, and prints the public half for you to add at
[aldine → Settings → Deploy keys](https://github.com/cowlabs-xyz/aldine/settings/keys/new).
Allow write access so the machine can push. The key reaches that one repository
and nothing else, and you revoke it per machine from that same page. A deploy
key must be unique across GitHub, so each machine needs its own.

The key sits behind an SSH host alias, so it never competes with a forwarded
agent:

```
Host github.com-aldine        # the deploy key, IdentitiesOnly
Host github.com               # untouched: a forwarded agent serves this
```

The Aldine remote is therefore `git@github.com-aldine:cowlabs-xyz/aldine.git`.

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

## Tailscale

Machines join the tailnet as **tagged nodes**, not as your user account. A
tagged node belongs to its tag, so it survives any change to a person's account,
and its key never expires. An untagged node is owned by whoever logged it in.

Define the tags once in the tailnet policy file:

```json
"tagOwners": {
  "tag:aldine-dev":  ["your-user@example.com"],
  "tag:aldine-prod": ["your-user@example.com"]
}
```

Then create a reusable auth key carrying `tag:aldine-dev` or `tag:aldine-prod`
at [the admin console](https://login.tailscale.com/admin/settings/keys), and
give it to `setup.sh`:

```bash
TS_AUTHKEY=tskey-auth-... ./setup.sh dev
```

`setup.sh` prompts for the key if the variable is not set. **Never commit an
auth key. This repo is public.**

Tailscale runs as a system daemon (`sudo brew services start tailscale`), so it
connects at boot with no login session. This is the open source `tailscale`
formula rather than the GUI cask, because only that variant serves Tailscale SSH
on macOS.

### Tailscale SSH

`setup.sh` runs `tailscale up --ssh`, so SSH access is granted by the tailnet
policy file rather than by `authorized_keys`. Nothing needs distributing to each
machine. Add a rule such as:

```json
"ssh": [
  {
    "action": "accept",
    "src":    ["autogroup:member"],
    "dst":    ["tag:aldine-dev", "tag:aldine-prod"],
    "users":  ["autogroup:nonroot"]
  }
]
```

Native Remote Login stays enabled as a fallback, so a Tailscale outage does not
lock you out of a machine on the local network.

## Remote Login and Full Disk Access

`systemsetup -setremotelogin` fails without Full Disk Access, which no script can
grant itself — only a person at the GUI or an MDM profile can. `setup.sh`
therefore enables the `com.openssh.sshd` LaunchDaemon through `launchctl`, which
carries no such requirement.

If that ever fails, turn Remote Login on by hand in System Settings → General →
Sharing. Run the first setup at the machine itself, since SSH is not available
until this step succeeds.

## Ollama

Ollama is the official release build, `ollama-darwin.tgz` from
[the GitHub releases](https://github.com/ollama/ollama/releases), at the
version that `OLLAMA_VERSION` in `setup.sh` pins. `setup.sh` checks the tarball
against the release's `sha256sum.txt`, unpacks it into
`~/.local/ollama/<version>`, and links `/usr/local/bin/ollama` to it.

It is not the Homebrew formula. Homebrew builds Ollama with no network, so the
build lacks `libollama_xgrammar.dylib` (Ollama downloads xgrammar while it
builds). Models that run on MLX, such as Qwen 3.5 and Gemma 4, then answer every
request for structured output with HTTP 501
([Homebrew/homebrew-core#302645](https://github.com/Homebrew/homebrew-core/issues/302645)).
The release tarball ships the library. It is not the Mac app either, nor
`install.sh`, which installs the app: the app checks for updates every hour and
sends a device ID. `setup.sh` removes the formula from a machine that still has
it, and keeps the models in `~/.ollama`.

A launchd user agent, `xyz.cowlabs.ollama`, runs `ollama serve`. It starts at
login and restarts after a crash. It listens on `127.0.0.1:11434` only, with
`OLLAMA_FLASH_ATTENTION=1` and `OLLAMA_KV_CACHE_TYPE=q8_0`, as the Homebrew
service did. It logs to `~/Library/Logs/xyz.cowlabs.ollama.log`.

`setup.sh` turns off Ollama's cloud features with
`{"disable_ollama_cloud": true}` in `~/.ollama/server.json`. This stops remote
inference on cloud models, and the call to ollama.com for model suggestions.
Ollama reads the file the same way as `OLLAMA_NO_CLOUD=1`.

`update.sh` does not touch Ollama. To change the version, change
`OLLAMA_VERSION` in `setup.sh` and the version in aldine's
`ops/box/ollama.json` together, then run `./setup.sh` on the machine. It
installs the new version, restarts the agent, and removes the old version.

## Manual steps after setup

- Set a hostname with `sudo scutil --set ComputerName/HostName/LocalHostName`
- Enable auto-login, so the Ollama agent restarts after an unattended reboot.
  Ollama runs as a user agent, not a system daemon, because Metal GPU access
  needs a login session; as a root daemon it would fall back to the CPU.
- Pull the Ollama models the box needs: `ollama pull <model>`
- Enable Screen Sharing in System Settings → General → Sharing, if wanted

No secrets belong in this repo — it is public.
