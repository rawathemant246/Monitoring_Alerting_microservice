#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

REQUIRED_CMDS=(docker kind kubectl helm curl)

err() {
  echo "error: $*" >&2
}

for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    err "${cmd} is required"
    exit 1
  fi
done

if lsof -i tcp:3000 -sTCP:LISTEN >/dev/null 2>&1; then
  err "port 3000 already in use"
  exit 1
fi

if lsof -i tcp:8080 -sTCP:LISTEN >/dev/null 2>&1; then
  err "port 8080 already in use"
  exit 1
fi

echo "[1/10] Starting local dependencies via docker compose"
docker compose -f docker-compose.local.yml up -d --remove-orphans

until curl -sf http://localhost:9000/minio/health/live >/dev/null; do
  echo "waiting for MinIO..."
  sleep 2
done

if ! kind get clusters | grep -qx "moni"; then
  echo "[2/10] Creating kind cluster 'moni'"
  kind create cluster --name moni --config kind/local-cluster.yaml --wait 90s
else
  echo "[2/10] kind cluster 'moni' already exists"
fi

# Ensure control-plane node can reach docker-compose network
if docker network ls --format '{{.Name}}' | grep -qx 'moni'; then
  docker network connect moni moni-control-plane >/dev/null 2>&1 || true
fi

echo "[3/10] Preparing monitoring namespace"
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

MINIO_ID=$(docker compose -f docker-compose.local.yml ps -q minio)
MEMQ_ID=$(docker compose -f docker-compose.local.yml ps -q memcached-q)
MEMIDX_ID=$(docker compose -f docker-compose.local.yml ps -q memcached-idx)

if [[ -z "${MINIO_ID}" ]]; then
  err "failed to obtain MinIO container id"
  exit 1
fi

MINIO_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${MINIO_ID}")
if [[ -n "${MEMQ_ID}" ]]; then
  MEMQ_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${MEMQ_ID}")
else
  err "memcached-q container not running"
  exit 1
fi

if [[ -n "${MEMIDX_ID}" ]]; then
  MEMIDX_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${MEMIDX_ID}")
else
  err "memcached-idx container not running"
  exit 1
fi

cat <<EON | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: monitoring
spec:
  clusterIP: None
  ports:
    - name: http
      port: 9000
      targetPort: 9000
---
apiVersion: v1
kind: Endpoints
metadata:
  name: minio
  namespace: monitoring
subsets:
  - addresses:
      - ip: ${MINIO_IP}
    ports:
      - name: http
        port: 9000
---
apiVersion: v1
kind: Service
metadata:
  name: memcached-q
  namespace: monitoring
spec:
  clusterIP: None
  ports:
    - name: memcached
      port: 11211
      targetPort: 11211
---
apiVersion: v1
kind: Endpoints
metadata:
  name: memcached-q
  namespace: monitoring
subsets:
  - addresses:
      - ip: ${MEMQ_IP}
    ports:
      - name: memcached
        port: 11211
---
apiVersion: v1
kind: Service
metadata:
  name: memcached-idx
  namespace: monitoring
spec:
  clusterIP: None
  ports:
    - name: memcached
      port: 11211
      targetPort: 11211
---
apiVersion: v1
kind: Endpoints
metadata:
  name: memcached-idx
  namespace: monitoring
subsets:
  - addresses:
      - ip: ${MEMIDX_IP}
    ports:
      - name: memcached
        port: 11211
EON

echo "[4/10] Creating MinIO bucket"
docker run --rm --network=moni --entrypoint /bin/sh minio/mc:latest \
  -c "mc alias set local http://minio:9000 minio minio123 && mc mb --ignore-existing local/mimir-tsdb && mc mb --ignore-existing local/mimir-ruler" >/dev/null

echo "[5/10] Installing Helm CRDs"
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null
helm upgrade --install prom-crds prometheus-community/prometheus-operator-crds --namespace monitoring --create-namespace >/dev/null
kubectl wait --for=condition=Established crd/prometheusagents.monitoring.coreos.com --timeout=60s >/dev/null || true

echo "[6/10] Deploying Mimir single-binary"
helm upgrade --install mimir grafana/mimir-distributed \
  -n monitoring \
  -f k8s/mimir/values-local.yaml

echo "[7/10] Deploying Prometheus Agent"
kubectl apply -f k8s/prometheus-operator/prom-agent-local.yaml


echo "[8/10] Deploying Alertmanager"
helm upgrade --install alertmanager prometheus-community/alertmanager \
  -n monitoring \
  -f k8s/alerting/alertmanager/local-values.yaml


echo "[9/10] Deploying Grafana"
helm upgrade --install grafana grafana/grafana \
  -n monitoring \
  -f k8s/grafana/values-local.yaml

kubectl apply -f k8s/local-overrides.yaml

kubectl rollout status statefulset/mimir -n monitoring --timeout=120s >/dev/null || true
kubectl rollout status deployment/mimir -n monitoring --timeout=120s >/dev/null || true
kubectl rollout status deployment/grafana -n monitoring --timeout=120s >/dev/null || true

cat <<MSG

Local monitoring stack is up!
  Grafana UI:        http://localhost:3000 (admin/admin)
  Query Frontend:    http://localhost:8080
  MinIO Console:     http://localhost:9000 (minio/minio123)

When finished, run ./scripts/local_down.sh
MSG
