# High-Value Test Plan

Execute these scenarios after deploying the stack (consider automating via CI/CD).

## 1. End-to-end ingest
1. Deploy example app + ServiceMonitor:
   ```bash
   kubectl apply -n monitoring -f k8s/tests/sample-app.yaml
   kubectl -n monitoring wait --for=condition=Ready pod -l app=sample-metrics --timeout=3m
   ```
2. Verify the series reach Mimir:
   ```bash
   QF="https://mimir-query-frontend.monitoring.svc.cluster.local/prometheus/api/v1"
   curl -sSk -H "X-Scope-OrgID: ${TENANT_ID}" "${QF}/series" \
     --data-urlencode 'match[]={__name__="sample_request_total"}' \
     --data-urlencode "start=$(date -u -d '5m ago' +%s)" \
     --data-urlencode "end=$(date -u +%s)"
   ```

## 2. Remote_write + compaction + downsampling
1. Query the ingester WAL size and compactor metrics:
   ```bash
   curl -sSk -H "X-Scope-OrgID: ${TENANT_ID}" "${QF}/query" \
     --data-urlencode 'query=sum(rate(cortex_ingester_wal_appender_adds_total[5m]))'
   ```
2. List the bucket for new blocks (expects new blocks within 30 min):
   ```bash
   aws s3 ls s3://${S3_BUCKET}/mimir/ --recursive --summarize --human-readable | tail
   ```
3. Validate downsampling tiers:
   ```bash
   aws s3 ls s3://${S3_BUCKET}/mimir/downsampling/ --recursive | grep -E '\\/(5m|1h)'
   ```
4. Alert check:
   ```bash
   curl -sSk -H "X-Scope-OrgID: ${TENANT_ID}" "${QF}/query" \
     --data-urlencode 'query=max_over_time(MimirCompactorLagging[5m])'
   ```

## 3. Query cache effectiveness
1. Load a 24h Grafana dashboard twice.
2. Inspect cache hit metrics:
   ```bash
   curl -sSk -H "X-Scope-OrgID: ${TENANT_ID}" "${QF}/query" \
     --data-urlencode 'query=cache:query_frontend_result:hit_ratio'
   ```
   Ensure value > 0.6 (warnings fire otherwise).

## 4. Alerting single source of truth
1. Scale Prometheus rules to zero alerts:
   ```bash
   kubectl -n monitoring patch prometheus/mimir --type=merge -p '{"spec":{"ruleSelector":{}}}'
   ```
2. Trigger synthetic alert through ruler (e.g., failing blackbox target) and confirm only Alertmanager receives it.

## 5. Cardinality guardrails
1. Push high-cardinality metrics from sample app (set env `MAX_LABELS=10k`).
2. Watch `SeriesCardinalityBudgetExceeded` fire in Alertmanager and confirm ingestion continues.

## 6. Tenancy & quota enforcement
1. Send traffic with two `X-Scope-OrgID` values via OTel collector.
2. Query long range (>= 10d) and observe `max_query_length` rejection in logs.

## 7. Failure drills
- Kill a querier pod: `kubectl delete pod -l app.kubernetes.io/name=mimir-querier -n monitoring --grace-period=0`
- Block object store via network policy for 2 minutes; observe only cold-block queries fail.
- Delete one Alertmanager pod; verify others continue routing.

## 8. Blackbox probes
- Flip probe endpoint to 500 and confirm `BlackboxProbeFailed` fires and clears when restored.

## 9. Autoscaling
- Stress query frontend CPU (>70%) using `vegeta` load then confirm HPA increases replicas (`kubectl get hpa -n monitoring`).

## 10. Clean up
- Delete sample app manifests and ensure all targets return to healthy state:
  ```bash
  kubectl delete -n monitoring -f k8s/tests/sample-app.yaml
  ```

Document results in your change management system.
