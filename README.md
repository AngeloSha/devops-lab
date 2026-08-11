# devops-lab

A deliberately small FastAPI service wrapped in a deliberately real platform:
GitHub Actions CI → GHCR → K3s → Argo CD (GitOps) → Prometheus/Grafana, running
on a single self-hosted Ubuntu node **alongside ~140 existing Docker containers
without touching them**.

The app is trivial on purpose. The platform around it is the project.

## Architecture

```
                        GitHub (this repo)
                              │
                         git push (app/**)
                              ▼
                       GitHub Actions
                 lint → test → build → scan-free build
                              │
                    push ghcr.io/angelosha/devops-lab:<sha>
                              │
              CI commits <sha> into deploy/overlays/prod  [skip ci]
                              │
                              ▼
                          Argo CD  ── watches deploy/overlays/prod
                              │        (automated sync, prune, selfHeal)
                              ▼
     ┌────────────────────  K3s (single node)  ────────────────────┐
     │  Namespace devops-lab                                       │
     │  Deployment (probes, limits, non-root) ← ConfigMap + Secret │
     │  Service (ClusterIP) ← Ingress (Traefik, host-routed)       │
     │  ServiceMonitor → Prometheus → Grafana                      │
     └───────────────────────────┬──────────────────────────────---┘
                                 │ Traefik NodePort 30080
                                 ▼
        Nginx Proxy Manager (existing, owns host 80/443, TLS)
                                 ▼
                      Cloudflare → Internet
   https://devops-lab.servershelf.com · argocd.… · grafana.…
```

## Design decisions worth asking me about

- **Why NodePort 30080 instead of the standard LoadBalancer?** The host already
  runs Nginx Proxy Manager on 80/443 for ~30 other sites. K3s was installed with
  `--disable servicelb` and a `HelmChartConfig` pinning Traefik to NodePorts
  30080/30443; NPM forwards each lab hostname to the node port and Traefik
  routes by Host header. Hybrid ingress: one entry point, two proxy layers.
- **Why does CI commit back into its own repo?** Monorepo GitOps: `app/**` is
  the software, `deploy/**` is the desired cluster state. The pipeline builds an
  immutable image, then records the new tag in the prod overlay. Argo CD reacts
  to the *git change*, not to the pipeline — the cluster's state is always
  whatever `deploy/overlays/prod` says. Loop protection is threefold:
  `paths-ignore: deploy/**`, `[skip ci]`, and GITHUB_TOKEN pushes never
  triggering workflows.
- **Why is the data dir on /data?** The root filesystem hosts a large Docker
  estate and sits at ~90%. K3s runs with `--data-dir /data/k3s`, which moves
  containerd images, the sqlite datastore *and* local-path PVs (Prometheus TSDB)
  onto a 2.4 TB filesystem. Prometheus is additionally capped with
  `retention: 2d` / `retentionSize: 4GB`.
- **Why is readiness toggleable at runtime?** `POST /toggle-ready` flips
  `/readyz` to 503 so you can watch Kubernetes remove the pod from the Service
  endpoints (READY 0/1) *without* restarting it — liveness stays green. It makes
  the readiness-vs-liveness distinction observable instead of theoretical.
- **Secrets:** `deploy/base/secret.yaml` is an explicit placeholder — this repo
  is public, and plain `Secret` manifests don't belong in git. The named next
  step is Sealed Secrets or SOPS.

## Drills (chaos practice)

| Drill | Command | What you observe |
|---|---|---|
| Readiness failure | `curl -X POST https://devops-lab.servershelf.com/toggle-ready` | Pod READY 0/1, endpoint removed, 503 from ingress; liveness untouched. Recover via the pod IP directly — the Service no longer routes to it. |
| Self-heal | `kubectl -n devops-lab scale deploy/devops-lab --replicas=3` | Argo CD reverts to the git-declared single replica. |
| Bad image | commit a nonexistent tag in the prod overlay | `ImagePullBackOff`; roll back with `git revert` — GitOps rollback is a git operation. |
| Crash loop | liveness probing a dead port | `CrashLoopBackOff` → `kubectl describe pod` / `logs --previous` workflow. |

## Repo layout

```
app/                      # FastAPI service, tests, Dockerfile (non-root, multi-stage)
deploy/base/              # namespace, configmap, secret (placeholder), deployment,
                          #   service, ingress, servicemonitor — the k8s truth
deploy/overlays/prod/     # kustomize overlay; CI pins the image tag here
deploy/argocd/            # Argo CD Application + ingress (bootstrap records)
monitoring/kps-values.yaml# kube-prometheus-stack sizing/retention caps
.github/workflows/ci.yml  # lint → test → build+push (GHCR) → gitops-commit
```

## Future rounds (pre-wired extension points)

- `terraform/` — first target: the Cloudflare DNS records for the lab hostnames
- `monitoring/loki-values.yaml` — logs beside metrics, same Grafana
- Alertmanager — single values flag flip in `kps-values.yaml`
- Sealed Secrets — replaces the placeholder Secret
