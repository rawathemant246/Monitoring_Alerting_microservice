#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

echo "[1/3] Deleting kind cluster"
kind delete cluster --name moni >/dev/null 2>&1 || echo "kind cluster not found"

if command -v docker >/dev/null 2>&1; then
  echo "[2/3] Stopping docker compose services"
  docker compose -f docker-compose.local.yml down -v >/dev/null 2>&1 || true
fi

echo "[3/3] Cleanup complete"
