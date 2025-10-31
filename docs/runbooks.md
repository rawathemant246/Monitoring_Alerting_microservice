# Monitoring Platform Runbooks

## Roll back noisy labels
1. Identify offending metrics via query:
   ```bash
   kubectl -n monitoring exec deploy/billing-exporter -- curl -sSk \
     "https://mimir-query-frontend.monitoring.svc.cluster.local/prometheus/api/v1/query" \
     -H 'X-Scope-OrgID: ${TENANT_ID}' \
     --data-urlencode 'query=topk(10, count by (__name__, label_name)(label_replace(scrape_samples_post_metric_relabeling, "label_name", "$1", "__name__", "(.*)")))'
   ```
2. Update relabel configs (typically `k8s/prometheus-operator/relabeling-drop.yaml`).
3. Apply changes: `./scripts/kube_apply.sh`.
4. Verify drop:
   ```bash
   kubectl -n monitoring exec deploy/billing-exporter -- curl -sSk \
     "https://mimir-query-frontend.monitoring.svc.cluster.local/prometheus/api/v1/query" \
     -H 'X-Scope-OrgID: ${TENANT_ID}' \
     --data-urlencode 'query=scrape_class:series_budget:ratio'
   ```

## Add a Prometheus shard
1. Bump `spec.shards` in `k8s/prometheus-operator/prometheus.yaml` and adjust per-pod resources if required.
2. Apply with `./scripts/kube_apply.sh`.
3. Watch rollout: `kubectl -n monitoring rollout status statefulset/prometheus-mimir -w`.
4. Confirm ingestion balance:
   ```bash
   kubectl -n monitoring exec deploy/billing-exporter -- curl -sSk \
     "https://mimir-query-frontend.monitoring.svc.cluster.local/prometheus/api/v1/query" \
     -H 'X-Scope-OrgID: ${TENANT_ID}' \
     --data-urlencode 'query=sum(rate(prometheus_tsdb_ingested_samples_total[5m])) by (shard)'
   ```

## Flush query caches
1. Scale down query frontends and store gateways to zero sequentially to avoid serving errors:
   ```bash
   kubectl -n monitoring scale deploy/mimir-query-frontend --replicas=0
   kubectl -n monitoring scale statefulset/mimir-store-gateway --replicas=0
   ```
2. Delete cache pods (if using external memcached) to drop content:
   ```bash
   kubectl -n monitoring delete pods -l app.kubernetes.io/instance=mimir-query-cache
   kubectl -n monitoring delete pods -l app.kubernetes.io/instance=mimir-index-cache
   ```
3. Restore replicas:
   ```bash
   kubectl -n monitoring scale deploy/mimir-query-frontend --replicas=3
   kubectl -n monitoring scale statefulset/mimir-store-gateway --replicas=4
   ```
4. Validate cache panels in Grafana recover to target hit rates.

## Apply an emergency alert mute
1. Create a silence via CLI:
   ```bash
   kubectl -n monitoring exec deploy/alertmanager-kube-prometheus-alertmanager -- \
     amtool silence add --duration=2h --comment "Emergency mute" \
     --author "${USER}" matcher tenant_id="${TENANT_ID}" matcher alertname="<ALERT>"
   ```
2. Confirm silence:
   ```bash
   kubectl -n monitoring exec deploy/alertmanager-kube-prometheus-alertmanager -- amtool silence query --active
   ```
3. Record the silence ID in the incident channel and schedule removal.

