#!/usr/bin/env bash
#
# devops-lab — everything after K3s exists. Run as the normal user (NO sudo).
#
#   bash /home/opencode/devops-lab/scripts/bootstrap-cluster.sh
#
# Phase 4: deploy the app manually (proves the manifests before Argo owns them)
# Phase 6: install Argo CD and hand it ownership of those same manifests
# Phase 7: install kube-prometheus-stack, then ship the ServiceMonitor via GitOps
#
# Idempotent: safe to re-run. Each phase verifies before the next begins.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"
export PATH="$HOME/.local/bin:$PATH"

hr() { echo; echo "=============================================================="; echo " $*"; echo "=============================================================="; }

hr "Preconditions"
kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: no cluster. Run scripts/install-k3s-root.sh as root first."; exit 1; }
kubectl get nodes

# On a fresh cluster Traefik arrives via a Helm install Job, which can take a
# few minutes to pull. Wait for it rather than failing the run.
echo
echo -n "waiting for Traefik to be installed by its Helm job "
for _ in $(seq 1 60); do
  kubectl -n kube-system get svc traefik >/dev/null 2>&1 && break
  echo -n "."
  sleep 10
done
echo
kubectl -n kube-system get svc traefik >/dev/null 2>&1 || {
  echo "ERROR: Traefik never appeared. Check: kubectl -n kube-system get pods,jobs"
  exit 1
}
echo "Traefik NodePorts:"
kubectl -n kube-system get svc traefik -o jsonpath='{range .spec.ports[*]}  {.name}: {.port} -> nodePort {.nodePort}{"\n"}{end}'
kubectl -n kube-system rollout status deploy/traefik --timeout=300s

hr "Phase 4 — deploy the app (manual kubectl, pre-GitOps)"
kubectl apply -k deploy/overlays/prod
if ! kubectl -n devops-lab rollout status deploy/devops-lab --timeout=180s; then
  echo
  echo "Rollout failed. Most likely cause: the GHCR package is still private."
  echo "Fix: https://github.com/users/AngeloSha/packages/container/devops-lab/settings -> Change visibility -> Public"
  kubectl -n devops-lab get pods
  kubectl -n devops-lab describe pod -l app=devops-lab | tail -20
  exit 1
fi
kubectl -n devops-lab get pods,svc,ingress
echo
echo "--- through Traefik, routed by Host header ---"
curl -s -H 'Host: devops-lab.servershelf.com' --max-time 10 http://127.0.0.1:30080/ ; echo
curl -s -H 'Host: devops-lab.servershelf.com' --max-time 10 http://127.0.0.1:30080/metrics | grep -m1 app_requests_total || true

hr "Phase 6 — Argo CD"
kubectl get ns argocd >/dev/null 2>&1 || kubectl create namespace argocd
# --server-side is required: the ApplicationSet CRD exceeds the 262144-byte limit
# on the last-applied-configuration annotation that client-side apply writes.
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --server-side --force-conflicts
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

# Dex only provides SSO, which this lab does not use — and its image lives on
# ghcr.io, which containerd on this host cannot currently reach. Local admin
# login works without it.
kubectl -n argocd scale deploy/argocd-dex-server --replicas=0

# TLS terminates at Nginx Proxy Manager, so the server itself speaks plain HTTP.
kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge -p '{"data":{"server.insecure":"true"}}'
kubectl -n argocd rollout restart deploy/argocd-server
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

kubectl apply -f deploy/argocd/ingress.yaml
kubectl apply -f deploy/argocd/application.yaml

echo
echo "waiting for Argo CD to adopt the existing resources..."
for _ in $(seq 1 30); do
  sync_status=$(kubectl -n argocd get application devops-lab -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
  health=$(kubectl -n argocd get application devops-lab -o jsonpath='{.status.health.status}' 2>/dev/null || true)
  [ "$sync_status" = "Synced" ] && [ "$health" = "Healthy" ] && break
  sleep 5
done
kubectl -n argocd get application devops-lab
echo
echo "Argo CD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d; echo

hr "Phase 7 — kube-prometheus-stack"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f monitoring/kps-values.yaml \
  --wait --timeout 15m
kubectl -n monitoring get pods

echo
echo "Grafana admin password:"
kubectl -n monitoring get secret kps-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo

hr "Phase 7b — ship the ServiceMonitor through GitOps (not kubectl)"
# The CRD only exists now, so this is committed *after* the stack is installed —
# and it is delivered by Argo CD, which is the whole point of the exercise.
cat > deploy/base/servicemonitor.yaml <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: devops-lab
  labels:
    app: devops-lab
spec:
  selector:
    matchLabels:
      app: devops-lab
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
EOF
if ! grep -q servicemonitor.yaml deploy/base/kustomization.yaml; then
  printf '  - servicemonitor.yaml\n' >> deploy/base/kustomization.yaml
fi
kustomize build deploy/overlays/prod >/dev/null   # validate before committing
if ! git diff --quiet -- deploy/ || [ -n "$(git status --porcelain deploy/)" ]; then
  git add deploy/base/servicemonitor.yaml deploy/base/kustomization.yaml
  git commit -q -m "monitoring: scrape the app via ServiceMonitor"
  git push -q
  echo "pushed — Argo CD will sync the ServiceMonitor within ~3 minutes"
  kubectl -n argocd patch application devops-lab --type merge -p '{"operation":{"sync":{}}}' >/dev/null 2>&1 || true
fi

hr "Summary"
kubectl get pods -A --field-selector=status.phase!=Running 2>/dev/null | grep -v Completed || echo "all pods Running"
echo
echo "Local checks (public URLs need the Cloudflare + NPM steps):"
echo "  curl -H 'Host: devops-lab.servershelf.com' http://127.0.0.1:30080/"
echo "  curl -H 'Host: argocd.servershelf.com'     http://127.0.0.1:30080/ -I"
echo "  curl -H 'Host: grafana.servershelf.com'    http://127.0.0.1:30080/ -I"
echo
df -h /data | tail -1
