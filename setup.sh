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
#
# A prod box is a customer box. It asks for every input at the start, then
# runs to the end with no other prompt, and ends with a check of what it set up.

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

ALDINE_DIR="$HOME/git/cowlabs/aldine"
ALDINE_LOCAL="$ALDINE_DIR/mise.local.toml"

# --- Inputs -------------------------------------------------------------
# Every input comes first, so the rest runs with nobody at the keyboard. A
# re-run asks only for what is not set up yet.
echo "==> Inputs"
sudo -v
# Keep sudo valid until the script ends, so a long step does not stop at a
# password prompt with nobody there.
while kill -0 "$$" 2>/dev/null; do sudo -n true; sleep 50; done 2>/dev/null &
SUDO_KEEPALIVE=$!
trap 'kill "$SUDO_KEEPALIVE" 2>/dev/null || true' EXIT

# The box name, such as acme-1, is the box id, the macOS hostname and the
# Tailscale machine name. It never changes, even after a wipe.
BOX_NAME_FILE="$HOME/.mac-box-name"
BOX_NAME=""
WIFI_SSID=""
WIFI_WANT=""
WIFI_PASSWORD=""
LOGO_DEV_KEY=""
if [ "$ROLE" = "prod" ]; then
  # A customer box holds the customer's data, so FileVault is on before setup.
  # Turning it on needs a person at the machine, so the script stops here.
  if ! fdesetup status | grep -q "FileVault is On"; then
    echo "    FileVault is off. Turn it on first, in System Settings > Privacy &"
    echo "    Security > FileVault, and give the recovery key to the customer."
    echo "    Then run ./setup.sh again."
    exit 1
  fi

  BOX_NAME="${BOX_NAME:-$(cat "$BOX_NAME_FILE" 2>/dev/null || true)}"
  until [[ "$BOX_NAME" =~ ^[a-z][a-z0-9]*-[0-9]+$ ]]; do
    read -rp "    Box name, <customer>-<n> such as acme-1: " BOX_NAME
  done
  echo "$BOX_NAME" > "$BOX_NAME_FILE"
  echo "    box name: $BOX_NAME"

  # The network cable comes first. The office wifi is the fallback.
  WIFI_DEVICE="$(networksetup -listallhardwareports | awk '/^Hardware Port: Wi-Fi$/ { getline; print $2 }')"
  WIFI_FILE="$HOME/.mac-wifi"
  if [ -n "$WIFI_DEVICE" ]; then
    WIFI_SSID="$(cat "$WIFI_FILE" 2>/dev/null || true)"
    if [ -n "$WIFI_SSID" ] && networksetup -listpreferredwirelessnetworks "$WIFI_DEVICE" | sed 's/^[[:space:]]*//' | grep -qxF "$WIFI_SSID"; then
      echo "    wifi: $WIFI_SSID, already saved"
      WIFI_SSID=""
    else
      read -rp "    Office wifi name (empty to skip): " WIFI_SSID
      WIFI_WANT="$WIFI_SSID"
      if [ -n "$WIFI_SSID" ]; then
        read -rsp "    Password of $WIFI_SSID: " WIFI_PASSWORD
        echo
      fi
    fi
  fi

  # The key for vendor logos. It goes in aldine's mise.local.toml, never in this
  # public repo.
  LOGO_DEV_KEY="$(sed -n 's/^ALDINE_LOGO_DEV_SECRET_KEY = "\(.*\)"$/\1/p' "$ALDINE_LOCAL" 2>/dev/null || true)"
  if [ -n "$LOGO_DEV_KEY" ]; then
    echo "    logo.dev key: already set"
  else
    while :; do
      read -rsp "    logo.dev secret key (sk_..., empty to skip): " LOGO_DEV_KEY
      echo
      [[ "$LOGO_DEV_KEY" =~ ^[A-Za-z0-9_]*$ ]] && break
      echo "    A key has letters, digits and underscores only."
    done
  fi
fi

# The backup drive: an encrypted APFS volume on an external disk, which
# box-server backs up to every night. FileVault covers only the Mac's own disk,
# so the volume has a passphrase of its own. The login keychain holds it, so an
# agent unlocks the volume after a restart. 1Password and the office keep it too.
BACKUP_VOLUME="Aldine Backups"
BACKUP_DIR="/Volumes/$BACKUP_VOLUME"
BACKUP_SERVICE="ai.aldine.backup-volume"
BACKUP_LABEL="ai.aldine.backup-volume"
BACKUP_PLIST="$HOME/Library/LaunchAgents/$BACKUP_LABEL.plist"
BACKUP_CONTAINER=""
BACKUP_PASSPHRASE=""

# The UUID of the backup volume, on any disk that is plugged in, or nothing.
backup_volume_uuid() {
  diskutil apfs list -plist | plutil -convert json -o - - |
    jq -r --arg name "$BACKUP_VOLUME" '.Containers[].Volumes[] | select(.Name == $name) | .APFSVolumeUUID' |
    head -n 1
}

# Each APFS container on an external disk, as "<container> <free bytes> <volumes>".
# A disk image, such as an Xcode simulator runtime, is not internal either, so it
# is left out by its bus protocol.
backup_containers() {
  diskutil apfs list -plist | plutil -convert json -o - - |
    jq -r '.Containers[] | [.ContainerReference, .DesignatedPhysicalStore, .CapacityFree, ([.Volumes[].Name] | join(", "))] | @tsv' |
    while IFS=$'\t' read -r container store free names; do
      if diskutil info -plist "$store" | plutil -convert json -o - - |
        jq -e '.Internal == false and .BusProtocol != "Disk Image"' >/dev/null; then
        printf '%s\t%s\t%s\n' "$container" "$free" "$names"
      fi
    done
}

# Ask for the passphrase of the backup volume, twice. A new passphrase has 20
# characters or more. An existing one is checked against the volume instead.
read_backup_passphrase() {
  while :; do
    read -rsp "    $1: " BACKUP_PASSPHRASE
    echo
    if [ "$2" = new ] && [ "${#BACKUP_PASSPHRASE}" -lt 20 ]; then
      echo "    A passphrase has 20 characters or more."
      continue
    fi
    local again
    read -rsp "    The same passphrase again: " again
    echo
    [ "$again" = "$BACKUP_PASSPHRASE" ] && break
    echo "    The two do not match."
  done
}

BACKUP_UUID="$(backup_volume_uuid)"
if [ -n "$BACKUP_UUID" ]; then
  echo "    backup volume: $BACKUP_VOLUME, already there"
  # A new Mac with a drive that holds backups: the passphrase is in 1Password.
  if ! security find-generic-password -s "$BACKUP_SERVICE" &>/dev/null; then
    until [ -n "$BACKUP_PASSPHRASE" ] && printf '%s' "$BACKUP_PASSPHRASE" | diskutil apfs unlockVolume "$BACKUP_UUID" -stdinpassphrase -verify &>/dev/null; do
      read_backup_passphrase "Passphrase of $BACKUP_VOLUME, from 1Password" existing
    done
  fi
else
  # Adding a volume keeps what the disk holds, such as a copy of older data.
  BACKUP_CHOICES="$(backup_containers)"
  if [ -z "$BACKUP_CHOICES" ]; then
    echo "    No external APFS disk is plugged in, so the box gets no backup drive."
    echo "    Plug in the backup drive and run ./setup.sh again. A drive that is not"
    echo "    APFS must be erased as APFS first, in Disk Utility."
  else
    echo "    The backup drive gets a new encrypted volume, $BACKUP_VOLUME."
    echo "    What the drive holds stays. The external APFS disks:"
    i=0
    while IFS=$'\t' read -r container free names; do
      i=$((i + 1))
      echo "      $i) $container, $((free / 1000000000)) GB free, holds: ${names:-nothing}"
    done <<< "$BACKUP_CHOICES"
    while :; do
      read -rp "    Backup drive [1-$i, empty to skip]: " choice
      [ -z "$choice" ] && break
      if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$i" ]; then
        BACKUP_CONTAINER="$(sed -n "${choice}p" <<< "$BACKUP_CHOICES" | cut -f1)"
        break
      fi
    done
    if [ -n "$BACKUP_CONTAINER" ]; then
      echo "    Make a passphrase in 1Password, titled \"${BOX_NAME:-$(hostname -s)} backup drive\"."
      echo "    Give a copy to the office, as with the FileVault recovery key."
      read_backup_passphrase "Passphrase for $BACKUP_VOLUME" new
    fi
  fi
fi

# The passphrase goes in the login keychain, which a session over SSH holds
# locked. Unlock it now, while a person is at the keyboard.
if [ -n "$BACKUP_PASSPHRASE" ] && { [ -n "${SSH_CONNECTION:-}" ] || ! security show-keychain-info "$HOME/Library/Keychains/login.keychain-db" &>/dev/null; }; then
  echo "    The login keychain is locked. Type the password of $USER to unlock it."
  security unlock-keychain "$HOME/Library/Keychains/login.keychain-db"
fi

# A tagged auth key gives the node the identity of tag:aldine-$ROLE rather
# than of a user account, and tagged nodes never expire. The key is a secret:
# pass it as TS_AUTHKEY, and never commit one to this public repo. On a re-run,
# start the daemon first, so a stopped daemon does not look like a new box.
if command -v tailscale &>/dev/null; then
  sudo brew services start tailscale &>/dev/null || true
  for _ in $(seq 1 15); do
    [ -S /var/run/tailscaled.socket ] && break
    sleep 1
  done
fi
if ! tailscale status &>/dev/null && [ -z "${TS_AUTHKEY:-}" ]; then
  echo "    Create a reusable auth key tagged 'tag:aldine-$ROLE':"
  echo "    https://login.tailscale.com/admin/settings/keys"
  read -rsp "    Auth key (tskey-auth-...): " TS_AUTHKEY
  echo
fi

# The deploy key for the aldine clone. It is the last input, as a person adds
# it on GitHub.
DEPLOY_KEY="$HOME/.ssh/aldine_deploy"
SSH_ALIAS="github.com-aldine"

# A deploy key reaches aldine and nothing else, so this machine holds no
# account-wide GitHub credential. It lives behind a Host alias, so plain
# github.com stays free for a forwarded agent (ssh -A) to serve.
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [ ! -f "$DEPLOY_KEY" ]; then
  ssh-keygen -t ed25519 -f "$DEPLOY_KEY" -N "" -C "aldine-deploy-${BOX_NAME:-$(hostname -s)}"
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

# ssh -T exits 1 even when it authenticates, because GitHub refuses shell
# access. Under pipefail, `ssh | grep` would therefore always look like a
# failure, so capture the output and match it instead.
deploy_key_ready() {
  local out
  out=$(ssh -T -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    "git@$SSH_ALIAS" 2>&1 || true)
  [[ "$out" == *"successfully authenticated"* ]]
}

# Wait until the public key is registered on the repo. A dev box pushes, so its
# key can write. A customer box only pulls, so its key is read-only.
until deploy_key_ready; do
  echo
  if [ "$ROLE" = "dev" ]; then
    echo "    Add this deploy key to aldine, with write access:"
  else
    echo "    Add this deploy key to aldine, titled $BOX_NAME. Leave write access off:"
  fi
  echo "    https://github.com/cowlabs-xyz/aldine/settings/keys/new"
  echo
  cat "$DEPLOY_KEY.pub"
  echo
  read -rp "    Press enter once it is added: "
done


echo "==> Installing packages from Brewfile"
# A customer box upgrades packages only through update.sh, by hand, outside
# office hours. A re-run of setup.sh there installs what is missing, and
# upgrades nothing.
if [ "$ROLE" = "prod" ]; then
  HOMEBREW_BUNDLE_NO_UPGRADE=1 brew bundle --file Brewfile
else
  brew bundle --file Brewfile
fi
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
sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool true
# macOS updates auto-install only on dev (tolerable reboots); prod applies
# them by hand outside office hours. A prod box has FileVault on, so a restart
# nobody expects leaves it down until someone types the password. Security
# responses can restart the machine too, so prod installs none by itself.
if [ "$ROLE" = "dev" ]; then
  sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool true
  sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool true
else
  sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
  sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool false
fi
# Gatekeeper: warn if someone disabled it
if ! spctl --status 2>/dev/null | grep -q "enabled"; then
  echo "    WARNING: Gatekeeper is disabled"
fi
# SSH: uncomment to require key auth once authorized_keys are deployed
# sudo tee /etc/ssh/sshd_config.d/100-aldine.conf >/dev/null <<'SSH'
# PasswordAuthentication no
# KbdInteractiveAuthentication no
# SSH

echo "==> macOS services and apps"
# A box serves Aldine only. Turn off the services that send data to Apple or
# talk to devices nearby. Some apply only after the next login.
# Siri, and Siri data sharing
defaults write com.apple.assistant.support "Assistant Enabled" -bool false
defaults write com.apple.assistant.support "Siri Data Sharing Opt-In Status" -int 2
defaults write com.apple.Siri StatusMenuVisible -bool false
defaults write com.apple.Siri VoiceTriggerUserEnabled -bool false
# Analytics and crash reports to Apple and to app developers
DIAG_PLIST="/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist"
sudo defaults write "$DIAG_PLIST" AutoSubmit -bool false
sudo defaults write "$DIAG_PLIST" ThirdPartyDataSubmit -bool false
# AirDrop and Handoff
defaults write com.apple.NetworkBrowser DisableAirDrop -bool true
defaults -currentHost write com.apple.coreservices.useractivityd ActivityAdvertisingAllowed -bool false
defaults -currentHost write com.apple.coreservices.useractivityd ActivityReceivingAllowed -bool false
# The App Store apps that come with a Mac. The apps on the system volume
# (Music, News, Safari and so on) are read-only and stay.
REMOVED_APPS=(GarageBand iMovie Keynote Numbers Pages)
for app in "${REMOVED_APPS[@]}"; do
  if [ -d "/Applications/$app.app" ]; then
    echo "    removing $app"
    sudo rm -rf "/Applications/$app.app"
  fi
done
if defaults read MobileMeAccounts Accounts 2>/dev/null | grep -q AccountID; then
  echo "    WARNING: this Mac is signed in to an Apple ID. Sign out in System Settings."
fi

# Vite serves Aldine on this port on every box. See ops/box/deploy.sh in aldine.
ALDINE_URL="http://localhost:5173"

if [ "$ROLE" = "prod" ]; then
  echo "==> Chrome"
  # Staff open Aldine on the box in Chrome, not Safari. Aldine is the start
  # page, the home page and a bookmark. Chrome reads the initial preferences
  # when it makes a new profile only, so a profile made before this step keeps
  # its own settings.
  CHROME_SUPPORT="/Library/Google"
  CHROME_INITIAL="$CHROME_SUPPORT/Google Chrome Initial Preferences"
  CHROME_BOOKMARKS="$CHROME_SUPPORT/aldine-bookmarks.html"
  sudo mkdir -p "$CHROME_SUPPORT"
  sudo tee "$CHROME_BOOKMARKS" >/dev/null <<BOOKMARKS
<!DOCTYPE NETSCAPE-Bookmark-file-1>
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Bookmarks</TITLE>
<H1>Bookmarks</H1>
<DL><p>
    <DT><H3 PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
    <DL><p>
        <DT><A HREF="$ALDINE_URL/">Aldine</A>
    </DL><p>
</DL><p>
BOOKMARKS
  sudo tee "$CHROME_INITIAL" >/dev/null <<PREFS
{
  "homepage": "$ALDINE_URL/",
  "homepage_is_newtabpage": false,
  "browser": { "show_home_button": true },
  "session": { "restore_on_startup": 4, "startup_urls": ["$ALDINE_URL/"] },
  "bookmark_bar": { "show_on_all_tabs": true },
  "sync_promo": { "show_on_first_run_allowed": false },
  "first_run_tabs": ["$ALDINE_URL/"],
  "distribution": {
    "skip_first_run_ui": true,
    "import_bookmarks": false,
    "import_bookmarks_from_file": "$CHROME_BOOKMARKS",
    "make_chrome_default_for_user": true,
    "suppress_first_run_default_browser_prompt": false
  }
}
PREFS
  # Chrome applies a policy only from a configuration profile, and macOS lets
  # a person install a profile, not a script. So open it for them.
  CHROME_PROFILE_ID="ai.aldine.chrome"
  chrome_profile_installed() {
    sudo profiles show -type configuration 2>/dev/null | grep -q "$CHROME_PROFILE_ID"
  }
  if ! chrome_profile_installed; then
    open assets/chrome.mobileconfig || true
    echo "    Install the Chrome profile: System Settings > General > Device Management,"
    echo "    open \"Aldine: Chrome\", and click Install. Then run ./setup.sh again."
  fi
  # macOS asks a person to confirm a new default browser. Chrome asks on its
  # first run, so open it.
  chrome_is_default() {
    defaults read com.apple.LaunchServices/com.apple.launchservices.secure LSHandlers 2>/dev/null | grep -B1 "LSHandlerURLScheme = https;" | grep -q "com.google.chrome"
  }
  if ! chrome_is_default; then
    open -a "Google Chrome" || true
    echo "    Make Chrome the default browser: confirm the macOS prompt, or pick it in"
    echo "    System Settings > Desktop & Dock > Default web browser."
  fi
fi

echo "==> Aldine app"
# An app with the Aldine icon that opens Aldine in Chrome, for the Dock. A
# re-run builds it again.
ALDINE_APP="/Applications/Aldine.app"
sudo rm -rf "$ALDINE_APP"
sudo osacompile -o "$ALDINE_APP" -e "do shell script \"open -a 'Google Chrome' $ALDINE_URL/\""
# The icon follows the macOS icon style: default, dark, clear and tinted.
# Assets.car holds it, and Aldine.icns is for older macOS. Both are compiled
# from assets/aldine-icon/Aldine.icon. See the README to change the icon.
sudo rm -f "$ALDINE_APP/Contents/Resources/applet.icns"
sudo cp assets/aldine-icon/Assets.car assets/aldine-icon/Aldine.icns "$ALDINE_APP/Contents/Resources/"
sudo /usr/libexec/PlistBuddy -c "Set :CFBundleIconName Aldine" -c "Set :CFBundleIconFile Aldine" "$ALDINE_APP/Contents/Info.plist"
# The edits break the ad-hoc signature of the applet. Sign it again.
sudo codesign --force --sign - "$ALDINE_APP"
sudo touch "$ALDINE_APP"

echo "==> Dock"
# The Dock holds only what a box needs, after Finder, which is always first:
# Aldine, Chrome, Terminal on a dev box, and System Settings. A re-run sets
# it again.
dock_tile() {
  echo "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>$1</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>"
}
DOCK_APPS=("$ALDINE_APP" "/Applications/Google Chrome.app")
[ "$ROLE" = "dev" ] && DOCK_APPS+=("/System/Applications/Utilities/Terminal.app")
DOCK_APPS+=("/System/Applications/System Settings.app")
DOCK_TILES=()
for app in "${DOCK_APPS[@]}"; do
  DOCK_TILES+=("$(dock_tile "$app")")
done
defaults write com.apple.dock persistent-apps -array "${DOCK_TILES[@]}"
defaults write com.apple.dock persistent-others -array
defaults write com.apple.dock show-recents -bool false
killall Dock &>/dev/null || true

# Every box shows the Aldine mark as its desktop picture and user picture.
echo "==> Desktop picture and user picture"
# The images live in this repo, in assets/. Copy them to where macOS keeps
# its own, so a pull of this repo does not change them under the box.
WALLPAPER="/Library/Desktop Pictures/Aldine.png"
USER_PICTURE="/Library/User Pictures/Aldine.png"
# A fresh macOS has neither folder: its own pictures are under /System.
sudo mkdir -p "/Library/Desktop Pictures" "/Library/User Pictures"
sudo cp assets/wallpaper.png "$WALLPAPER"
sudo cp assets/user-picture.png "$USER_PICTURE"
# macOS shows an emoji or Memoji avatar (AvatarRepresentation) and a photo
# (JPEGPhoto) before Picture, so delete both.
sudo dscl . -delete "/Users/$USER" AvatarRepresentation &>/dev/null || true
sudo dscl . -delete "/Users/$USER" JPEGPhoto &>/dev/null || true
sudo dscl . -create "/Users/$USER" Picture "$USER_PICTURE"
# Setting the desktop picture needs a logged-in session, and macOS can ask
# once to let this terminal control System Events.
if ! osascript -e "tell application \"System Events\" to tell every desktop to set picture to POSIX file \"$WALLPAPER\"" &>/dev/null; then
  echo "    Could not set the desktop picture. Log in at the box and run ./setup.sh"
  echo "    there, or pick $WALLPAPER in System Settings > Wallpaper."
fi

if [ "$ROLE" = "prod" ]; then
  echo "==> Screen lock"
  # A person uses Aldine at the box, and the display sleeps after 10 minutes.
  # Ask for the password 5 seconds after that, so nobody walking past reads
  # the invoices. sysadminctl asks for the password of this user.
  SCREEN_LOCK_STATUS="screenLock delay is 5 seconds"
  if ! sysadminctl -screenLock status 2>&1 | grep -q "$SCREEN_LOCK_STATUS"; then
    echo "    Type the macOS password of $USER to turn on the screen lock."
    sysadminctl -screenLock 5 -password - || echo "    WARNING: the screen lock is not set"
  fi
fi

echo "==> Server behaviour (headless)"
# Never sleep; restart automatically after power failure or freeze
sudo pmset -a sleep 0 disksleep 0 displaysleep 10 autorestart 1 womp 1
sudo systemsetup -setrestartfreeze on
# A dev box keeps FileVault OFF for unattended reboots (boot blocks on
# password), and relies on the physical security of our office. A prod box
# holds a customer's data, so it has FileVault ON, and the final check says so.
if [ "$ROLE" = "dev" ] && fdesetup status | grep -q "FileVault is On"; then
  echo "    WARNING: FileVault is ON — this machine cannot reboot unattended"
  echo "    (use 'sudo fdesetup authrestart' for manual reboots, or disable FileVault)"
fi

if [ "$ROLE" = "prod" ]; then
  echo "==> Name: $BOX_NAME"
  for name in ComputerName HostName LocalHostName; do
    if [ "$(scutil --get "$name" 2>/dev/null || true)" != "$BOX_NAME" ]; then
      sudo scutil --set "$name" "$BOX_NAME"
    fi
  done

  if [ -n "$WIFI_SSID" ]; then
    echo "==> Wifi: $WIFI_SSID"
    # networksetup prints an error but exits 0 when it cannot join, so the
    # list of saved networks decides.
    sudo networksetup -setairportnetwork "$WIFI_DEVICE" "$WIFI_SSID" "$WIFI_PASSWORD" || true
    if networksetup -listpreferredwirelessnetworks "$WIFI_DEVICE" | sed 's/^[[:space:]]*//' | grep -qxF "$WIFI_SSID"; then
      echo "$WIFI_SSID" > "$WIFI_FILE"
      echo "    saved"
    else
      echo "    FAILED to join $WIFI_SSID. Check the name and the password, and run ./setup.sh again"
    fi
  fi
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

echo "==> Tailscale"
# A system daemon, so it starts at boot with no login session. This is the open
# source formula, not the GUI cask: only this variant serves Tailscale SSH on
# macOS, and the cask would need a GUI to log in.
sudo brew services start tailscale &>/dev/null || true
for _ in $(seq 1 15); do
  [ -S /var/run/tailscaled.socket ] && break
  sleep 1
done

TS_HOSTNAME="${BOX_NAME:-$(hostname -s)}"
if tailscale status &>/dev/null; then
  echo "    already connected"
  # A dev box keeps the Tailscale name it has.
  if [ "$ROLE" = "prod" ]; then
    sudo tailscale set --hostname="$TS_HOSTNAME"
  fi
else
  # --ssh serves SSH over the tailnet, authorised by the policy file instead of
  # authorized_keys. Native Remote Login stays on above as a fallback.
  sudo tailscale up --ssh --auth-key="$TS_AUTHKEY" --hostname="$TS_HOSTNAME"
fi
# Let this user run tailscale without sudo
sudo tailscale set --operator="$USER" || true

# A watchdog loads tailscaled again when anything unloads it, such as
# `brew services stop`, or a `brew services restart` that a dropped Tailscale
# SSH session cut halfway. launchd's KeepAlive restarts a tailscaled that exits,
# but not one that is unloaded. Without the watchdog, the box stays off the
# tailnet until someone reaches it on the office network. It runs every 2
# minutes, and logs only when it acts.
TS_LABEL="sh.brew.tailscale"
# Homebrew keeps the plist of the service in the keg. brew services copies it
# to /Library/LaunchDaemons on start, and removes the copy on stop.
TS_KEG_PLIST="$(brew --prefix tailscale)/$TS_LABEL.plist"
TS_WATCHDOG_LABEL="ai.aldine.tailscale-watchdog"
TS_WATCHDOG_PLIST="/Library/LaunchDaemons/$TS_WATCHDOG_LABEL.plist"
TS_WATCHDOG_WANT="$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Written by bootstrap-mac setup.sh. Edits are overwritten. -->
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$TS_WATCHDOG_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>launchctl print system/$TS_LABEL &gt;/dev/null 2&gt;&amp;1 &amp;&amp; exit 0; plist=/Library/LaunchDaemons/$TS_LABEL.plist; if [ ! -f "\$plist" ]; then cp "$TS_KEG_PLIST" "\$plist" &amp;&amp; chown root:wheel "\$plist" &amp;&amp; chmod 644 "\$plist"; fi; launchctl bootstrap system "\$plist" &amp;&amp; echo "\$(date): tailscaled was not loaded, loaded it again"</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>120</integer>
  <key>StandardOutPath</key>
  <string>/var/log/$TS_WATCHDOG_LABEL.log</string>
  <key>StandardErrorPath</key>
  <string>/var/log/$TS_WATCHDOG_LABEL.log</string>
</dict>
</plist>
EOF
)"
if [ "$(sudo cat "$TS_WATCHDOG_PLIST" 2>/dev/null)" != "$TS_WATCHDOG_WANT" ]; then
  echo "$TS_WATCHDOG_WANT" | sudo tee "$TS_WATCHDOG_PLIST" >/dev/null
  sudo chown root:wheel "$TS_WATCHDOG_PLIST"
  sudo chmod 644 "$TS_WATCHDOG_PLIST"
  # launchd reads a plist only when it loads it, so unload the old one, and
  # wait until it is gone.
  sudo launchctl bootout "system/$TS_WATCHDOG_LABEL" 2>/dev/null || true
  for _ in $(seq 1 10); do
    sudo launchctl print "system/$TS_WATCHDOG_LABEL" &>/dev/null || break
    sleep 1
  done
fi
if ! sudo launchctl print "system/$TS_WATCHDOG_LABEL" &>/dev/null; then
  sudo launchctl bootstrap system "$TS_WATCHDOG_PLIST"
fi
echo "    the watchdog loads tailscaled again within 2 minutes if anything unloads it"

echo "==> Ollama"
# The official release build, run by our own launchd agent. Not the Homebrew
# formula: Homebrew builds with no network, so it lacks libollama_xgrammar.dylib,
# and models that run on MLX then refuse structured output (HTTP 501). Not the
# Mac app either: it checks for updates every hour and sends a device ID.
# The version is pinned. Change it here and in aldine's ops/box/ollama.json
# together; a re-run of setup.sh installs it and removes the old one.
OLLAMA_VERSION="0.40.6"
OLLAMA_ROOT="$HOME/.local/ollama"
OLLAMA_DIR="$OLLAMA_ROOT/$OLLAMA_VERSION"
OLLAMA_LABEL="ai.aldine.ollama"
OLLAMA_PLIST="$HOME/Library/LaunchAgents/$OLLAMA_LABEL.plist"
OLLAMA_DOMAIN="gui/$(id -u)"

if [ ! -x "$OLLAMA_DIR/ollama" ]; then
  echo "    installing $OLLAMA_VERSION"
  OLLAMA_URL="https://github.com/ollama/ollama/releases/download/v$OLLAMA_VERSION"
  mkdir -p "$OLLAMA_ROOT"
  OLLAMA_TMP="$(mktemp -d "$OLLAMA_ROOT/.download.XXXXXX")"
  curl -fsSL -o "$OLLAMA_TMP/ollama-darwin.tgz" "$OLLAMA_URL/ollama-darwin.tgz"
  curl -fsSL -o "$OLLAMA_TMP/sha256sum.txt" "$OLLAMA_URL/sha256sum.txt"
  # The release lists each asset as ./<name>. No line, or a mismatch, fails.
  (cd "$OLLAMA_TMP" && grep '  \./ollama-darwin\.tgz$' sha256sum.txt | shasum -a 256 -c -)
  mkdir "$OLLAMA_TMP/ollama"
  tar -xzf "$OLLAMA_TMP/ollama-darwin.tgz" -C "$OLLAMA_TMP/ollama"
  if ! ls "$OLLAMA_TMP"/ollama/mlx_metal_v*/libollama_xgrammar.dylib &>/dev/null; then
    echo "    FAILED: the $OLLAMA_VERSION tarball has no libollama_xgrammar.dylib" >&2
    exit 1
  fi
  mv "$OLLAMA_TMP/ollama" "$OLLAMA_DIR"
  rm -rf "$OLLAMA_TMP"
fi
# The CLI on PATH. Ollama follows the link to find its libraries.
sudo mkdir -p /usr/local/bin
sudo ln -sfn "$OLLAMA_DIR/ollama" /usr/local/bin/ollama

# Earlier versions of this script ran Ollama under the agent xyz.cowlabs.ollama.
# Remove it, so it does not hold the port of the agent below. Its log stays.
launchctl bootout "$OLLAMA_DOMAIN/xyz.cowlabs.ollama" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/xyz.cowlabs.ollama.plist"

# Earlier versions of this script ran the formula as a Homebrew service. Stop
# and remove it. The models in ~/.ollama stay, so nothing downloads again.
if brew list --formula ollama &>/dev/null; then
  brew services stop ollama || true
  brew unpin ollama 2>/dev/null || true
  brew uninstall ollama
fi

# Turn off Ollama's cloud features: remote inference, and the call to
# ollama.com for model suggestions. Ollama reads the file the same way as
# OLLAMA_NO_CLOUD=1, and only at start.
OLLAMA_CONFIG="$HOME/.ollama/server.json"
OLLAMA_CONFIG_WANT='{"disable_ollama_cloud": true}'
OLLAMA_RESTART=false
if [ "$(cat "$OLLAMA_CONFIG" 2>/dev/null)" != "$OLLAMA_CONFIG_WANT" ]; then
  mkdir -p "$HOME/.ollama"
  echo "$OLLAMA_CONFIG_WANT" > "$OLLAMA_CONFIG"
  OLLAMA_RESTART=true
fi

# A user agent, not a system daemon: Metal GPU access needs a login session, and
# a root LaunchDaemon would fall back to CPU. Enable auto-login (see manual
# steps) so it returns after an unattended reboot. Localhost only, and the
# environment the Homebrew service set.
OLLAMA_PLIST_WANT="$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Written by bootstrap-mac setup.sh. Edits are overwritten. -->
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$OLLAMA_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$OLLAMA_DIR/ollama</string>
    <string>serve</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OLLAMA_HOST</key>
    <string>127.0.0.1:11434</string>
    <key>OLLAMA_FLASH_ATTENTION</key>
    <string>1</string>
    <key>OLLAMA_KV_CACHE_TYPE</key>
    <string>q8_0</string>
  </dict>
  <key>WorkingDirectory</key>
  <string>$HOME</string>
  <key>KeepAlive</key>
  <true/>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/$OLLAMA_LABEL.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/$OLLAMA_LABEL.log</string>
</dict>
</plist>
EOF
)"
if [ "$(cat "$OLLAMA_PLIST" 2>/dev/null)" != "$OLLAMA_PLIST_WANT" ]; then
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  echo "$OLLAMA_PLIST_WANT" > "$OLLAMA_PLIST"
  # launchd reads a plist only when it loads it, so unload the old one
  launchctl bootout "$OLLAMA_DOMAIN/$OLLAMA_LABEL" 2>/dev/null || true
  for _ in $(seq 1 10); do
    launchctl print "$OLLAMA_DOMAIN/$OLLAMA_LABEL" &>/dev/null || break
    sleep 1
  done
fi
if ! launchctl print "$OLLAMA_DOMAIN/$OLLAMA_LABEL" &>/dev/null; then
  launchctl bootstrap "$OLLAMA_DOMAIN" "$OLLAMA_PLIST"
elif [ "$OLLAMA_RESTART" = true ]; then
  launchctl kickstart -k "$OLLAMA_DOMAIN/$OLLAMA_LABEL"
fi

# GPU discovery takes a few seconds at start
OLLAMA_RUNNING=""
for _ in $(seq 1 60); do
  OLLAMA_RUNNING="$(curl -fsS http://127.0.0.1:11434/api/version 2>/dev/null || true)"
  [[ "$OLLAMA_RUNNING" == *"\"$OLLAMA_VERSION\""* ]] && break
  sleep 1
done
if [[ "$OLLAMA_RUNNING" == *"\"$OLLAMA_VERSION\""* ]]; then
  echo "    $OLLAMA_VERSION running"
  # Remove other versions, and any download left by an interrupted run
  find "$OLLAMA_ROOT" -mindepth 1 -maxdepth 1 ! -name "$OLLAMA_VERSION" -exec rm -rf {} +
else
  echo "    WARNING: Ollama $OLLAMA_VERSION does not answer on 127.0.0.1:11434"
  echo "    (got: ${OLLAMA_RUNNING:-nothing}). See ~/Library/Logs/$OLLAMA_LABEL.log"
fi

echo "==> Backup drive"
if [ -n "$BACKUP_CONTAINER" ]; then
  if ! printf '%s' "$BACKUP_PASSPHRASE" | diskutil apfs addVolume "$BACKUP_CONTAINER" APFS "$BACKUP_VOLUME" -stdinpassphrase; then
    echo "    FAILED to add $BACKUP_VOLUME to $BACKUP_CONTAINER. Check the drive in Disk Utility, and run ./setup.sh again." >&2
    exit 1
  fi
  BACKUP_UUID="$(backup_volume_uuid)"
fi
if [ -n "$BACKUP_PASSPHRASE" ]; then
  # Only security reads the item, so the agent reads it with no prompt.
  security add-generic-password -U -a "$BACKUP_VOLUME" -s "$BACKUP_SERVICE" \
    -T /usr/bin/security -w "$BACKUP_PASSPHRASE" "$HOME/Library/Keychains/login.keychain-db"
fi
if [ -n "$BACKUP_UUID" ]; then
  # The agent unlocks and mounts the volume at login, and every 5 minutes, so a
  # drive that is plugged in again comes back. It does nothing while the volume
  # is mounted, or no disk holds it.
  BACKUP_PLIST_WANT="$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Written by bootstrap-mac setup.sh. Edits are overwritten. -->
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$BACKUP_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>[ -d "$BACKUP_DIR" ] &amp;&amp; exit 0; uuid="\$(diskutil apfs list -plist | plutil -convert json -o - - | /usr/bin/jq -r '.Containers[].Volumes[] | select(.Name == "$BACKUP_VOLUME") | .APFSVolumeUUID' | head -n 1)"; [ -n "\$uuid" ] || exit 0; /usr/bin/security find-generic-password -s "$BACKUP_SERVICE" -w | diskutil apfs unlockVolume "\$uuid" -stdinpassphrase</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>300</integer>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/$BACKUP_LABEL.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/$BACKUP_LABEL.log</string>
</dict>
</plist>
EOF
)"
  if [ "$(cat "$BACKUP_PLIST" 2>/dev/null)" != "$BACKUP_PLIST_WANT" ]; then
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    echo "$BACKUP_PLIST_WANT" > "$BACKUP_PLIST"
    launchctl bootout "gui/$(id -u)/$BACKUP_LABEL" 2>/dev/null || true
  fi
  launchctl bootstrap "gui/$(id -u)" "$BACKUP_PLIST" 2>/dev/null || true
  launchctl kickstart "gui/$(id -u)/$BACKUP_LABEL" || true
  for _ in $(seq 1 15); do
    [ -d "$BACKUP_DIR" ] && break
    sleep 1
  done
  if [ -d "$BACKUP_DIR" ]; then
    # Keep the permissions that box-server sets, and keep Spotlight out of the
    # backups.
    sudo diskutil enableOwnership "$BACKUP_DIR" >/dev/null
    sudo mdutil -i off "$BACKUP_DIR" >/dev/null
    echo "    $BACKUP_DIR is mounted"
  else
    echo "    WARNING: $BACKUP_VOLUME does not mount. See ~/Library/Logs/$BACKUP_LABEL.log"
  fi
else
  echo "    no backup drive: the box takes no backups"
fi

echo "==> Log rotation"
# The agent rotates each ~/Library/Logs/ai.aldine.*.log, the logs of Aldine and
# Ollama, and keeps about 14 days of them. The logs never leave the box.
# rotate-logs.sh says why it does not use newsyslog.
ROTATE_LABEL="ai.aldine.rotate-logs"
ROTATE_PLIST="$HOME/Library/LaunchAgents/$ROTATE_LABEL.plist"
ROTATE_SCRIPT="$HOME/.local/aldine/rotate-logs.sh"
mkdir -p "$(dirname "$ROTATE_SCRIPT")"
install -m 755 rotate-logs.sh "$ROTATE_SCRIPT"
ROTATE_PLIST_WANT="$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Written by bootstrap-mac setup.sh. Edits are overwritten. -->
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$ROTATE_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>$ROTATE_SCRIPT</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>3600</integer>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/$ROTATE_LABEL.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/$ROTATE_LABEL.log</string>
</dict>
</plist>
EOF
)"
if [ "$(cat "$ROTATE_PLIST" 2>/dev/null)" != "$ROTATE_PLIST_WANT" ]; then
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  echo "$ROTATE_PLIST_WANT" > "$ROTATE_PLIST"
  launchctl bootout "gui/$(id -u)/$ROTATE_LABEL" 2>/dev/null || true
  for _ in $(seq 1 10); do
    launchctl print "gui/$(id -u)/$ROTATE_LABEL" &>/dev/null || break
    sleep 1
  done
fi
if ! launchctl print "gui/$(id -u)/$ROTATE_LABEL" &>/dev/null; then
  launchctl bootstrap "gui/$(id -u)" "$ROTATE_PLIST"
fi
echo "    the box rotates its logs every day, and keeps 14 days of them"

echo "==> Aldine"
# Both roles run Aldine from a clone: ops/box/deploy.sh in aldine installs and
# restarts it. Activate mise in the shells, so SSH sessions and the login shell
# of the launchd agent get the pinned tools.
if ! grep -q "brew shellenv" "$HOME/.zprofile" 2>/dev/null; then
  echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
fi
if ! grep -q "mise activate" "$HOME/.zshrc" 2>/dev/null; then
  echo 'eval "$(mise activate zsh)"' >> "$HOME/.zshrc"
fi
if [ ! -d "$ALDINE_DIR/.git" ]; then
  mkdir -p "$(dirname "$ALDINE_DIR")"
  git clone "git@$SSH_ALIAS:cowlabs-xyz/aldine.git" "$ALDINE_DIR"
fi

# A customer box carries its own id, which also turns off the debug service.
# This file belongs to setup.sh on a prod box: a re-run writes it again.
if [ "$ROLE" = "prod" ]; then
  # A re-run with the drive unplugged keeps the setting, so it does not turn
  # backups off.
  BACKUP_SET=false
  if [ -n "$BACKUP_UUID" ] || grep -qxF "ALDINE_BACKUP_DIR = \"$BACKUP_DIR\"" "$ALDINE_LOCAL" 2>/dev/null; then
    BACKUP_SET=true
  fi
  ALDINE_LOCAL_WANT="$(cat <<EOF
# Written by bootstrap-mac setup.sh. Edits are overwritten.
[env]
ALDINE_BOX_ID = "$BOX_NAME"
EOF
)"
  if [ -n "$LOGO_DEV_KEY" ]; then
    ALDINE_LOCAL_WANT="$ALDINE_LOCAL_WANT
ALDINE_LOGO_DEV_SECRET_KEY = \"$LOGO_DEV_KEY\""
  fi
  if [ "$BACKUP_SET" = true ]; then
    ALDINE_LOCAL_WANT="$ALDINE_LOCAL_WANT
ALDINE_BACKUP_DIR = \"$BACKUP_DIR\""
  fi
  ( umask 077 && echo "$ALDINE_LOCAL_WANT" > "$ALDINE_LOCAL" )
  mise trust "$ALDINE_LOCAL"
elif [ -n "$BACKUP_UUID" ]; then
  # A dev box keeps its own mise.local.toml. Add the setting to it.
  ( umask 077 && touch "$ALDINE_LOCAL" )
  mise trust "$ALDINE_LOCAL"
  (cd "$ALDINE_DIR" && mise set --file "$ALDINE_LOCAL" "ALDINE_BACKUP_DIR=$BACKUP_DIR")
fi

# mise refuses to run an untrusted config file
mise trust "$ALDINE_DIR/mise.toml"
# Go, Node, pnpm, buf and golangci-lint at the versions the repo pins. A dev
# box also gets the pnpm deps and the Playwright browser. A deploy installs
# what a prod box needs.
if [ "$ROLE" = "dev" ]; then
  (cd "$ALDINE_DIR" && mise install && mise run setup)
else
  (cd "$ALDINE_DIR" && mise install)
fi

if [ "$ROLE" = "prod" ]; then
  echo
  echo "==> Check"
  FAILED=0
  check() {
    if eval "$2" &>/dev/null; then
      echo "    ok      $1"
    else
      echo "    FAILED  $1"
      FAILED=$((FAILED + 1))
    fi
  }
  check "hostname is $BOX_NAME" '[ "$(scutil --get HostName)" = "$BOX_NAME" ]'
  check "tailscaled is loaded" 'sudo launchctl print "system/$TS_LABEL"'
  check "Tailscale comes back by itself when something unloads it" 'sudo launchctl print "system/$TS_WATCHDOG_LABEL" && [ -f "$TS_KEG_PLIST" ]'
  check "Tailscale machine name is $BOX_NAME" 'tailscale status --json --peers=false | grep -q "\"DNSName\": \"$BOX_NAME\."'
  check "FileVault is on" 'fdesetup status | grep -q "FileVault is On"'
  check "macOS updates do not install by themselves" '[ "$(defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates)" = 0 ] && [ "$(defaults read /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall)" = 0 ]'
  check "Siri is off" '[ "$(defaults read com.apple.assistant.support "Assistant Enabled")" = 0 ]'
  check "the Mac sends no analytics or crash reports" '[ "$(defaults read "$DIAG_PLIST" AutoSubmit)" = 0 ] && [ "$(defaults read "$DIAG_PLIST" ThirdPartyDataSubmit)" = 0 ]'
  check "AirDrop and Handoff are off" '[ "$(defaults read com.apple.NetworkBrowser DisableAirDrop)" = 1 ] && [ "$(defaults -currentHost read com.apple.coreservices.useractivityd ActivityAdvertisingAllowed)" = 0 ]'
  check "GarageBand, iMovie, Keynote, Numbers and Pages are removed" '( for app in "${REMOVED_APPS[@]}"; do [ ! -d "/Applications/$app.app" ] || exit 1; done )'
  check "no Apple ID is signed in" '! defaults read MobileMeAccounts Accounts 2>/dev/null | grep -q AccountID'
  check "Chrome is installed" '[ -d "/Applications/Google Chrome.app" ]'
  check "Chrome opens Aldine" '[ -f "$CHROME_INITIAL" ] && [ -f "$CHROME_BOOKMARKS" ]'
  check "the Chrome profile blocks sign-in and data to Google" 'chrome_profile_installed'
  check "Chrome is the default browser" 'chrome_is_default'
  check "the Dock holds Chrome and System Settings" 'defaults read com.apple.dock persistent-apps | grep -q "Google Chrome.app" && ! defaults read com.apple.dock persistent-apps | grep -q "Safari.app"'
  check "the user picture is the Aldine mark" '! dscl . -read "/Users/$USER" AvatarRepresentation && [ "$(dscl . -read "/Users/$USER" Picture | tail -1 | sed "s/^Picture: //; s/^ //")" = "$USER_PICTURE" ]'
  check "the screen locks 5 seconds after the display sleeps" 'sysadminctl -screenLock status 2>&1 | grep -q "$SCREEN_LOCK_STATUS"'
  check "the deploy key reaches aldine" 'deploy_key_ready'
  check "aldine is cloned" '[ -d "$ALDINE_DIR/.git" ]'
  check "the box id is $BOX_NAME" 'grep -qxF "ALDINE_BOX_ID = \"$BOX_NAME\"" "$ALDINE_LOCAL"'
  if grep -q "^ALDINE_LOGO_DEV_SECRET_KEY = " "$ALDINE_LOCAL"; then
    echo "    ok      the logo.dev key is set"
  else
    echo "    -       no logo.dev key: vendors show their initials"
  fi
  check "Ollama $OLLAMA_VERSION answers" 'curl -fsS http://127.0.0.1:11434/api/version | grep -q "\"$OLLAMA_VERSION\""'
  check "the box rotates its logs" 'launchctl print "gui/$(id -u)/$ROTATE_LABEL" | grep -q "last exit code = 0"'
  # A customer box holds the only copy of its data, so it needs its drive.
  if [ -z "$BACKUP_UUID" ]; then
    check "a backup drive with $BACKUP_VOLUME is plugged in" 'false'
  else
    check "the backup volume $BACKUP_VOLUME is encrypted" 'diskutil info "$BACKUP_DIR" | grep -qE "FileVault: +Yes"'
    check "the backup volume is mounted and writable" 'touch "$BACKUP_DIR/.setup-check" && rm "$BACKUP_DIR/.setup-check"'
    check "the keychain holds the passphrase of the backup volume" 'security find-generic-password -s "$BACKUP_SERVICE"'
    check "the backup volume unlocks at login" 'launchctl print "gui/$(id -u)/$BACKUP_LABEL"'
    check "the box backs up to $BACKUP_DIR" 'grep -qxF "ALDINE_BACKUP_DIR = \"$BACKUP_DIR\"" "$ALDINE_LOCAL"'
  fi
  WIFI_WANT="${WIFI_WANT:-$(cat "$WIFI_FILE" 2>/dev/null || true)}"
  if [ -n "$WIFI_WANT" ]; then
    check "the office wifi $WIFI_WANT is saved" 'networksetup -listpreferredwirelessnetworks "$WIFI_DEVICE" | sed "s/^[[:space:]]*//" | grep -qxF "$WIFI_WANT"'
  else
    echo "    -       no office wifi"
  fi
  echo
  if [ "$FAILED" -gt 0 ]; then
    echo "$FAILED check(s) failed. Fix them, and run ./setup.sh again."
    exit 1
  fi
  echo "Done. $BOX_NAME is set up. Deploy Aldine to it from your laptop."
else
  echo
  if [ ! -d "$BACKUP_DIR" ]; then
    echo "WARNING: no backup drive is mounted, so this box takes no backups."
    echo
  fi
  echo "Done. Remaining manual steps:"
  echo "  - Set a hostname: sudo scutil --set ComputerName/HostName/LocalHostName"
  echo "  - Enable Screen Sharing (System Settings > General > Sharing) if wanted"
  echo "  - Enable auto-login (System Settings > Users & Groups), so the Ollama"
  echo "    user agent comes back after an unattended reboot"
  echo "  - Verify the toolchain: cd ~/git/cowlabs/aldine && mise run build && mise run test"
fi
