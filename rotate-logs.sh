#!/bin/sh
# Rotates each Aldine and Ollama log in ~/Library/Logs, and keeps about 14 days
# of them, so the logs cannot fill the disk. setup.sh installs this script, and
# the launchd agent ai.aldine.rotate-logs runs it every hour.
#
# launchd opens the log of an agent once, when it starts the agent. A rename
# leaves the agent writing to the renamed file, so newsyslog cannot rotate these
# logs. This script copies each log, then empties it in place. launchd opens a
# log for append, so the next line goes to the start of the empty file. A line
# that the agent writes between the copy and the truncate is lost.
#
# A log rotates on its first run of each day, and when it is over 100 MB.
set -u

LOGS="$HOME/Library/Logs"
MAX_BYTES=$((100 * 1024 * 1024))
KEEP_DAYS=14

today="$(date +%Y%m%d)"
for log in "$LOGS"/ai.aldine.*.log; do
  [ -s "$log" ] || continue
  # The rotations of a log are <log>.<yyyymmddThhmmss>.gz, so the last name in
  # order is the latest. A rotation that gzip failed on has no .gz.
  latest="$(find "$LOGS" -maxdepth 1 -name "$(basename "$log").*" | sort | tail -n 1)"
  size="$(stat -f %z "$log")"
  case "$latest" in
    "$log.$today"T*) [ "$size" -gt "$MAX_BYTES" ] || continue ;;
  esac
  rotated="$log.$(date +%Y%m%dT%H%M%S)"
  # Keep the log as it is when the copy fails, such as on a full disk.
  if ! cp "$log" "$rotated"; then
    rm -f "$rotated"
    continue
  fi
  : > "$log"
  gzip "$rotated"
done

find "$LOGS" -maxdepth 1 -name 'ai.aldine.*.log.*' -mtime +"$KEEP_DAYS" -delete
