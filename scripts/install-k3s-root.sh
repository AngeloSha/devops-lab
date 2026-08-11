#!/usr/bin/env bash
#
# devops-lab — K3s install. RUN AS ROOT, ONCE.
#
#   sudo bash /home/opencode/devops-lab/scripts/install-k3s-root.sh
#
# Why each flag exists (this host runs ~140 production containers):
#
#   DATA_DIR                  Where containerd images, the sqlite datastore and
#                             local-path PersistentVolumes live. Default is the
#                             k3s default under /var/lib/rancher, which on this
#                             host is an NVMe mirror (~41 GB free after pruning
#                             the Docker build cache). Do NOT move this to /data:
#                             /data is a 15 TB spinning disk that sits at ~95%
#                             utilisation serving the media stack, and a
#                             Kubernetes datastore doing constant small writes
#                             behind a 130 ms queue makes the whole control
#                             plane sluggish. Space is worth less than latency
#                             here, and the Prometheus retention caps in
#                             monitoring/kps-values.yaml keep the footprint small.
#   --disable servicelb       K3s's built-in ServiceLB (klipper) would bind
#                             host ports 80/443 for Traefik and collide with
#                             Nginx Proxy Manager. Traefik is instead pinned to
#                             NodePorts 30080/30443 by the HelmChartConfig below.
#   nodeport-addresses=...    Restricts NodePort exposure to loopback, the NPM
#                             docker gateway and tailscale — so the cluster is
#                             NOT reachable over plain HTTP from the internet.
#   fail-swap-on=false        The host has swap in use; kubelet must not refuse
#                             to start because of it.
#
# It does NOT reboot, does NOT restart Docker, and only ADDS firewall rules.
# Uninstall at any time with: /usr/local/bin/k3s-uninstall.sh

set -euo pipefail

LAB_USER=opencode
NPM_GATEWAY=172.19.0.1        # gateway of the docker network NPM sits on
TAILSCALE_IP=100.123.189.55
DATA_DIR=/var/lib/rancher/k3s # NVMe. See the note above before changing this.

echo "=============================================================="
echo " 1/6  Pre-flight diagnostics (read-only)"
echo "=============================================================="
echo "--- disk (DATA_DIR=${DATA_DIR}) ---"; df -h / /data
echo "--- firewall ---"; ufw status verbose || true
echo "--- ports that must be free (expect NO output) ---"
ss -lntp | grep -E ':(6443|10250|30080|30443)\s' || echo "  6443/10250/30080/30443 all free — good"
echo "--- containers currently running ---"; docker ps -q | wc -l

echo
echo "=============================================================="
echo " 2/6  Firewall: ADD rules only (nothing is flushed or deleted)"
echo "=============================================================="
ufw allow from ${NPM_GATEWAY%.*}.0/16 to any port 30080 proto tcp comment 'NPM -> k3s traefik web'
ufw allow from ${NPM_GATEWAY%.*}.0/16 to any port 30443 proto tcp comment 'NPM -> k3s traefik websecure'
ufw allow from 10.42.0.0/16 comment 'k3s pod CIDR'
ufw allow from 10.43.0.0/16 comment 'k3s service CIDR'

echo
echo "=============================================================="
echo " 3/6  Stage Traefik NodePort config BEFORE install"
echo "=============================================================="
mkdir -p "${DATA_DIR}/server/manifests"
cat > "${DATA_DIR}/server/manifests/traefik-config.yaml" <<'EOF'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    service:
      type: NodePort
      spec:
        type: NodePort
    ports:
      web:
        nodePort: 30080
      websecure:
        nodePort: 30443
EOF
echo "staged ${DATA_DIR}/server/manifests/traefik-config.yaml"

echo
echo "=============================================================="
echo " 4/6  Install K3s server"
echo "=============================================================="
curl -sfL https://get.k3s.io | sh -s - server \
  --data-dir "${DATA_DIR}" \
  --disable servicelb \
  --write-kubeconfig-mode 600 \
  --kubelet-arg=fail-swap-on=false \
  --kube-proxy-arg=nodeport-addresses=127.0.0.0/8,${NPM_GATEWAY}/32,${TAILSCALE_IP}/32

echo
echo "=============================================================="
echo " 5/6  Hand the kubeconfig to ${LAB_USER}"
echo "=============================================================="
mkdir -p /home/${LAB_USER}/.kube
install -m 600 -o ${LAB_USER} -g ${LAB_USER} /etc/rancher/k3s/k3s.yaml /home/${LAB_USER}/.kube/config
chown ${LAB_USER}:${LAB_USER} /home/${LAB_USER}/.kube
echo "wrote /home/${LAB_USER}/.kube/config"

echo
echo "=============================================================="
echo " 6/6  Verification"
echo "=============================================================="
echo "waiting for node to become Ready (up to 120s)..."
k3s kubectl wait --for=condition=Ready node --all --timeout=120s || true
k3s kubectl get nodes -o wide
echo
echo "--- kube-system (expect traefik/coredns/metrics-server/local-path; NO svclb-*) ---"
k3s kubectl -n kube-system get pods
echo
echo "--- traefik service (expect 80:30080 and 443:30443) ---"
k3s kubectl -n kube-system get svc traefik || echo "traefik still deploying; re-check in a minute"
echo
echo "--- host ports 80/443 must STILL belong to nginx-proxy-manager ---"
ss -lntp | grep -E ':(80|443)\s' || true
echo
echo "--- Traefik answering locally (404 = correct, no route yet) ---"
curl -s -o /dev/null -w "  127.0.0.1:30080 -> HTTP %{http_code}\n" --max-time 5 http://127.0.0.1:30080/ || echo "  no answer yet"
echo
echo "--- THE CRITICAL GATE: can Nginx Proxy Manager reach Traefik? ---"
docker exec npm curl -s -o /dev/null -w "  npm -> ${NPM_GATEWAY}:30080 = HTTP %{http_code}\n" --max-time 5 http://${NPM_GATEWAY}:30080/ \
  || echo "  FAILED — tell Claude; fallback is to point NPM at ${TAILSCALE_IP}:30080"
echo
echo "--- containers still running (must match the count from step 1) ---"
docker ps -q | wc -l
df -h / /data
echo
echo "=============================================================="
echo " DONE. Tell Claude the cluster is up."
echo "=============================================================="
