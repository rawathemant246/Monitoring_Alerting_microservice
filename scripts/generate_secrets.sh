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
GRAFANA_IAM_ROLE_ARN="${GRAFANA_IAM_ROLE_ARN:-}"
MIMIR_DISTRIBUTOR_ROLE_ARN="${MIMIR_DISTRIBUTOR_ROLE_ARN:-}"
MIMIR_QUERIER_ROLE_ARN="${MIMIR_QUERIER_ROLE_ARN:-}"
MIMIR_QUERY_FRONTEND_ROLE_ARN="${MIMIR_QUERY_FRONTEND_ROLE_ARN:-}"
MIMIR_STORE_GATEWAY_ROLE_ARN="${MIMIR_STORE_GATEWAY_ROLE_ARN:-}"
MIMIR_COMPACTOR_ROLE_ARN="${MIMIR_COMPACTOR_ROLE_ARN:-}"
MIMIR_RULER_ROLE_ARN="${MIMIR_RULER_ROLE_ARN:-}"
GF_ROOT_URL="${GF_ROOT_URL:-https://grafana.${BASE_DOMAIN}}"

REQUIRED_VARS=(
  AWS_REGION
  S3_BUCKET
  KMS_KEY_ID
  AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY
  MIMIR_REMOTE_WRITE_TOKEN
  OIDC_CLIENT_ID
  OIDC_CLIENT_SECRET
  OIDC_ISSUER
  ONCALL_EMAIL
  PD_KEY
  WEBHOOK_URL
)

for var_name in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "error: environment variable ${var_name} must be set." >&2
    exit 1
  fi
done

if ! command -v kubectl >/dev/null 2>&1; then
  echo "error: kubectl binary not found in PATH." >&2
  exit 1
fi

kubectl get namespace monitoring >/dev/null 2>&1 || kubectl create namespace monitoring

upsert_secret() {
  local name=$1
  shift
  kubectl -n monitoring create secret generic "${name}" "$@" --dry-run=client -o yaml | kubectl apply -f -
}

echo ">> Ensuring AWS credentials secret"
upsert_secret mimir-aws \
  --from-literal=AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
  --from-literal=AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
  --from-literal=AWS_REGION="${AWS_REGION}"

echo ">> Ensuring remote-write secret"
SUBST_VARS='${MIMIR_REMOTE_WRITE_TOKEN}'
envsubst "${SUBST_VARS}" < "${ROOT}/k8s/prometheus-operator/remote_write.yaml" | kubectl apply -f -

echo ">> Ensuring Alertmanager receiver secrets"
SUBST_VARS='${ONCALL_EMAIL}${PD_KEY}${WEBHOOK_URL}'
envsubst "${SUBST_VARS}" < "${ROOT}/k8s/alerting/alertmanager/receivers.yaml" | kubectl apply -f -

echo ">> Creating Grafana authentication secrets"
upsert_secret grafana-oidc \
  --from-literal=client_id="${OIDC_CLIENT_ID}" \
  --from-literal=client_secret="${OIDC_CLIENT_SECRET}" \
  --from-literal=issuer="${OIDC_ISSUER}" \
  --from-literal=root_url="${GF_ROOT_URL}"

upsert_secret grafana-alerting \
  --from-literal=email_list="${ONCALL_EMAIL}"

echo ">> Building Grafana dashboard ConfigMaps"
kubectl -n monitoring create configmap grafana-dashboards-observability \
  --from-file=prometheus.json="${ROOT}/k8s/grafana/dashboards/prometheus.json" \
  --from-file=mimir.json="${ROOT}/k8s/grafana/dashboards/mimir.json" \
  --dry-run=client -o yaml \
  | kubectl apply -f -
kubectl -n monitoring label configmap grafana-dashboards-observability grafana_dashboard=true --overwrite
kubectl -n monitoring annotate configmap grafana-dashboards-observability grafana_folder=Observability --overwrite

kubectl -n monitoring create configmap grafana-dashboards-tenant \
  --from-file=slo-overview.json="${ROOT}/k8s/grafana/dashboards/slo-overview.json" \
  --dry-run=client -o yaml \
  | kubectl apply -f -
kubectl -n monitoring label configmap grafana-dashboards-tenant grafana_dashboard=true --overwrite
kubectl -n monitoring annotate configmap grafana-dashboards-tenant grafana_folder="${TENANT_ID}" --overwrite

echo ">> Packaging ruler rules"
declare -a RULER_ARGS=()
while IFS= read -r rule_file; do
  key="$(basename "${rule_file}")"
  RULER_ARGS+=(--from-file="${key}=${rule_file}")
done < <(find "${ROOT}/k8s/alerting/ruler/rules" -type f -name '*.yaml' | sort)
kubectl -n monitoring create configmap mimir-ruler-rules \
  "${RULER_ARGS[@]}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monitoring label configmap mimir-ruler-rules app.kubernetes.io/part-of=mimir-observability --overwrite

cat <<EOF

Generated secrets and ConfigMaps have been applied to the monitoring namespace.
Ensure the following environment variables are exported before running Helm releases:
  TENANT_ID=${TENANT_ID}
  CLUSTER_NAME=${CLUSTER_NAME}
  ENVIRONMENT=${ENVIRONMENT}
  BASE_DOMAIN=${BASE_DOMAIN}
EOF
