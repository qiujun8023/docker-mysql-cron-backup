#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_SCRIPT="$PROJECT_ROOT/scripts/backup.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mysql-scheduled-backup.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass_count=0

pass() {
  printf 'PASS %s\n' "$1"
  pass_count=$((pass_count + 1))
}

fail_test() {
  printf 'FAIL %s: %s\n' "$1" "$2" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail_test "$2" "missing file $1"
}

assert_no_match() {
  if find "$1" -type f -name "$2" | grep -q .; then
    fail_test "$3" "unexpected file matching $2"
  fi
}

create_mocks() {
  local root="$1"
  mkdir -p "$root/bin" "$root/s3"

  cat > "$root/bin/mysql" <<'MOCK'
#!/usr/bin/env bash
printf '%b' "${MOCK_DATABASES:-information_schema\nmysql\nperformance_schema\nsys\napp\nanalytics\n}"
MOCK

  cat > "$root/bin/mysqldump" <<'MOCK'
#!/usr/bin/env bash
database="${!#}"
if [[ "${MOCK_FAIL_DATABASE:-}" == "$database" ]]; then
  exit 23
fi
printf '%s\n' "CREATE DATABASE IF NOT EXISTS \`$database\`;" "USE \`$database\`;" "SELECT '$database';"
MOCK

  cat > "$root/bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
index=0
while (( index < ${#args[@]} )); do
  case "${args[$index]}" in
    s3|s3api) break ;;
  esac
  index=$((index + 1))
done
command="${args[$index]:-}"
if [[ "$command" == "s3" && "${args[$((index + 1))]:-}" == "cp" ]]; then
  source_file="${args[$((index + 2))]}"
  uri="${args[$((index + 3))]}"
  object="${uri#s3://}"
  key="${object#*/}"
  destination="$MOCK_S3_DIR/$key"
  mkdir -p "$(dirname "$destination")"
  cp "$source_file" "$destination"
  printf '%s\n' "$key" >> "$MOCK_AWS_LOG"
  exit 0
fi
if [[ "$command" == "s3api" && "${args[$((index + 1))]:-}" == "head-object" ]]; then
  key=""
  index=$((index + 2))
  while (( index < ${#args[@]} )); do
    if [[ "${args[$index]}" == "--key" ]]; then
      key="${args[$((index + 1))]}"
      break
    fi
    index=$((index + 1))
  done
  size="$(wc -c < "$MOCK_S3_DIR/$key" | tr -d '[:space:]')"
  if [[ "${MOCK_SIZE_MISMATCH:-false}" == "true" ]]; then
    size=$((size + 1))
  fi
  printf '%s\n' "$size"
  exit 0
fi
exit 64
MOCK

  chmod +x "$root/bin/mysql" "$root/bin/mysqldump" "$root/bin/aws"
}

run_backup() {
  local root="$1"
  shift
  env \
    PATH="$root/bin:$PATH" \
    BACKUP_DIR="$root/backup" \
    BACKUP_LOCK_DISABLED=true \
    BACKUP_SERVER_NAME=tencent-tky-001 \
    BACKUP_TIMESTAMP=20260917013000 \
    LOCAL_RETENTION_COUNT=2 \
    MYSQL_HOST=mysql \
    MYSQL_USER=backup \
    MYSQL_PASSWORD=secret \
    AWS_ACCESS_KEY_ID=mysql-backup \
    AWS_SECRET_ACCESS_KEY=secret \
    MOCK_AWS_LOG="$root/aws.log" \
    MOCK_S3_DIR="$root/s3" \
    S3_BUCKET=mysql-backups \
    S3_ENDPOINT=https://s3.example.test \
    "$@" \
    bash "$BACKUP_SCRIPT"
}

test_happy_path() {
  local name=happy_path
  local root="$TEST_ROOT/$name"
  create_mocks "$root"
  mkdir -p "$root/backup"

  run_backup "$root"

  assert_file "$root/backup/app.20260917013000.sql.gz" "$name"
  assert_file "$root/backup/analytics.20260917013000.sql.gz" "$name"
  assert_file "$root/s3/tencent-tky-001/app.20260917013000.sql.gz" "$name"
  assert_file "$root/s3/tencent-tky-001/analytics.20260917013000.sql.gz" "$name"
  assert_file "$root/backup/.state/last-success" "$name"
  assert_no_match "$root" 'latest.*' "$name"
  assert_no_match "$root/s3" 'mysql.*.sql.gz' "$name"
  pass "$name"
}

test_local_retention() {
  local name=local_retention
  local root="$TEST_ROOT/$name"
  create_mocks "$root"
  mkdir -p "$root/backup"
  printf old | gzip -n > "$root/backup/app.20260914013000.sql.gz"
  printf old | gzip -n > "$root/backup/app.20260915013000.sql.gz"
  printf old | gzip -n > "$root/backup/app.20260916013000.sql.gz"

  run_backup "$root" MYSQL_DATABASES=app

  [[ "$(find "$root/backup" -maxdepth 1 -name 'app.*.sql.gz' | wc -l | tr -d '[:space:]')" == 2 ]] \
    || fail_test "$name" "expected two local backups"
  [[ ! -e "$root/backup/app.20260915013000.sql.gz" ]] \
    || fail_test "$name" "old backup was not removed"
  assert_file "$root/backup/app.20260916013000.sql.gz" "$name"
  assert_file "$root/backup/app.20260917013000.sql.gz" "$name"
  pass "$name"
}

test_partial_failure() {
  local name=partial_failure
  local root="$TEST_ROOT/$name"
  create_mocks "$root"
  mkdir -p "$root/backup"

  if run_backup "$root" MYSQL_DATABASES=app,broken MOCK_FAIL_DATABASE=broken; then
    fail_test "$name" "backup unexpectedly succeeded"
  fi

  assert_file "$root/s3/tencent-tky-001/app.20260917013000.sql.gz" "$name"
  assert_file "$root/backup/.state/last-failure" "$name"
  [[ ! -e "$root/backup/.state/last-success" ]] \
    || fail_test "$name" "success marker exists after failure"
  assert_no_match "$root/backup" '.*.partial' "$name"
  pass "$name"
}

test_remote_size_mismatch() {
  local name=remote_size_mismatch
  local root="$TEST_ROOT/$name"
  create_mocks "$root"
  mkdir -p "$root/backup"

  if run_backup "$root" MYSQL_DATABASES=app MOCK_SIZE_MISMATCH=true; then
    fail_test "$name" "backup unexpectedly succeeded"
  fi

  assert_file "$root/backup/.state/last-failure" "$name"
  pass "$name"
}

test_healthcheck() {
  local name=healthcheck
  local root="$TEST_ROOT/$name"
  local now
  mkdir -p "$root/backup/.state"
  now="$(date +%s)"

  printf '%s\n' "$now" > "$root/backup/.state/started-at"
  BACKUP_DIR="$root/backup" HEALTHCHECK_MAX_AGE_SECONDS=60 \
    bash "$PROJECT_ROOT/scripts/healthcheck.sh" \
    || fail_test "$name" "fresh container should be healthy"

  printf '%s\n' "$now" > "$root/backup/.state/last-success"
  printf '%s\n' "$((now + 1))" > "$root/backup/.state/last-failure"
  if BACKUP_DIR="$root/backup" HEALTHCHECK_MAX_AGE_SECONDS=60 \
      bash "$PROJECT_ROOT/scripts/healthcheck.sh"; then
    fail_test "$name" "newer failure should be unhealthy"
  fi

  printf '%s\n' "$((now + 2))" > "$root/backup/.state/last-success"
  BACKUP_DIR="$root/backup" HEALTHCHECK_MAX_AGE_SECONDS=60 \
    bash "$PROJECT_ROOT/scripts/healthcheck.sh" \
    || fail_test "$name" "newer success should recover health"
  pass "$name"
}

test_file_credentials() {
  local name=file_credentials
  local root="$TEST_ROOT/$name"
  create_mocks "$root"
  mkdir -p "$root/backup" "$root/secrets"
  printf '%s\n' backup > "$root/secrets/mysql_user"
  printf '%s\n' mysql-secret > "$root/secrets/mysql_password"
  printf '%s\n' mysql-backup > "$root/secrets/s3_access_key"
  printf '%s\n' s3-secret > "$root/secrets/s3_secret_key"

  run_backup "$root" \
    MYSQL_DATABASES=app \
    MYSQL_USER= \
    MYSQL_USER_FILE="$root/secrets/mysql_user" \
    MYSQL_PASSWORD= \
    MYSQL_PASSWORD_FILE="$root/secrets/mysql_password" \
    AWS_ACCESS_KEY_ID= \
    AWS_ACCESS_KEY_ID_FILE="$root/secrets/s3_access_key" \
    AWS_SECRET_ACCESS_KEY= \
    AWS_SECRET_ACCESS_KEY_FILE="$root/secrets/s3_secret_key"

  assert_file "$root/s3/tencent-tky-001/app.20260917013000.sql.gz" "$name"
  pass "$name"
}

test_happy_path
test_local_retention
test_partial_failure
test_remote_size_mismatch
test_healthcheck
test_file_credentials

printf '%s tests passed\n' "$pass_count"
