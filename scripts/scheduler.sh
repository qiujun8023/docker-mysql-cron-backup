#!/usr/bin/env bash

set -uo pipefail

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$*"
}

is_true() {
  case "$1" in
    1|true|TRUE|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

BACKUP_DIR="${BACKUP_DIR:-/backup}"
BACKUP_TIME="${BACKUP_TIME:-03:00}"
RUN_ON_STARTUP="${RUN_ON_STARTUP:-false}"
STATE_DIR="$BACKUP_DIR/.state"

if [[ ! "$BACKUP_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
  log "ERROR: BACKUP_TIME must use HH:MM in 24-hour time"
  exit 1
fi

mkdir -p "$STATE_DIR"
date +%s > "$STATE_DIR/started-at"

stopping=false
child_pid=""

stop() {
  stopping=true
  if [[ -n "$child_pid" ]]; then
    kill "$child_pid" 2>/dev/null || true
  fi
}
trap stop TERM INT

run_backup() {
  log "Starting scheduled backup"
  /usr/local/bin/backup.sh &
  child_pid=$!
  if wait "$child_pid"; then
    log "Scheduled backup succeeded"
  else
    log "ERROR: scheduled backup failed" >&2
  fi
  child_pid=""
}

if is_true "$RUN_ON_STARTUP"; then
  run_backup
fi

while [[ "$stopping" != "true" ]]; do
  now="$(date +%s)"
  next="$(date -d "$(date +%F) $BACKUP_TIME" +%s)"
  if (( next <= now )); then
    next="$(date -d "tomorrow $BACKUP_TIME" +%s)"
  fi
  delay=$((next - now))
  log "Next backup at $(date -d "@$next" '+%Y-%m-%d %H:%M:%S%z')"

  sleep "$delay" &
  child_pid=$!
  wait "$child_pid" 2>/dev/null || true
  child_pid=""

  [[ "$stopping" == "true" ]] && break
  run_backup
done

log "Scheduler stopped"
