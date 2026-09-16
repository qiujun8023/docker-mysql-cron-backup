#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-mysql-cron-backup:integration}"
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8.4}"

NAME="msb-it-$$"
NETWORK="$NAME"
MYSQL_CONTAINER="$NAME-mysql"
SCHEDULER_CONTAINER="$NAME-scheduler"
S3_VOLUME="$NAME-s3"

ROOT_PASSWORD=root-secret
BACKUP_PASSWORD='p"a\ss #;1'
SQL_BACKUP_PASSWORD="${BACKUP_PASSWORD//\\/\\\\}"
TIMESTAMP=20260917030000

log() {
  printf '==> %s\n' "$*"
}

fail_test() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}

cleanup() {
  docker rm -f "$SCHEDULER_CONTAINER" "$MYSQL_CONTAINER" >/dev/null 2>&1 || true
  docker volume rm "$S3_VOLUME" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_for() {
  local description="$1"
  local attempt
  shift
  for attempt in $(seq 1 90); do
    if "$@" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  fail_test "timed out waiting for $description after $attempt attempts"
}

mysql_root() {
  docker exec -i -e MYSQL_PWD="$ROOT_PASSWORD" "$MYSQL_CONTAINER" \
    mysql --protocol=TCP --host=127.0.0.1 --user=root "$@"
}

mysql_value() {
  mysql_root --batch --skip-column-names --execute="$1"
}

backup_env() {
  printf '%s\n' \
    "--network=$NETWORK" \
    "--volume=$PROJECT_ROOT/tests/fake-aws.sh:/opt/fake-aws:ro" \
    "--volume=$S3_VOLUME:/fake-s3" \
    "-e" "MYSQL_HOST=$MYSQL_CONTAINER" \
    "-e" "MYSQL_USER=backup" \
    "-e" "MYSQL_PASSWORD=$BACKUP_PASSWORD" \
    "-e" "S3_BUCKET=mysql-backups" \
    "-e" "AWS_ACCESS_KEY_ID=integration" \
    "-e" "AWS_SECRET_ACCESS_KEY=integration-secret" \
    "-e" "AWS_BIN=/opt/fake-aws" \
    "-e" "MOCK_S3_DIR=/fake-s3"
}

s3_volume() {
  local command="$1"
  shift
  docker run --rm --volume "$S3_VOLUME:/fake-s3:ro" --entrypoint "$command" "$IMAGE" "$@"
}

assert_equal() {
  [[ "$2" == "$3" ]] || fail_test "$1: expected '$3', got '$2'"
}

if [[ "${SKIP_BUILD:-false}" != "true" ]]; then
  log "Building $IMAGE"
  docker build -t "$IMAGE" "$PROJECT_ROOT"
fi

log "Starting MySQL"
docker network create "$NETWORK" >/dev/null
docker volume create "$S3_VOLUME" >/dev/null
docker run -d --name "$MYSQL_CONTAINER" --network "$NETWORK" \
  -e MYSQL_ROOT_PASSWORD="$ROOT_PASSWORD" \
  "$MYSQL_IMAGE" >/dev/null

wait_for MySQL mysql_value 'SELECT 1'

log "Seeding databases"
mysql_root <<SQL
CREATE DATABASE app;
USE app;
CREATE TABLE items (id INT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(50) NOT NULL, payload BLOB);
CREATE TABLE audit (item_id INT NOT NULL);
INSERT INTO items (name, payload) VALUES ('alpha', 0x00FF10), ('beta', NULL);
CREATE VIEW item_names AS SELECT name FROM items;
CREATE TRIGGER items_after_insert AFTER INSERT ON items FOR EACH ROW INSERT INTO audit VALUES (NEW.id);
CREATE PROCEDURE count_items() SELECT COUNT(*) FROM items;
CREATE EVENT daily_noop ON SCHEDULE EVERY 1 DAY DO SELECT 1;
CREATE DATABASE analytics;
CREATE TABLE analytics.metrics (id INT PRIMARY KEY);
CREATE USER 'backup'@'%' IDENTIFIED BY '$SQL_BACKUP_PASSWORD';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, SHOW_ROUTINE ON *.* TO 'backup'@'%';
SQL

log "Running one-off backup"
mapfile -t BACKUP_ENV < <(backup_env)
docker run --rm "${BACKUP_ENV[@]}" \
  -e S3_PREFIX=manual \
  -e BACKUP_TIMESTAMP="$TIMESTAMP" \
  --entrypoint backup.sh \
  "$IMAGE"

objects="$(s3_volume find /fake-s3 -type f)"
grep -qx "/fake-s3/manual/app.$TIMESTAMP.sql.gz" <<< "$objects" || fail_test "app backup missing: $objects"
grep -qx "/fake-s3/manual/analytics.$TIMESTAMP.sql.gz" <<< "$objects" || fail_test "analytics backup missing: $objects"

log "Restoring app backup with the MySQL client"
mysql_value 'DROP DATABASE app'
s3_volume cat "/fake-s3/manual/app.$TIMESTAMP.sql.gz" | gzip -dc | mysql_root

assert_equal "row count" "$(mysql_value 'SELECT COUNT(*) FROM app.items')" 2
assert_equal "blob payload" "$(mysql_value "SELECT HEX(payload) FROM app.items WHERE name = 'alpha'")" 00FF10
assert_equal "view" "$(mysql_value "SELECT COUNT(*) FROM information_schema.VIEWS WHERE TABLE_SCHEMA = 'app'")" 1
assert_equal "trigger" "$(mysql_value "SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = 'app'")" 1
assert_equal "routine" "$(mysql_value "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = 'app'")" 1
assert_equal "event" "$(mysql_value "SELECT COUNT(*) FROM information_schema.EVENTS WHERE EVENT_SCHEMA = 'app'")" 1
mysql_value "INSERT INTO app.items (name) VALUES ('gamma')"
assert_equal "trigger works" "$(mysql_value 'SELECT COUNT(*) FROM app.audit')" 1

log "Running scheduled backup through crond"
docker run -d --name "$SCHEDULER_CONTAINER" "${BACKUP_ENV[@]}" \
  -e S3_PREFIX=scheduled \
  -e BACKUP_CRON='* * * * *' \
  "$IMAGE" >/dev/null

scheduled_backup_done() {
  docker logs "$SCHEDULER_CONTAINER" 2>&1 | grep 'Backup completed successfully' >/dev/null
}
wait_for "scheduled backup" scheduled_backup_done

objects="$(s3_volume find /fake-s3/scheduled -type f)"
grep -q '/app\.[0-9]\{14\}\.sql\.gz$' <<< "$objects" || fail_test "scheduled backup missing: $objects"
docker exec "$SCHEDULER_CONTAINER" /usr/local/bin/healthcheck.sh || fail_test "container should be healthy"

started="$(date +%s)"
docker stop "$SCHEDULER_CONTAINER" >/dev/null
(( $(date +%s) - started < 8 )) || fail_test "container did not stop promptly"

printf 'integration tests passed\n'
