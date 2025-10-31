# Monitoring and Alerting Platform

Production-ready infrastructure-as-code for a multi-tenant Prometheus → Mimir stack with HA alerting, Grafana dashboards, and tight cost controls.

## Repository Layout

```
terraform/                # AWS object storage, KMS, IAM
k8s/                      # Kubernetes manifests & Helm values
  grafana/                # Grafana values + dashboards
  mimir/                  # Mimir Helm values & runtime limits
  prometheus-operator/    # Prometheus CRD resources, scrape configs
  alerting/               # Ruler rule groups & Alertmanager values
scripts/                  # Helper scripts (apply, secrets, smoke tests)
```

## Prerequisites

- Terraform ≥ 1.5 with AWS credentials capable of creating S3, IAM, and KMS resources.
- kubectl ≥ 1.27 with access to your target Kubernetes cluster.
- Helm ≥ 3.12.
- cert-manager and (optionally) an ingress controller in the target cluster.

## Configuration

Create a `.env` file at the repo root or export the following variables before running any scripts:

| Variable | Description |
|----------|-------------|
| `AWS_REGION` | AWS region for S3 + KMS |
| `S3_BUCKET` | Name for the Mimir object storage bucket |
| `KMS_KEY_ID` | KMS CMK ID or ARN securing the bucket |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Credentials with access to the bucket/KMS |
| `TENANT_ID` | Default tenant identifier (defaults to `single`) |
| `BASE_DOMAIN` | DNS suffix used by ingress (e.g. `example.com`) |
| `CLUSTER_NAME` | Logical cluster label for metrics (defaults to `primary`) |
| `ENVIRONMENT` | Environment label (defaults to `prod`) |
| `MIMIR_REMOTE_WRITE_TOKEN` | Bearer token used by Prometheus remote write |
| `OIDC_CLIENT_ID` / `OIDC_CLIENT_SECRET` / `OIDC_ISSUER` | Grafana OIDC configuration |
| `GF_ROOT_URL` | External Grafana URL (defaults to `https://grafana.${BASE_DOMAIN}`) |
| `ONCALL_EMAIL` | Primary Alertmanager email target |
| `PD_KEY` | PagerDuty routing key |
| `WEBHOOK_URL` | Generic webhook receiver target |
| `GRAFANA_IAM_ROLE_ARN`, `MIMIR_*_ROLE_ARN` | Optional IRSA role ARNs per component |

## Deployment Workflow

1. **Provision AWS primitives**
   ```bash
   cd terraform
   terraform init
   terraform apply
   ```

2. **Generate secrets and runtime config**
   ```bash
   cd ..
   ./scripts/generate_secrets.sh
   ```

3. **Install Helm releases (after exporting the same environment variables in your shell)**
   ```bash
   helm repo add grafana https://grafana.github.io/helm-charts
   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts

    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

    envsubst < k8s/mimir/values.yaml > /tmp/mimir-values.yaml
    helm upgrade --install mimir grafana/mimir-distributed -n monitoring -f /tmp/mimir-values.yaml

   helm upgrade --install prom-operator prometheus-community/kube-prometheus-stack \
     -n monitoring \
     --set grafana.enabled=false \
     --set alertmanager.enabled=false \
     --set kubeStateMetrics.enabled=false \
     --set nodeExporter.enabled=false

   envsubst < k8s/alerting/alertmanager/values.yaml > /tmp/alertmanager-values.yaml
   helm upgrade --install alertmanager prometheus-community/alertmanager \
     -n monitoring -f /tmp/alertmanager-values.yaml

   envsubst < k8s/grafana/values.yaml > /tmp/grafana-values.yaml
   helm upgrade --install grafana grafana/grafana -n monitoring -f /tmp/grafana-values.yaml
   ```

4. **Apply supporting manifests (scrape configs, rules, limits)**
   ```bash
   ./scripts/kube_apply.sh
   ```

5. **Run smoke tests**
   ```bash
   ./scripts/smoke_tests.sh
   ```

The smoke test verifies Mimir queries (including long-range downsampled data) and Alertmanager API health.

## Notes

- All manifests expect cert-manager to issue the `monitoring-ca` cluster issuer defined in `k8s/certs/mtls-issuer.yaml`.
- Dashboards are shipped as JSON under `k8s/grafana/dashboards/` and are packaged into ConfigMaps by `scripts/generate_secrets.sh`.
- Prometheus remote write token, IAM bindings, and OIDC secrets are intentionally externalised to keep sensitive data out of Git.
- For multi-tenant operations extend `k8s/mimir/limits.yaml` with additional tenant overrides and re-run `scripts/generate_secrets.sh`.
