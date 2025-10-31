#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${ROOT}/backup-$(date -u +%Y%m%dT%H%M%SZ)"

mkdir -p "${BACKUP_DIR}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "error: kubectl binary not found in PATH." >&2
  exit 1
fi


echo ">> Exporting Grafana dashboards"
kubectl -n monitoring get configmap grafana-dashboards-observability -o yaml > "${BACKUP_DIR}/grafana-dashboards-observability.yaml"
kubectl -n monitoring get configmap grafana-dashboards-tenant -o yaml > "${BACKUP_DIR}/grafana-dashboards-tenant.yaml"

echo ">> Exporting Alertmanager configuration and silences"
kubectl -n monitoring get secret alertmanager-kube-prometheus-alertmanager -o yaml > "${BACKUP_DIR}/alertmanager-secret.yaml"
kubectl -n monitoring get --raw="/api/v1/namespaces/monitoring/services/https:alertmanager-operated:9093/proxy/api/v2/silences" \
  > "${BACKUP_DIR}/alertmanager-silences.json"

echo ">> Exporting Mimir ruler rules"
kubectl -n monitoring get configmap mimir-ruler-rules -o yaml > "${BACKUP_DIR}/mimir-ruler-rules.yaml"

echo ">> Exporting Prometheus recording rules"
kubectl -n monitoring get prometheusrule -l monitoring.grafana.com/rule-type=recording -o yaml > "${BACKUP_DIR}/prometheus-recording-rules.yaml"

tar -czf "${BACKUP_DIR}.tar.gz" -C "${ROOT}" "$(basename "${BACKUP_DIR}")"
rm -rf "${BACKUP_DIR}"

echo "Backup written to ${BACKUP_DIR}.tar.gz"
