#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DEFAULT_ENV_FILE="${ROOT}/.env"
if [[ -f "${DEFAULT_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${DEFAULT_ENV_FILE}"
fi

TENANT_ID="${TENANT_ID:-single}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "error: kubectl binary not found in PATH." >&2
  exit 1
fi

run_curl() {
  local name=$1
  shift
  kubectl -n monitoring run "${name}" \
    --image=curlimages/curl:8.8.0 \
    --restart=Never \
    --rm -i \
    --command -- "$@" >/tmp/"${name}".log 2>&1 || {
      echo "✖ ${name} failed:"
      cat /tmp/"${name}".log
      rm -f /tmp/"${name}".log
      exit 1
    }
  echo "✔ ${name} passed"
  rm -f /tmp/"${name}".log
}

echo ">> Waiting for monitoring pods to become Ready"
kubectl -n monitoring wait --for=condition=Ready pod -l app.kubernetes.io/part-of=mimir-observability --timeout=10m >/dev/null || \
  echo "!! Warning: no pods found with app.kubernetes.io/part-of=mimir-observability"
kubectl -n monitoring wait --for=condition=Ready pod -l app.kubernetes.io/name=grafana --timeout=5m >/dev/null || \
  echo "!! Warning: Grafana pods not yet ready"
kubectl -n monitoring wait --for=condition=Ready pod -l app.kubernetes.io/name=alertmanager --timeout=5m >/dev/null || \
  echo "!! Warning: Alertmanager pods not yet ready"

QUERY_ENDPOINT="https://mimir-query-frontend.monitoring.svc.cluster.local/prometheus/api/v1"

run_curl smoke-query sh -c "
  curl -sSk -H 'X-Scope-OrgID: ${TENANT_ID}' '${QUERY_ENDPOINT}/query?query=up' | grep '\"status\":\"success\"'
"

START_TS="$(date -u -d '3 days ago' +%s)"
END_TS="$(date -u +%s)"

run_curl smoke-range sh -c "
  curl -sSk -H 'X-Scope-OrgID: ${TENANT_ID}' '${QUERY_ENDPOINT}/query_range?query=sum(rate(http_requests_total{job!=\"\"}[5m]))&start=${START_TS}&end=${END_TS}&step=300' | grep '\"status\":\"success\"'
"

run_curl smoke-seriestats sh -c "
  curl -sSk -H 'X-Scope-OrgID: ${TENANT_ID}' '${QUERY_ENDPOINT}/query?query=sum(prometheus_tsdb_head_series)' | grep '\"value\"'
"

run_curl smoke-alertmanager sh -c "
  curl -sSk https://alertmanager-operated.monitoring.svc.cluster.local:9093/api/v2/status | grep 'cluster'
"

run_curl smoke-blackbox sh -c "
  curl -sSk -H 'X-Scope-OrgID: ${TENANT_ID}' '${QUERY_ENDPOINT}/query?query=avg_over_time(probe_success[5m])' | grep '\"status\":\"success\"'
"

echo "All smoke tests passed."
