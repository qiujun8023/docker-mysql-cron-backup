#!/usr/bin/env bash

set -Eeuo pipefail

export LC_ALL=C
umask 077

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$*"
}

fail() {
  log "ERROR: $*" >&2
  return 1
}

require_value() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    fail "$name is required"
    return 1
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "required command not found: $1"
    return 1
  fi
}

write_epoch() {
  local destination="$1"
  local temporary="${destination}.tmp.$$"
  date +%s > "$temporary"
  mv -f "$temporary" "$destination"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

is_system_database() {
  case "$1" in
    information_schema|mysql|performance_schema|sys) return 0 ;;
    *) return 1 ;;
  esac
}

validate_database_name() {
  [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.\$-]*$ ]]
}

local_file_size() {
  wc -c < "$1" | tr -d '[:space:]'
}

collect_databases() {
  local destination="$1"
  local query

  if [[ -n "${MYSQL_DATABASES:-}" ]]; then
    printf '%s\n' "$MYSQL_DATABASES" | tr ',' '\n' > "$destination"
    return
  fi

  query="SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','mysql','performance_schema','sys') ORDER BY SCHEMA_NAME"
  if ! "$MYSQL_BIN" "${MYSQL_ARGS[@]}" --execute="$query" > "$destination"; then
    fail "could not list MySQL databases"
    return 1
  fi
}

backup_database() {
  local database="$1"
  local timestamp="$2"
  local basename="${database}.${timestamp}.sql.gz"
  local dump_file="${WORK_DIR}/${basename}"
  local key="${S3_KEY_PREFIX}${basename}"
  local remote_size
  local local_size

  log "Dumping database $database"
  if ! "$MYSQLDUMP_BIN" \
      "${MYSQL_CONNECTION_ARGS[@]}" \
      --single-transaction \
      --quick \
      --routines \
      --events \
      --triggers \
      --hex-blob \
      --no-tablespaces \
      --set-gtid-purged=OFF \
      --databases "$database" \
      | gzip "-$GZIP_LEVEL" -n > "$dump_file"; then
    rm -f -- "$dump_file"
    fail "mysqldump failed for $database"
    return 1
  fi

  if ! gzip -t "$dump_file"; then
    rm -f -- "$dump_file"
    fail "gzip verification failed for $database"
    return 1
  fi

  log "Uploading s3://${S3_BUCKET}/${key}"
  if ! "$AWS_BIN" "${AWS_ARGS[@]}" s3 cp \
      "$dump_file" "s3://${S3_BUCKET}/${key}" \
      --only-show-errors; then
    rm -f -- "$dump_file"
    fail "S3 upload failed for $database"
    return 1
  fi

  local_size="$(local_file_size "$dump_file")"
  rm -f -- "$dump_file"

  if ! remote_size="$("$AWS_BIN" "${AWS_ARGS[@]}" s3api head-object \
      --bucket "$S3_BUCKET" \
      --key "$key" \
      --query ContentLength \
      --output text)"; then
    fail "could not verify uploaded object for $database"
    return 1
  fi
  remote_size="$(trim "$remote_size")"

  if [[ "$local_size" != "$remote_size" ]]; then
    fail "uploaded size mismatch for $database: local=$local_size remote=$remote_size"
    return 1
  fi

  log "Completed database $database"
}

MYSQL_HOST="${MYSQL_HOST:-mysql}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
MYSQL_SSL_MODE="${MYSQL_SSL_MODE:-PREFERRED}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_REGION="${S3_REGION:-us-east-1}"
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-}"
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
GZIP_LEVEL="${GZIP_LEVEL:-6}"
STATE_DIR="${STATE_DIR:-/var/lib/mysql-backup}"
MYSQL_BIN="${MYSQL_BIN:-mysql}"
MYSQLDUMP_BIN="${MYSQLDUMP_BIN:-mysqldump}"
AWS_BIN="${AWS_BIN:-aws}"

mkdir -p "$STATE_DIR"
WORK_DIR=""

on_exit() {
  local status=$?
  trap - EXIT
  if [[ -n "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR" 2>/dev/null || true
  fi
  if (( status != 0 )); then
    write_epoch "$STATE_DIR/last-failure" 2>/dev/null || true
  fi
  exit "$status"
}
trap on_exit EXIT

require_value MYSQL_USER
require_value MYSQL_PASSWORD
require_value S3_BUCKET
require_value AWS_ACCESS_KEY_ID
require_value AWS_SECRET_ACCESS_KEY

S3_PREFIX="${S3_PREFIX#/}"
S3_PREFIX="${S3_PREFIX%/}"
if [[ -n "$S3_PREFIX" && ! "$S3_PREFIX" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]]; then
  fail "S3_PREFIX contains unsupported characters"
  exit 1
fi
S3_KEY_PREFIX="${S3_PREFIX:+${S3_PREFIX}/}"

if [[ ! "$MYSQL_PORT" =~ ^[0-9]+$ ]]; then
  fail "MYSQL_PORT must be numeric"
  exit 1
fi
if [[ ! "$GZIP_LEVEL" =~ ^[1-9]$ ]]; then
  fail "GZIP_LEVEL must be between 1 and 9"
  exit 1
fi
case "$MYSQL_SSL_MODE" in
  DISABLED|PREFERRED|REQUIRED|VERIFY_CA|VERIFY_IDENTITY) ;;
  *)
    fail "MYSQL_SSL_MODE must be DISABLED, PREFERRED, REQUIRED, VERIFY_CA or VERIFY_IDENTITY"
    exit 1
    ;;
esac

require_command "$MYSQL_BIN"
require_command "$MYSQLDUMP_BIN"
require_command "$AWS_BIN"
require_command gzip

if [[ "${BACKUP_LOCK_DISABLED:-false}" != "true" ]]; then
  require_command flock
  exec 9> "$STATE_DIR/backup.lock"
  if ! flock -n 9; then
    fail "another backup is already running"
    exit 1
  fi
fi
write_epoch "$STATE_DIR/last-attempt"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mysql-backup.XXXXXX")"

export MYSQL_PWD="$MYSQL_PASSWORD"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="$S3_REGION"

if [[ -z "${AWS_CONFIG_FILE:-}" ]]; then
  AWS_CONFIG_FILE="$WORK_DIR/aws-config"
  {
    printf '[default]\nregion = %s\n' "$S3_REGION"
    if [[ -n "$S3_ENDPOINT" ]]; then
      printf 'request_checksum_calculation = when_required\n'
      printf 'response_checksum_validation = when_required\n'
      printf 's3 =\n  addressing_style = path\n'
    fi
  } > "$AWS_CONFIG_FILE"
  export AWS_CONFIG_FILE
fi

MYSQL_CONNECTION_ARGS=(
  --host="$MYSQL_HOST"
  --port="$MYSQL_PORT"
  --user="$MYSQL_USER"
  --protocol=TCP
  --ssl-mode="$MYSQL_SSL_MODE"
)
MYSQL_ARGS=("${MYSQL_CONNECTION_ARGS[@]}" --batch --skip-column-names)
AWS_ARGS=(--region "$S3_REGION")
if [[ -n "$S3_ENDPOINT" ]]; then
  AWS_ARGS+=(--endpoint-url "$S3_ENDPOINT")
fi

TIMESTAMP="${BACKUP_TIMESTAMP:-$(date +%Y%m%d%H%M%S)}"
if [[ ! "$TIMESTAMP" =~ ^[0-9]{14}$ ]]; then
  fail "backup timestamp must use YYYYMMDDHHmmss"
  exit 1
fi

DATABASE_LIST="$WORK_DIR/databases"
collect_databases "$DATABASE_LIST"

failures=0
DATABASES=()
while IFS= read -r database || [[ -n "$database" ]]; do
  database="$(trim "${database%$'\r'}")"
  [[ -z "$database" ]] && continue
  is_system_database "$database" && continue
  if ! validate_database_name "$database"; then
    log "ERROR: skipping unsupported database name: $database" >&2
    failures=$((failures + 1))
    continue
  fi
  DATABASES+=("$database")
done < "$DATABASE_LIST"

if (( ${#DATABASES[@]} == 0 )); then
  fail "no user databases found"
  exit 1
fi

log "Starting backup; databases=${#DATABASES[@]}"
for database in "${DATABASES[@]}"; do
  if ! backup_database "$database" "$TIMESTAMP"; then
    failures=$((failures + 1))
  fi
done

if (( failures > 0 )); then
  fail "$failures database backup(s) failed"
  exit 1
fi

write_epoch "$STATE_DIR/last-success"
rm -f "$STATE_DIR/last-failure"
log "Backup completed successfully"
