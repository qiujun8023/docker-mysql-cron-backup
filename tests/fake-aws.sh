#!/usr/bin/env bash
set -euo pipefail
args=("$@")
printf '%s\n' "$*" >> "${MOCK_AWS_ARGS_LOG:-/dev/null}"
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
  printf '%s\n' "$key" >> "${MOCK_AWS_LOG:-/dev/null}"
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
