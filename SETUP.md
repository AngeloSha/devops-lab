# Setup — the four things only you can do

Everything else is scripted. Do these in order.

## 1. Grant the `workflow` scope so CI can be pushed

The repo pushed fine, but GitHub refuses to accept `.github/workflows/ci.yml`
from an OAuth token without the `workflow` scope, so the pipeline file is
sitting locally, uncommitted. One command fixes it:

```bash
gh auth refresh -h github.com -s workflow
```

It prints a one-time code and opens github.com/login/device. After that:

```bash
cd /home/opencode/devops-lab && git add .github && git commit -m "ci: pipeline" && git push
```

That first push triggers the build and publishes the container image.

## 2. Make the container image public

Once the build finishes, open
<https://github.com/users/AngeloSha/packages/container/devops-lab/settings>
→ **Change visibility** → **Public**.

Otherwise Kubernetes can't pull it without an imagePullSecret.

## 3. Install K3s (the only root step)

Read it first — it explains every flag and touches nothing that exists:

```bash
sudo bash /home/opencode/devops-lab/scripts/install-k3s-root.sh
```

It ends with a connectivity gate showing whether Nginx Proxy Manager can reach
Traefik. Note that line — everything public depends on it.

Then, unprivileged, the rest of the lab builds itself:

```bash
bash /home/opencode/devops-lab/scripts/bootstrap-cluster.sh
```

## 4. Publish the three hostnames

**Cloudflare** → servershelf.com → DNS → three `A` records pointing at this
server, proxied exactly like your existing hosts:

| Name | Type | Content |
|---|---|---|
| `devops-lab` | A | server public IP |
| `argocd` | A | server public IP |
| `grafana` | A | server public IP |

**Nginx Proxy Manager** (`http://<server>:81`) → Proxy Hosts → Add, three times.
All three forward to the *same* port — Traefik routes them apart by hostname:

| Domain | Scheme | Forward Host | Port | Extra |
|---|---|---|---|---|
| devops-lab.servershelf.com | http | `172.19.0.1` | 30080 | Block Common Exploits |
| argocd.servershelf.com | http | `172.19.0.1` | 30080 | **Websockets ON** |
| grafana.servershelf.com | http | `172.19.0.1` | 30080 | **Websockets ON** |

SSL tab on each: request a Let's Encrypt certificate and Force SSL, same as your
other sites. If the connectivity gate in step 3 failed, use `100.123.189.55`
(the tailscale IP) as the Forward Host instead.
