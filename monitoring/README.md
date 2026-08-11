# Monitoring

One Grafana for the whole machine: the K3s lab, the ~139-container Docker estate
that predates it, and every public hostname Nginx Proxy Manager serves.

Grafana: <https://grafana.servershelf.com> · Prometheus and Alertmanager are
in-cluster only (reach them with `kubectl port-forward`).

## What is scraped

| Source | How | Series |
|---|---|---|
| K3s itself (kubelet, apiserver, CoreDNS) | chart defaults, heavily trimmed | ~14k |
| Host (CPU, memory, disk, network) | node-exporter DaemonSet | ~9.7k |
| Kubernetes objects | kube-state-metrics | ~1.9k |
| **139 Docker containers** | `cadvisor.yaml` DaemonSet | ~2.6k |
| **46 public hostnames** | `probes.yaml` + blackbox exporter | ~1.1k |
| **Authentik** (SSO) | `scrapeconfigs.yaml` via the host bridge | ~390 |
| the demo app | its own ServiceMonitor in `deploy/base` | ~960 |

## Apply order

`kps-values.yaml` and `blackbox-values.yaml` are Helm; the rest is `kubectl apply`.
Nothing here is managed by Argo CD — it watches only `deploy/overlays/prod`.

```bash
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  --version 88.2.0 -n monitoring -f monitoring/kps-values.yaml
helm upgrade --install blackbox prometheus-community/prometheus-blackbox-exporter \
  --version 11.17.2 -n monitoring -f monitoring/blackbox-values.yaml
kubectl apply -f monitoring/host-bridge.yaml
kubectl apply -f monitoring/cadvisor.yaml
kubectl apply -f monitoring/probes.yaml
kubectl apply -f monitoring/scrapeconfigs.yaml
kubectl apply -f monitoring/alert-rules.yaml
```

## Three things that will bite you

**1. `release: kps` is mandatory on `Probe`, `ScrapeConfig` and `PrometheusRule`.**
Those selectors are `matchLabels{release: kps}`. Without the label the object is
accepted by the API and then silently ignored — which looks exactly like "the
target is down". Check the label before debugging anything else.
(`ServiceMonitor` is exempt; its selector is `{}`.)

**2. The admission webhook is disabled**, so a malformed `PrometheusRule` is
accepted and then silently fails to load. Always validate first:

```bash
python3 -c "
import yaml
docs=list(yaml.safe_load_all(open('monitoring/alert-rules.yaml')))
print(yaml.dump({'groups':[g for d in docs if d for g in d['spec']['groups']]}))" > /tmp/r.yaml
docker run --rm --entrypoint /bin/promtool -v /tmp/r.yaml:/r.yaml:ro \
  prom/prometheus:v3.1.0 check rules /r.yaml
```

**3. `prometheus_tsdb_head_series` lies for hours after a cardinality change.**
It counts everything still in the head block, including series nothing is writing
to any more. After the kubelet/apiserver trim it read 133k while live ingestion
was already 35k. To see the truth, count live series instead:

```bash
PX=/api/v1/namespaces/monitoring/services/kps-kube-prometheus-stack-prometheus:9090/proxy
kubectl get --raw "$PX/api/v1/query?query=count%20by%20(job)(%7B__name__!%3D%22%22%7D)"
```

## Why the cardinality trim exists

K3s runs the apiserver, scheduler, controller-manager and kubelet in **one process
sharing one Prometheus registry**, so `https://<node>:10250/metrics` serves the
entire control-plane metric set. Scraping both `kubelet` and `apiserver` stored
the same ~40k series twice. Measured before: **115,161 series**, kubelet 55,764 and
apiserver 37,994. After the keep-lists in `kps-values.yaml`: **~33,400** — and the
whole Docker estate fits in the space that freed up.

## Why `host-bridge.yaml` exists

Two Docker firewall behaviours, neither fixable from inside the cluster:

- Docker sets `FORWARD` policy to `DROP` and only accepts traffic to *published*
  ports, so pods cannot reach a container IP on `172.19.0.0/16` (Authentik).
- mailcow adds a `mailcow isolation` rule dropping any TCP forwarded into its
  bridge from another interface, so pods cannot reach postfix either.

Host-originated traffic takes `OUTPUT`, not `FORWARD`, so a `hostNetwork` pod
relays fine. As a bonus, postfix sees SMTP arriving from `127.0.0.1` — already
inside its `mynetworks` — so **Alertmanager needs no mailbox, password or Secret**.

Alertmanager itself is deliberately *not* hostNetwork: its config-reloader sidecar
binds `:8080`, which on this host belongs to the obscura-preview site.

## Alerting

Email to `angeloshaheen@servershelf.com` via the SMTP relay. Verified end-to-end:
postfix logs `status=sent`.

Deliberately quiet. `Watchdog`, `InfoInhibitor`, everything at `severity: info`,
and the chronic host alerts (`NodeSystemSaturation`, `NodeDiskIOSaturation`,
`CPUThrottlingHigh` — all permanently true on this box) route to a null receiver:
visible in the UI, never emailed. Warnings are inhibited while a critical with the
same alertname and instance is active.

## Known-broken hosts

`probes.yaml` keeps four in a `known_broken` group that only alerts at `info`:

- `komga`, `lazylibrarian`, `lidarr` — NPM proxy host exists, no backing container (502)
- `www.envelopee.net` — **no NPM proxy host at all**, so TLS falls through to
  `CN=www.inviteify.net`. The handshake aborts, so it can never report a
  certificate expiry either. A real misconfiguration worth fixing.

When one recovers, move it into `blackbox-internal` — that is the only edit needed;
the alert rules key off `probe_group`, not hostnames.

## Rollback

```bash
kubectl delete -f monitoring/alert-rules.yaml -f monitoring/scrapeconfigs.yaml \
                 -f monitoring/probes.yaml -f monitoring/cadvisor.yaml \
                 -f monitoring/host-bridge.yaml
helm uninstall blackbox -n monitoring
helm rollback kps -n monitoring     # undoes the cardinality trim and Alertmanager
```

Nothing here creates, restarts or modifies a Docker container, and nothing creates
a Docker network — which also means watchtower's nightly sweep has no new surface
to act on.
