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
- `setup.sh` — main setup: `brew bundle`, macOS defaults, security lockdown, Siri, analytics, AirDrop and Handoff off, the bundled App Store apps removed, Google Chrome, an Aldine app that opens Aldine as a Chrome app, a Dock with Aldine, Chrome and System Settings (and Terminal on dev), the Aldine mark as the desktop picture and the user picture (images in `assets/`; the desktop picture needs a logged-in session),
  headless server behaviour, Remote Login (SSH), Tailscale, Ollama, log rotation, the Aldine settings in `~/.config/aldine/box.env`
- `rotate-logs.sh` — rotates the Aldine and Ollama logs; `setup.sh` installs it
- `Brewfile` — packages for all machines
- `Brewfile.dev` — development toolchain, dev role only, mise included
- `mise.toml` — `setup` and `update` as mise tasks, on dev machines only

## Aldine on a box

Every box runs one `box-server` binary, which serves the API and the web app on `http://localhost:5173`. A deploy from aldine installs it. `setup.sh` installs no part of Aldine itself. It writes the settings that `box-server` reads. See [Aldine settings](#aldine-settings).

A customer box has no clone of aldine, no toolchain, no mise and no deploy key. A deploy copies a release of `box-server` to it over SSH.

The dev box builds, tests and runs the CI of aldine, so it keeps a clone at `~/git/cowlabs/aldine`:

- a deploy key for the clone. See [GitHub access](#github-access).
- `mise install` and `mise run setup` — Go, Node, pnpm, buf and golangci-lint at the versions `aldine/mise.toml` pins, the pnpm dependencies and the Playwright browser. Homebrew installs mise only.
- `mise activate` added to `~/.zshrc`, so SSH sessions and the CI runner get the tools

Both roles add `brew shellenv` to `~/.zprofile`, so SSH sessions get the Homebrew tools. Verify a dev box with `cd ~/git/cowlabs/aldine && mise run build && mise run test`.

## Aldine settings

`setup.sh` writes the settings of `box-server` to `~/.config/aldine/box.env`, on both roles. The launchd agent `ai.aldine.box-server`, which a deploy installs, reads the file with `sh` each time it starts `box-server`.

- `sh` reads the file. Each setting is `KEY=value`. A value with a space, such as the backup folder, is in single quotes.
- The file has mode 600, as it holds the logo.dev key. Never put the file or a key in this repo.
- A re-run writes the settings below again. It keeps every other line, such as a comment or `ALDINE_LOG_LEVEL=debug`.
- `setup.sh` stops at the start if `sh` cannot read the file. It also stops, and keeps the file, if the new file is not valid or changes another setting.
- When a re-run changes the file, it restarts `ai.aldine.box-server` if the agent runs, so the new settings apply. The box finishes the running job first. The final check fails if the restart fails.

| Setting | Customer box | Dev box |
| --- | --- | --- |
| `ALDINE_BOX_ID` | the box name, such as `acme-1` | `dev-box` |
| `ALDINE_DEPLOY_MODE` | not set, so the debug service is off | `dev`, which turns on the debug service |
| `ALDINE_ADDR` | `127.0.0.1:5173` | `127.0.0.1:5173` |
| `ALDINE_DATA_DIR` | `$HOME/aldine`, as an absolute path | the same, or the value in `mise.local.toml` |
| `ALDINE_BACKUP_DIR` | `/Volumes/Aldine Backups`, when the box has a backup drive | the same |
| `ALDINE_LOGO_DEV_SECRET_KEY` | the logo.dev key, when you give one | the value in `mise.local.toml`, when set |
| `ALDINE_LOG_FORMAT` | `console` | `console` |
| `ALDINE_LOG_LEVEL`, `ALDINE_OLLAMA_URL` | the value in `mise.local.toml`, when set and not in box.env yet | the same |

`setup.sh` also makes the data folder, as `box-server` does not. On both roles, it ends with a check of box.env: mode 600, the box id, the deploy mode, `ALDINE_ADDR` and the data folder. A deploy of aldine reads the box id from box.env. `box-server` reads the deploy mode from it.

Boxes set up before box.env kept their settings in aldine's `mise.local.toml`. `setup.sh` reads the logo.dev key, the backup folder, `ALDINE_LOG_LEVEL` and `ALDINE_OLLAMA_URL` from it, when box.env does not have them. The dev box also reads the data folder from it. `setup.sh` prints each other `ALDINE_` setting in `mise.local.toml` that it does not carry over, such as the settings of the box watch, as `box-server` does not read them. The dev box keeps its `mise.local.toml` for the aldine tasks, such as the SSH host of the dev box. A customer box set up before keeps its clone and its deploy key. Delete both after the first deploy of a release: `rm -rf ~/git/cowlabs/aldine ~/.ssh/aldine_deploy*`, the `github.com-aldine` host in `~/.ssh/config`, and the deploy key on GitHub.

### Roll out box.env to the dev box

A deploy to the dev box reads box.env. Do the steps in this order:

1. Merge the bootstrap-mac change that writes box.env.
2. On the dev box, run `cd ~/git/cowlabs/bootstrap-mac && git pull && ./setup.sh`. It writes `~/.config/aldine/box.env` and checks it.
3. Merge aldine #275 to #279. Wait for the check of the push to main. Then run `mise run box:deploy` from a laptop. Nothing deploys on merge.

### mise tasks

On a dev machine, `mise.toml` runs this repo's scripts as tasks: `mise run setup`, `mise run update` and `mise run update-macos`. A customer box has no mise. Run `./setup.sh` and `./update.sh` there.

## Customer boxes

The `prod` role sets up a box in a customer's office. It asks for every input
at the start, then runs to the end with no other prompt:

- the box name, `<customer>-<n>` such as `acme-1`. It is the box id, the macOS
  hostname and the Tailscale machine name, and it never changes. `setup.sh`
  keeps it in `~/.mac-box-name`.
- the office wifi and its password, the fallback for the network cable.
  Leave it empty to skip.
- the logo.dev secret key, for vendor logos. Leave it empty to skip.
- the Tailscale auth key, tagged `tag:aldine-prod`, if the box is not on the
  tailnet yet.
- the backup drive and the passphrase of its volume. See
  [Backup drive](#backup-drive).

A re-run asks only for what is not set up yet.

`setup.sh` then:

- sets the hostname and the Tailscale machine name to the box name
- joins the office wifi
- makes Aldine the start page of Chrome and a bookmark. A configuration profile, `assets/chrome.mobileconfig`, blocks sign-in to a Google profile, search suggestions and usage statistics. It also makes Chrome install Aldine as an app (`WebAppInstallForceList`). A person installs the profile in System Settings, and confirms Chrome as the default browser. See [Aldine as an app](#aldine-as-an-app).
- locks the screen 5 seconds after the display sleeps. It asks for the password of the box user.
- turns off automatic macOS updates and security responses, as both can
  restart the box. With FileVault on, a restart nobody expects leaves the box
  down until someone types the password. Apply updates by hand.
- sets up the backup drive
- writes `~/.config/aldine/box.env` with the box name as `ALDINE_BOX_ID`, the logo.dev key and `ALDINE_BACKUP_DIR`. A customer box has no debug service. See [Aldine settings](#aldine-settings).

It ends with a check of each of these, of the backup volume, and of FileVault and Ollama. A failed check exits with an error: fix it, and run `./setup.sh` again. Then deploy a release to the box from your laptop, with `mise run box:deploy <tag> --box aldine@<box name>` in aldine.

Before `setup.sh`, at the machine: create the `aldine` admin account, and turn
on FileVault. Neither can be done from a script. `setup.sh` stops at the start
if FileVault is off.

## Backup drive

Aldine backs up its database and files every night at about 2am to an external
drive plugged into the box, and keeps the last 14 copies. Both roles set up the
drive, so the dev box backs up the same way as a customer box.

- `setup.sh` lists the APFS containers on external disks, and asks which one
  is the backup drive. It adds an encrypted APFS volume, `Aldine Backups`, to
  it. What the drive holds already stays. A drive that is not APFS must be
  erased as APFS first, in Disk Utility. Leave the choice empty to skip. A
  customer box needs its drive, so its final check then fails.
- FileVault covers only the Mac's own disk, so the volume has a passphrase of
  its own. Make it in 1Password first, titled `<box name> backup drive`, then
  paste it. Give a copy to the customer, as with the FileVault recovery key.
- The login keychain holds the passphrase. A launchd user agent,
  `ai.aldine.backup-volume`, unlocks and mounts the volume at login
  and every 5 minutes, so a drive that is plugged in again comes back. It logs
  to `~/Library/Logs/ai.aldine.backup-volume.log`.
- `ALDINE_BACKUP_DIR` in `~/.config/aldine/box.env` turns backups on, on both roles. `setup.sh` writes it. See [Aldine settings](#aldine-settings).
- Spotlight does not index the volume.

On a new Mac with a drive that holds backups, `setup.sh` finds the volume, and asks for its passphrase from 1Password. Then deploy a release, and restore with `mise run box:restore` in aldine.

## GitHub access

These machines never hold an account-wide GitHub credential. `gh auth login`
would grant one: OAuth scopes such as `repo` cover every repository the account
can reach, and they cannot be narrowed to one repo. `gh` is therefore not
installed. Run it from your laptop.

A customer box needs no GitHub access: it has no clone, and a deploy copies a release to it from your laptop.

On a dev box, `setup.sh` generates a **deploy key**, at `~/.ssh/aldine_deploy`, and prints the public half for you to add at [aldine → Settings → Deploy keys](https://github.com/cowlabs-xyz/aldine/settings/keys/new). Allow write access, so the machine can push. The key reaches that one repository and nothing else, and you revoke it from that same page. A deploy key must be unique across GitHub, so each machine needs its own.

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

### Tailscale comes back by itself

A box that drops off the tailnet is out of reach until someone is at its office.
A root launchd daemon, `ai.aldine.tailscale-watchdog`, checks every 2 minutes
that `tailscaled` is loaded, and loads it again if not. It logs to
`/var/log/ai.aldine.tailscale-watchdog.log`, only when it acts. launchd's
`KeepAlive` already restarts a `tailscaled` that exits. The watchdog covers one
that is unloaded, such as by `brew services stop`.

**Never run `brew services restart tailscale` over Tailscale SSH.** It stops the
daemon, which ends the session, and the start never runs. Restart it through
launchd instead, which does the restart itself:

```bash
sudo launchctl kickstart -k system/sh.brew.tailscale
```

The session drops for a few seconds. `update.sh` restarts it this way, as its
last step. To stop Tailscale on purpose, unload the watchdog first:
`sudo launchctl bootout system/ai.aldine.tailscale-watchdog`. That lasts until
the next restart or run of `setup.sh`, which load it again. To keep it off,
also run `sudo launchctl disable system/ai.aldine.tailscale-watchdog`, and
`enable` it again after.

A customer box upgrades packages only through `update.sh`, by hand. A re-run of
`setup.sh` there installs what is missing, and upgrades nothing.

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

A launchd user agent, `ai.aldine.ollama`, runs `ollama serve`. It starts at
login and restarts after a crash. It listens on `127.0.0.1:11434` only, with
`OLLAMA_FLASH_ATTENTION=1` and `OLLAMA_KV_CACHE_TYPE=q8_0`, as the Homebrew
service did. It logs to `~/Library/Logs/ai.aldine.ollama.log`.

`setup.sh` turns off Ollama's cloud features with
`{"disable_ollama_cloud": true}` in `~/.ollama/server.json`. This stops remote
inference on cloud models, and the call to ollama.com for model suggestions.
Ollama reads the file the same way as `OLLAMA_NO_CLOUD=1`.

`update.sh` does not touch Ollama. To change the version, change
`OLLAMA_VERSION` in `setup.sh` and the version in aldine's
`box-server/ollama.json` together, then run `./setup.sh` on the machine. It
installs the new version, restarts the agent, and removes the old version.

## Log rotation

Each Aldine and Ollama agent logs to `~/Library/Logs/ai.aldine.*.log`. A launchd user agent, `ai.aldine.rotate-logs`, rotates these logs, so they cannot fill the disk. The logs never leave the box.

- The agent runs `~/.local/aldine/rotate-logs.sh` every hour. `setup.sh` copies it there from this repo.
- A log rotates on the first run of each day, and when it is over 100 MB.
- A rotated log is `<log>.<yyyymmddThhmmss>.gz`, next to the log. The agent deletes it after 14 days.
- The agent copies the log, then empties it in place. It does not rename the log, because launchd opens the log once, when it starts an agent, and the agent keeps writing to that file. For the same reason, newsyslog cannot rotate these logs.
- A line that an agent writes between the copy and the truncate is lost.

To read the logs of a box from your laptop, run `mise run box:logs --box <host>` in aldine.

## Aldine as an app

Aldine opens from the Dock as an app of its own, in a window with no tabs and no address bar.

- The Chrome profile has the policy `WebAppInstallForceList` for `http://localhost:5173/`, with `default_launch_container` set to `window`. Chrome installs Aldine as an app when it runs with the profile and reaches Aldine. The manifest of the web app is `box-web/public/site.webmanifest` in aldine.
- Chrome writes the app to `~/Applications/Chrome Apps.localized/Aldine.app`. The Dock tile is that app, so the Dock shows Aldine running, not Chrome.
- `setup.sh` starts Chrome hidden when the profile is installed and the app is not, waits up to 90 seconds for the app, and closes Chrome again. It does this only when the profile has the policy and Aldine answers. Otherwise it prints what to do: install the updated profile, or deploy Aldine and run setup again.
- A setup before the first deploy skips the two checks of the app, as Chrome cannot install Aldine before it answers.
- `/Applications/Aldine.app` opens the installed app, for Launchpad and Spotlight. Before the install it opens Aldine in a Chrome window with `--app`.
- A re-run builds `/Applications/Aldine.app` again and sets the Dock tile to the installed app.

To get this on a box that is set up already:

1. Deploy a release of aldine that has the new manifest.
2. Run `./setup.sh` on the box. It opens the updated Chrome profile.
3. Install the profile in System Settings > General > Device Management: open "Aldine: Chrome" and click Install.
4. Run `./setup.sh` again. It installs the app and sets the Dock.

## Aldine app icon

`setup.sh` builds `/Applications/Aldine.app`, which opens the Aldine app that Chrome installed. Its icon follows the macOS icon style: default, dark, clear and tinted. The icon of the installed app comes from the manifest of the web app.

- `assets/aldine-icon/Aldine.icon` is the source, in the format of Icon Composer. The background is Forest `#2a3b2b`, or `#181715` in dark mode. The mark is Sage `#aac2af`.
- `assets/aldine-icon/Assets.car` and `Aldine.icns` are compiled from it. `setup.sh` copies them into the app.

To change the icon, edit the source in Icon Composer or by hand, then compile it on a Mac with Xcode, such as the dev box:

```bash
cd assets/aldine-icon && mkdir -p out
/Applications/Xcode.app/Contents/Developer/usr/bin/actool Aldine.icon --compile out \
  --platform macosx --minimum-deployment-target 26.0 --app-icon Aldine \
  --output-partial-info-plist out/partial.plist
mv out/Assets.car out/Aldine.icns . && rm -r out
```

## Manual steps after setup on a dev box

- Set a hostname with `sudo scutil --set ComputerName/HostName/LocalHostName`
- Enable auto-login, so the Ollama agent restarts after an unattended reboot.
  Ollama runs as a user agent, not a system daemon, because Metal GPU access
  needs a login session; as a root daemon it would fall back to the CPU.
- Enable Screen Sharing in System Settings → General → Sharing, if wanted

A deploy of aldine pulls the Ollama models. A customer box has FileVault on, so
it has no auto-login: after a restart, someone types the password.

No secrets belong in this repo — it is public.
