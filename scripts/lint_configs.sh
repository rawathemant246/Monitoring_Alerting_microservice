#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v promtool >/dev/null 2>&1; then
  echo "error: promtool is required for linting (https://prometheus.io/docs/prometheus/latest/getting_started/)." >&2
  exit 1
fi

RULE_DIR="${ROOT}/k8s/prometheus-operator/recording-rules"

STATUS=0
for rule_file in "${RULE_DIR}"/*.yaml; do
  echo ">> promtool check rules ${rule_file#${ROOT}/}"
  if ! promtool check rules "${rule_file}"; then
    STATUS=1
  fi
done

if [[ ${STATUS} -ne 0 ]]; then
  echo "Rule validation failed."
  exit ${STATUS}
fi

echo "All Prometheus recording rules validated."
