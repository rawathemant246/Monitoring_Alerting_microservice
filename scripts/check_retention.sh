#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_ENV_FILE="${ROOT}/.env"
if [[ -f "${DEFAULT_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${DEFAULT_ENV_FILE}"
fi

: "${S3_BUCKET?Set S3_BUCKET in environment or .env}"

if ! command -v aws >/dev/null 2>&1; then
  echo "error: aws CLI is required" >&2
  exit 1
fi

JSON=$(aws s3api get-bucket-lifecycle-configuration --bucket "${S3_BUCKET}" --output json)
if [[ -z "${JSON}" ]]; then
  echo "error: lifecycle configuration empty" >&2
  exit 1
fi

printf '%s' "${JSON}" | python3 <<'PY'
import json
import sys

CONFIG = json.load(sys.stdin)
rules = CONFIG.get("Rules", [])
if not rules:
    sys.exit("Lifecycle rules missing")

transition_ok = False
expiration_ok = False
for rule in rules:
    if rule.get("Status") != "Enabled":
        continue
    transitions = rule.get("Transitions", [])
    for t in transitions:
        if t.get("StorageClass") == "STANDARD_IA" and t.get("Days") == 30:
            transition_ok = True
    expiration = rule.get("Expiration", {})
    if expiration.get("Days") in {365, 366}:
        expiration_ok = True

errors = []
if not transition_ok:
    errors.append("Expected transition to STANDARD_IA after 30 days not found")
if not expiration_ok:
    errors.append("Expected expiration at ~365 days not found")

if errors:
    for err in errors:
        print(f"- {err}")
    sys.exit(1)

print("Lifecycle policy validated: IA @ 30d, expiry @ 365d")
PY
