#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DEFAULT_ENV_FILE="${ROOT}/.env"
if [[ -f "${DEFAULT_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${DEFAULT_ENV_FILE}"
fi

: "${TENANT_ID:=single}"

REQUIRED_BINARIES=(kubectl)
for bin in "${REQUIRED_BINARIES[@]}"; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "error: ${bin} binary not found in PATH." >&2
    exit 1
  fi
done

: "${NEW_AWS_ACCESS_KEY_ID?Set NEW_AWS_ACCESS_KEY_ID with the replacement key.}"
: "${NEW_AWS_SECRET_ACCESS_KEY?Set NEW_AWS_SECRET_ACCESS_KEY with the replacement secret.}"
: "${NEW_OIDC_CLIENT_SECRET?Set NEW_OIDC_CLIENT_SECRET for Grafana OIDC rotation.}"

MAYBE_REMOTE_WRITE="${NEW_MIMIR_REMOTE_WRITE_TOKEN:-}"

update_secret() {
  local name=$1
  shift
  kubectl -n monitoring create secret generic "${name}" "$@" --dry-run=client -o yaml | kubectl apply -f -
}

rollout_restart() {
  local kind=$1
  local name=$2
  kubectl -n monitoring rollout restart "${kind}/${name}"
  kubectl -n monitoring rollout status "${kind}/${name}" --timeout=5m
}

echo ">> Rotating AWS credentials in mimir-aws secret"
update_secret mimir-aws \
  --from-literal=AWS_ACCESS_KEY_ID="${NEW_AWS_ACCESS_KEY_ID}" \
  --from-literal=AWS_SECRET_ACCESS_KEY="${NEW_AWS_SECRET_ACCESS_KEY}" \
  --from-literal=AWS_REGION="${AWS_REGION}"

for workload in statefulset/mimir-ingester statefulset/mimir-querier statefulset/mimir-store-gateway deployment/mimir-query-frontend deployment/mimir-ruler; do
  echo ">> Restarting ${workload} to pick up new AWS credentials"
  kubectl -n monitoring rollout restart "${workload}"
  kubectl -n monitoring rollout status "${workload}" --timeout=5m || true
done

echo ">> Rotating Grafana OIDC client secret"
update_secret grafana-oidc \
  --from-literal=client_id="${OIDC_CLIENT_ID}" \
  --from-literal=client_secret="${NEW_OIDC_CLIENT_SECRET}" \
  --from-literal=issuer="${OIDC_ISSUER}" \
  --from-literal=root_url="${GF_ROOT_URL:-https://grafana.${BASE_DOMAIN:-example.com}}"
rollout_restart deployment grafana

if [[ -n "${MAYBE_REMOTE_WRITE}" ]]; then
  echo ">> Updating Prometheus remote write token"
  kubectl -n monitoring create secret generic mimir-remote-write \
    --from-literal=token="${MAYBE_REMOTE_WRITE}" \
    --dry-run=client -o yaml | kubectl apply -f -
  rollout_restart statefulset prometheus-mimir
fi

echo ">> Triggering cert-manager renewal for mTLS certificates"
for cert in prometheus-mtls mimir-mtls alertmanager-mtls grafana-tls mimir-gateway-tls; do
  kubectl -n monitoring annotate certificate "${cert}" cert-manager.io/renew=now --overwrite
  kubectl -n monitoring wait certificate "${cert}" --for=condition=Ready --timeout=5m || true
  echo "   - Renewed ${cert}"
done

cat <<ROTMSG

Secret rotation completed. Validate by:
  - Checking Grafana login.
  - Verifying remote-write traffic (if updated).
  - Ensuring cert-manager issued fresh TLS secrets.
ROTMSG
