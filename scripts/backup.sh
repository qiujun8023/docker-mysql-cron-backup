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

read_setting() {
  local value_name="$1"
  local file_name="$2"
  local value="${!value_name:-}"
  local file="${!file_name:-}"

  if [[ -n "$value" && -n "$file" ]]; then
    fail "set either $value_name or $file_name, not both"
    return 1
  fi

  if [[ -n "$file" ]]; then
    if [[ ! -r "$file" ]]; then
      fail "$file_name is not readable: $file"
      return 1
    fi
    IFS= read -r value < "$file" || true
    value="${value%$'\r'}"
  fi

  printf -v "$value_name" '%s' "$value"
  export "${value_name?}"
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

cleanup_local_backups() {
  local database="$1"
  local keep="$2"
  local files=()
  local file

  while IFS= read -r file; do
    files+=("$file")
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "${database}.*.sql.gz" -print | sort)

  while (( ${#files[@]} > keep )); do
    log "Removing local backup ${files[0]}"
    if ! rm -f -- "${files[0]}"; then
      fail "could not remove local backup ${files[0]}"
      return 1
    fi
    files=("${files[@]:1}")
  done
}

collect_databases() {
  local destination="$1"
  local query

  if [[ -n "${MYSQL_DATABASES_FILE:-}" ]]; then
    if [[ ! -r "$MYSQL_DATABASES_FILE" ]]; then
      fail "MYSQL_DATABASES_FILE is not readable: $MYSQL_DATABASES_FILE"
      return 1
    fi
    cp "$MYSQL_DATABASES_FILE" "$destination"
    return
  fi

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
  local destination="${BACKUP_DIR}/${basename}"
  local temporary="${BACKUP_DIR}/.${basename}.partial"
  local key="${BACKUP_SERVER_NAME}/${basename}"
  local remote_size
  local local_size

  if [[ -e "$destination" || -e "$temporary" ]]; then
    fail "backup already exists for $database at timestamp $timestamp"
    return 1
  fi

  CURRENT_PARTIAL="$temporary"
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
      | gzip "-$GZIP_LEVEL" -n > "$temporary"; then
    rm -f -- "$temporary"
    CURRENT_PARTIAL=""
    fail "mysqldump failed for $database"
    return 1
  fi

  if ! gzip -t "$temporary"; then
    rm -f -- "$temporary"
    CURRENT_PARTIAL=""
    fail "gzip verification failed for $database"
    return 1
  fi

  if ! mv "$temporary" "$destination"; then
    rm -f -- "$temporary"
    CURRENT_PARTIAL=""
    fail "could not finalize local backup for $database"
    return 1
  fi
  CURRENT_PARTIAL=""
  log "Uploading s3://${S3_BUCKET}/${key}"

  if ! "$AWS_BIN" "${AWS_ARGS[@]}" s3 cp \
      "$destination" "s3://${S3_BUCKET}/${key}" \
      --only-show-errors; then
    fail "S3 upload failed for $database"
    return 1
  fi

  local_size="$(local_file_size "$destination")"
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

  cleanup_local_backups "$database" "$LOCAL_RETENTION_COUNT"
  log "Completed database $database"
}

BACKUP_DIR="${BACKUP_DIR:-/backup}"
BACKUP_SERVER_NAME="${BACKUP_SERVER_NAME:-}"
GZIP_LEVEL="${GZIP_LEVEL:-6}"
LOCAL_RETENTION_COUNT="${LOCAL_RETENTION_COUNT:-2}"
MYSQL_BIN="${MYSQL_BIN:-mysql}"
MYSQLDUMP_BIN="${MYSQLDUMP_BIN:-mysqldump}"
MYSQL_HOST="${MYSQL_HOST:-}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_SSL_MODE="${MYSQL_SSL_MODE:-PREFERRED}"
AWS_BIN="${AWS_BIN:-aws}"
S3_BUCKET="${S3_BUCKET:-mysql-backups}"
S3_REGION="${S3_REGION:-us-east-1}"

mkdir -p "$BACKUP_DIR/.state"
STATE_DIR="$BACKUP_DIR/.state"
CURRENT_PARTIAL=""
DATABASE_LIST=""

on_exit() {
  local status=$?
  trap - EXIT
  if [[ -n "$CURRENT_PARTIAL" ]]; then
    rm -f -- "$CURRENT_PARTIAL" 2>/dev/null || true
  fi
  if [[ -n "$DATABASE_LIST" ]]; then
    rm -f -- "$DATABASE_LIST" 2>/dev/null || true
  fi
  if (( status != 0 )); then
    write_epoch "$STATE_DIR/last-failure" 2>/dev/null || true
  fi
  exit "$status"
}
trap on_exit EXIT

read_setting MYSQL_HOST MYSQL_HOST_FILE
read_setting MYSQL_USER MYSQL_USER_FILE
read_setting MYSQL_PASSWORD MYSQL_PASSWORD_FILE
read_setting AWS_ACCESS_KEY_ID AWS_ACCESS_KEY_ID_FILE
read_setting AWS_SECRET_ACCESS_KEY AWS_SECRET_ACCESS_KEY_FILE

MYSQL_HOST="${MYSQL_HOST:-mysql}"
export MYSQL_HOST

require_value BACKUP_SERVER_NAME
require_value MYSQL_HOST
require_value MYSQL_USER
require_value MYSQL_PASSWORD
require_value S3_BUCKET
require_value S3_ENDPOINT
require_value AWS_ACCESS_KEY_ID
require_value AWS_SECRET_ACCESS_KEY

if [[ ! "$BACKUP_SERVER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  fail "BACKUP_SERVER_NAME contains unsupported characters"
  exit 1
fi
if [[ ! "$MYSQL_PORT" =~ ^[0-9]+$ ]]; then
  fail "MYSQL_PORT must be numeric"
  exit 1
fi
if [[ ! "$GZIP_LEVEL" =~ ^[1-9]$ ]]; then
  fail "GZIP_LEVEL must be between 1 and 9"
  exit 1
fi
if [[ ! "$LOCAL_RETENTION_COUNT" =~ ^[1-9][0-9]*$ ]]; then
  fail "LOCAL_RETENTION_COUNT must be a positive integer"
  exit 1
fi

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

export MYSQL_PWD="$MYSQL_PASSWORD"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="$S3_REGION"

if [[ -z "${AWS_CONFIG_FILE:-}" ]]; then
  AWS_CONFIG_FILE="$STATE_DIR/aws-config"
  printf '[default]\nregion = %s\ns3 =\n  addressing_style = path\n' "$S3_REGION" > "$AWS_CONFIG_FILE"
  chmod 0600 "$AWS_CONFIG_FILE"
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
AWS_ARGS=(--endpoint-url "$S3_ENDPOINT" --region "$S3_REGION")

TIMESTAMP="${BACKUP_TIMESTAMP:-$(date +%Y%m%d%H%M%S)}"
if [[ ! "$TIMESTAMP" =~ ^[0-9]{14}$ ]]; then
  fail "backup timestamp must use YYYYMMDDHHmmss"
  exit 1
fi

DATABASE_LIST="$STATE_DIR/databases.$$"
if ! collect_databases "$DATABASE_LIST"; then
  rm -f "$DATABASE_LIST"
  DATABASE_LIST=""
  exit 1
fi

DATABASES=()
while IFS= read -r database || [[ -n "$database" ]]; do
  database="$(trim "${database%$'\r'}")"
  [[ -z "$database" || "$database" == \#* ]] && continue
  is_system_database "$database" && continue
  if ! validate_database_name "$database"; then
    fail "unsupported database name: $database"
    exit 1
  fi
  DATABASES+=("$database")
done < "$DATABASE_LIST"
rm -f "$DATABASE_LIST"
DATABASE_LIST=""

if (( ${#DATABASES[@]} == 0 )); then
  fail "no user databases found"
  exit 1
fi

log "Starting backup for ${BACKUP_SERVER_NAME}; databases=${#DATABASES[@]}"
failures=0
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
