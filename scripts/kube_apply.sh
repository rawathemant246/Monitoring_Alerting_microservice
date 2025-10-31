#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DEFAULT_ENV_FILE="${ROOT}/.env"
if [[ -f "${DEFAULT_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${DEFAULT_ENV_FILE}"
fi

TENANT_ID="${TENANT_ID:-single}"
CLUSTER_NAME="${CLUSTER_NAME:-primary}"
ENVIRONMENT="${ENVIRONMENT:-prod}"
BASE_DOMAIN="${BASE_DOMAIN:-example.com}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "error: kubectl binary not found in PATH." >&2
  exit 1
fi

MANIFESTS=(
  "${ROOT}/k8s/namespaces.yaml"
  "${ROOT}/k8s/certs/mtls-issuer.yaml"
  "${ROOT}/k8s/certs/component-certs.yaml"
  "${ROOT}/k8s/mimir/limits.yaml"
  "${ROOT}/k8s/mimir/autoscaling/hpa.yaml"
  "${ROOT}/k8s/billing-exporter/configmap.yaml"
  "${ROOT}/k8s/billing-exporter/deployment.yaml"
  "${ROOT}/k8s/prometheus-operator/relabeling-drop.yaml"
  "${ROOT}/k8s/prometheus-operator/podMonitors/app-workloads.yaml"
  "${ROOT}/k8s/prometheus-operator/serviceMonitors/mimir.yaml"
  "${ROOT}/k8s/prometheus-operator/serviceMonitors/memcached.yaml"
  "${ROOT}/k8s/prometheus-operator/serviceMonitors/otel-collector.yaml"
  "${ROOT}/k8s/prometheus-operator/recording-rules/cache_health.yaml"
  "${ROOT}/k8s/prometheus-operator/recording-rules/cardinality_guard.yaml"
  "${ROOT}/k8s/prometheus-operator/recording-rules/cpu_mem_net.yaml"
  "${ROOT}/k8s/prometheus-operator/recording-rules/slo_latency_histograms.yaml"
  "${ROOT}/k8s/prometheus-operator/recording-rules/autoscale_signals.yaml"
  "${ROOT}/k8s/prometheus-operator/prometheus.yaml"
)

SUBST_VARS='${TENANT_ID}${CLUSTER_NAME}${ENVIRONMENT}${BASE_DOMAIN}'

kubectl get namespace monitoring >/dev/null 2>&1 || kubectl create namespace monitoring

for manifest in "${MANIFESTS[@]}"; do
  if [[ ! -f "${manifest}" ]]; then
    continue
  fi

  if [[ "${manifest}" == *"/prometheus.yaml" ]]; then
    if ! kubectl api-resources --api-group=monitoring.coreos.com | grep -q "^prometheuses"; then
      echo ">> Skipping ${manifest} (Prometheus CRD missing). Install prometheus-operator first."
      continue
    fi
  fi

  echo ">> Applying ${manifest#${ROOT}/}"
  envsubst "${SUBST_VARS}" < "${manifest}" | kubectl apply -f -
done

echo ">> Apply complete."
