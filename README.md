# runpods

Custom Runpod pod images that join a Tailscale tailnet on boot, so the pod is
reachable by a stable tailnet name and nothing has to be exposed publicly.

| Image | Base | Adds |
| --- | --- | --- |
| `ghcr.io/jakub-k-slys/runpods/tf` | `runpod/base` (Ubuntu 24.04, SSH, JupyterLab) | TensorFlow in `/opt/tf` with a `TensorFlow` Jupyter kernel, Tailscale |
| `ghcr.io/jakub-k-slys/runpods/comfyui` | `runpod/comfyui` (CUDA 12.8) | Tailscale |

Versions are pinned in [`docker-bake.hcl`](docker-bake.hcl). CI builds both images on
every push to `main` and publishes `:latest` and `:sha-<commit>`.

## How Tailscale runs in a pod

Runpod pods are unprivileged containers, without `/dev/net/tun` or `NET_ADMIN`, so
`tailscaled` runs in **userspace networking** mode:

- **Inbound works as usual.** Tailnet connections to the pod are forwarded to its
  local ports: SSH, JupyterLab, ComfyUI.
- **Outbound to the tailnet is proxy-only.** From inside the pod, tailnet hosts are
  reachable through the SOCKS5/HTTP proxy on `localhost:1055`
  (`ALL_PROXY=socks5://localhost:1055`), not transparently.
- **It may relay.** Runpod has no UDP on pod ports. When no direct path forms, traffic
  goes through Tailscale's DERP relays over HTTPS. That works, but with more latency;
  `tailscale ping <pod>` shows `via DERP` or `via <ip>`.

[`common/tailscale/ts-entrypoint.sh`](common/tailscale/ts-entrypoint.sh) starts it in
the background and then `exec`s the image's own `/start.sh`. A Tailscale failure is
logged to `/var/log/tailscaled.log` and never blocks or restarts the pod. Without
`TS_AUTHKEY`, the image behaves exactly like its base.

| Variable | Default | Meaning |
| --- | --- | --- |
| `TS_AUTHKEY` | unset | Auth key. Unset = no Tailscale. |
| `TS_HOSTNAME` | `runpod-<pod id>` | Name on the tailnet. |
| `TS_STATE_DIR` | `/workspace/.tailscale/<hostname>` | Node state, so the pod keeps its identity and name across stop/start. `mem` keeps it in memory (use with an ephemeral key). |
| `TS_EXTRA_ARGS` | unset | Extra flags for `tailscale up`. |

## One-time setup

1. **Tailnet policy.** Add the tag and a one-way grant: you reach the pods, the pods
   reach nothing. A rented GPU box should have no path into the rest of the tailnet.
   If the policy still has a default allow-all rule, narrow it first.

   ```jsonc
   "tagOwners": {
     "tag:runpod": ["autogroup:admin"],
   },
   "grants": [
     {
       "src": ["autogroup:member"],
       "dst": ["tag:runpod"],
       "ip":  ["tcp:22", "tcp:8888", "tcp:8188", "tcp:8080"],
     },
   ],
   ```

2. **Auth key.** In the Tailscale admin console: *Settings → Keys → Generate auth key*,
   **reusable**, **ephemeral**, tag `tag:runpod` (and **pre-approved**, which the console
   offers only when device approval is on). Ephemeral matches the templates'
   `TS_STATE_DIR=mem`: the node disappears from the tailnet shortly after the pod goes
   away. With persistent state instead, use a non-ephemeral key. Auth keys expire after at
   most 90 days; nodes already joined keep working, because tagged nodes have key expiry
   disabled.

3. **Runpod secret.** Store the key as a Runpod secret named `ts_authkey`. It is
   referenced from the template as `{{ RUNPOD_SECRET_ts_authkey }}`, so it never
   appears in the template or in this repo.

4. **Package visibility.** The GHCR packages inherit the repository's public
   visibility, so Runpod pulls them without registry credentials. If the repository
   ever goes private, either make the packages public or add a registry credential to
   the templates.

## Runpod templates

Two private templates exist in the Runpod account:

| | `runpods-tf` | `runpods-comfyui` |
| --- | --- | --- |
| Template id | `na5e98qdbb` | `bx72oa97x7` |
| Image | `ghcr.io/jakub-k-slys/runpods/tf:sha-02aad72` | `ghcr.io/jakub-k-slys/runpods/comfyui:sha-02aad72` |
| `TS_HOSTNAME` | `runpod-tf` | `runpod-comfy` |
| Container disk | 30 GB | 150 GB (the base's default) |
| Volume at `/workspace` | 20 GB | 50 GB (as the official template) |
| Host CUDA | any | 12.8 – 13.4 (the base needs 12.8+; a newer driver runs it) |
| GPU | any NVIDIA | 16 GB+ VRAM |

`allowedCudaVersions` is matched **exactly** against the host's reported CUDA version,
not as a minimum. The official ComfyUI template's `12.8, 12.9` matches almost no
host once the fleet moves to newer drivers (most were on 13.2 in October 2026), and the
deploy page then offers no GPU at all. Keep the list open upwards. The `comfyui` base is
the CUDA 12.8 line: prefer pre-Blackwell GPUs (RTX 4090, L40S, A6000) until a Blackwell
card has been tried on it, or move the base to Runpod's `cuda13.0` variant.

Common to both:

- **Image tag:** pinned to a commit (`sha-<commit>`), not `latest`, so a pod gets a
  known build and hosts never serve a stale cached `latest`. After a CI build worth
  shipping, point the template at the new tag (*Templates → Edit*, or the Runpod MCP
  `update-template`).
- **Environment:** `TS_AUTHKEY={{ RUNPOD_SECRET_ts_authkey }}`, `TS_HOSTNAME` and
  `TS_STATE_DIR=mem`. In-memory state, because these pods are mostly throwaway: state on
  the template's host-local volume is deleted with the pod and leaves a stale offline node,
  and the next pod then registers as `<name>-1`. With `mem` and an ephemeral key, every
  boot joins as a fresh node under the same name (new 100.x IP) and the old one is removed
  automatically. For a long-lived pod on a network volume, drop `TS_STATE_DIR` to keep
  one identity across stop/start.
  `startJupyter` and `startSsh` are on, so Runpod injects a generated
  `JUPYTER_PASSWORD` (shown on the pod's *Connect* page) and the account's SSH keys as
  `PUBLIC_KEY`.
- **Docker command:** empty. It replaces the image `CMD` (`/start.sh`), and the pod
  would boot without SSH, JupyterLab or ComfyUI.
- **Volume:** the template's volume disk is host-local. For data that must outlive the
  host, pick a network volume at deploy time; it mounts at `/workspace` in its place.
  Only `/workspace` survives a stop/start (and the Tailscale state, when `TS_STATE_DIR`
  is left at its default).
- **Ports:** only `8888/http` (JupyterLab, token-protected) and `22/tcp` (SSH, key
  only), as a way in if Tailscale does not come up. ComfyUI (`8188`, no login) and
  FileBrowser (`8080`, default `admin` / `adminadmin12` unless `FILEBROWSER_PASSWORD` is
  set) are deliberately not exposed: Runpod proxy URLs are public. Reach them over the
  tailnet.

## Connecting

With `TS_HOSTNAME=runpod-tf` / `runpod-comfy`:

- **SSH:** `ssh root@runpod-tf`. The account's SSH keys reach the pod through `PUBLIC_KEY`,
  as on any Runpod image.
- **JupyterLab:** `http://runpod-tf:8888/?token=<JUPYTER_PASSWORD>`. In PyCharm: *Jupyter →
  Add Jupyter Connection → Connect to Jupyter server using URL*, then pick the
  `TensorFlow` kernel. For a remote interpreter, use *On SSH* with `/opt/tf/bin/python`.
- **ComfyUI:** `http://runpod-comfy:8188`, FileBrowser at `:8080`.

The pod keeps its tailnet name across stop/start, unlike Runpod's public TCP ports,
which change on every restart. With `TS_STATE_DIR=mem` the name stays but the 100.x IP
changes, so connect by name.

## Building locally

```bash
docker buildx bake --print            # resolved config
docker buildx bake tf --load          # linux/amd64; slow under emulation on Apple Silicon
TAGS=test docker buildx bake comfyui --push
```

To bump a version, edit `docker-bake.hcl`. For Tailscale, the checksum is at
`https://pkgs.tailscale.com/stable/tailscale_<version>_amd64.tgz.sha256`.

## Verifying a new image

1. The pod log shows `[tailscale] joined the tailnet as <name>`.
2. `tailscale ping <name>` answers; note whether it is direct or via DERP.
3. SSH and the web UIs answer over the tailnet name.
4. tf: `/opt/tf/bin/python -c "import tensorflow as tf; print(tf.config.list_physical_devices('GPU'))"`
   lists the GPU.
5. After a stop/start, the pod comes back under the same name, not `<name>-1`, and
   (with an ephemeral key) its previous node is gone from the machine list.

## Gotchas

- **One name per pod.** Two pods with the same `TS_HOSTNAME` on one network volume
  share a state directory and fight over the node identity.
- **Deleting a node in the admin console** invalidates the stored state. Remove
  `/workspace/.tailscale/<hostname>` so the next boot registers again with the auth key.
- **ComfyUI first boot** copies ComfyUI to `/workspace/runpod-slim` and takes a few
  minutes; "Running" in the console does not mean the UI is up yet.
- **Models belong on the volume, not in the image.** Download them on the pod
  (ComfyUI-Manager, `huggingface-cli`). Uploading them over a DERP-relayed tailnet
  connection is slow.
