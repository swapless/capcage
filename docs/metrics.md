# Metrics

Pull model: the customer's Prometheus scrapes the pods. Nothing is pushed; nothing leaves
the network.

## Exposed

| Component | Endpoint | Port | Notes |
|---|---|---|---|
| SeaweedFS (object store) | `/metrics` | 9091 | native Prometheus metrics |
| MySQL | `/metrics` | 9104 | `mysqld_exporter` sidecar |
| ingress-nginx | `/metrics` | 10254 | when a controller is present |
| cap-web | — | 3000 | no native metrics; blackbox-probe `/` |
| media-server | `/health` | 3456 | health only; blackbox-probe |

cap-web and media-server expose no Prometheus metrics (Cap is unmodified); cover them with
blackbox up/down + latency probes, which is the SLO signal that matters.

## Scrape — option A: Prometheus Operator

```
helm upgrade cap <chart> -n cap -f <values> \
  --set metrics.serviceMonitor.enabled=true \
  --set metrics.serviceMonitor.labels.release=<prometheus-release>
```

Creates ServiceMonitors for the object store and MySQL exporter.

## Scrape — option B: annotations (no Operator)

The metrics services carry `prometheus.io/{scrape,port,path}` annotations. Discover them:

```yaml
- job_name: cap-endpoints
  kubernetes_sd_configs: [{ role: pod, namespaces: { names: [cap] } }]
  relabel_configs:
    - { source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape], action: keep, regex: "true" }
    - { source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path], action: replace, target_label: __metrics_path__, regex: (.+) }
    - { source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port], action: replace, target_label: __address__, regex: '([^:]+)(?::\d+)?;(\d+)', replacement: $1:$2 }
```

## Blackbox for cap-web / media-server

```yaml
- job_name: cap-blackbox
  metrics_path: /probe
  params: { module: [http_2xx] }
  static_configs: [{ targets: [ "http://cap-web.cap.svc:3000/", "http://cap-media-server.cap.svc:3456/health" ] }]
  relabel_configs:
    - { source_labels: [__address__], target_label: __param_target }
    - { target_label: __address__, replacement: blackbox-exporter.monitoring.svc:9115 }
```

## Network

Scraping is in-cluster and pull-only; nothing egresses. If Prometheus is in another
namespace, add an ingress NetworkPolicy allowing it into `cap` (the default-deny here is
egress-only, so in-cluster ingress scraping already works).

## Suggested alerts

- `up{job=~"cap.*"} == 0` for 5m → component down.
- `mysql_up == 0` → DB down.
- SeaweedFS volume free < 15% → capacity.
- blackbox `probe_success{target=~".*cap-web.*"} == 0` → app not serving.
