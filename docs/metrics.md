# Metrics — the customer scrapes us (pull model)

We expose Prometheus metrics; **your** Prometheus scrapes them. Nothing is pushed
anywhere, no metrics leave your network. This keeps the air-gap intact while giving
you full operational visibility.

## What's exposed

| Component | Endpoint | Port | Notes |
|---|---|---|---|
| Object store (SeaweedFS) | `/metrics` | 9091 | native Prometheus metrics (volume/filer/s3) |
| MySQL | `/metrics` | 9104 | via the `mysqld_exporter` sidecar (connections, queries, buffer pool, replication) |
| ingress-nginx | `/metrics` | 10254 | request rate/latency/status (when the bundled controller is enabled) |
| cap-web (Next.js) | — | 3000 | **no native metrics**; scrape liveness via blackbox probe of `/` |
| media-server | `/health` | 3456 | health only; blackbox probe |

cap-web and media-server expose no Prometheus metrics (we don't modify Cap), so we cover
them with **blackbox/health probing** — up/down + latency — which is what matters for SLOs.

## How to scrape

Two options; pick what your monitoring stack uses.

### A. Prometheus Operator (ServiceMonitors)

If you run kube-prometheus-stack, enable ServiceMonitors and label them for your
Prometheus's selector:
```
helm upgrade cap install/helm/cap -n cap -f <profile> \
  --set metrics.serviceMonitor.enabled=true \
  --set metrics.serviceMonitor.labels.release=kube-prometheus-stack
```
This creates ServiceMonitors for the object store and MySQL exporter in namespace `cap`.

### B. Annotation-based scraping (no Operator)

Every metrics service is annotated so an annotation-relabel scrape config discovers it:
```yaml
# prometheus.yml — add to scrape_configs
- job_name: cap-endpoints
  kubernetes_sd_configs: [{ role: pod, namespaces: { names: [cap] } }]
  relabel_configs:
    - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
      action: keep
      regex: "true"
    - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
      action: replace
      target_label: __metrics_path__
      regex: (.+)
    - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
      action: replace
      target_label: __address__
      regex: ([^:]+)(?::\d+)?;(\d+)
      replacement: $1:$2
```

### Blackbox for cap-web / media-server

Point your blackbox-exporter at these (they only need in-cluster reachability):
```yaml
- job_name: cap-blackbox
  metrics_path: /probe
  params: { module: [http_2xx] }
  static_configs:
    - targets:
        - http://cap-web.cap.svc:3000/
        - http://cap-media-server.cap.svc:3456/health
  relabel_configs:
    - source_labels: [__address__]
      target_label: __param_target
    - target_label: __address__
      replacement: blackbox-exporter.monitoring.svc:9115
```

## Network note

Scraping is **pull, in-cluster**. Your Prometheus reaches these pods over the cluster
network; nothing egresses. If your Prometheus lives in another namespace, allow ingress
to `cap` from it (add a NetworkPolicy ingress rule — the default-deny in this repo is
egress-only, so ingress scraping already works within the cluster).

## Suggested alerts / SLOs

- `up{job=~"cap.*"} == 0` for 5m → component down.
- SeaweedFS volume free bytes < 15% → capacity.
- mysqld_exporter `mysql_up == 0` → DB down.
- blackbox `probe_success{target=~".*cap-web.*"} == 0` → app not serving (the SLO signal).
