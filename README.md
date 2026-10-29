# runpods

Custom Runpod pod images that join a Tailscale tailnet on boot, so the pod is
reachable by a stable tailnet name and nothing has to be exposed publicly.

| Image | Base | Adds |
| --- | --- | --- |
| `ghcr.io/jakub-k-slys/runpods/tf` | `runpod/base` (Ubuntu 24.04, SSH, JupyterLab) | TensorFlow in `/opt/tf` with a `TensorFlow` Jupyter kernel, Tailscale |
| `ghcr.io/jakub-k-slys/runpods/comfyui` | `runpod/comfyui` (CUDA 12.8) | Tailscale, models/inputs/outputs on a global volume when one is mounted ([below](#comfyui-with-a-global-volume)) |

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
- **It may relay.** Pod ports carry no UDP, so whether a direct path forms depends on the
  host's NAT. When none does, traffic goes through Tailscale's DERP relays over HTTPS. That
  works, but with more latency; `tailscale ping <pod>` shows `via DERP(<region>)` or
  `via <ip>:<port>`. In the October 2026 tests both Secure Cloud pods went direct and the
  Community Cloud pod relayed (see [Test results](#test-results-2026-10-27)).

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
| `COMFY_GLOBAL_DIR` | `/workspace-global` | comfyui only: where a global volume is mounted ([below](#comfyui-with-a-global-volume)). |

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
- **JupyterLab:** `http://runpod-tf:8888/?token=<JUPYTER_PASSWORD>`, then pick the
  `TensorFlow 2.21.0` kernel (the default `Python 3` kernel has no TensorFlow). The token
  is on the pod's *Connect* page; the Runpod API returns it redacted.
- **PyCharm needs Pro.** A remote Jupyter server (*Settings → Languages & Frameworks →
  Jupyter → Jupyter Servers → +*, URL with the token) and a remote interpreter (*On SSH*,
  `/opt/tf/bin/python`) are both Pro features. The free tier of the unified PyCharm
  (checked on 2026.2.3) excludes the `intellij.jupyter.py.pro` module, so the option to
  add a server never shows up and notebooks run only on a local kernel. Without Pro, use
  JupyterLab in the browser, or VS Code's Jupyter extension (*Select Kernel → Existing
  Jupyter Server*), which takes the same URL for free. The SSH interpreter also needs a
  key in Runpod's *Settings → SSH Public Keys* before the pod is created.
- **ComfyUI:** `http://runpod-comfy:8188`, FileBrowser at `:8080`.

## ComfyUI with a global volume

A Runpod global volume is object storage presented as files: any pod in any data center
can mount it, but it handles only whole-file writes and reads well. Installing ComfyUI
onto it fails (tried 2026-10-29 with the volume at `/workspace`): the base start script
copies ComfyUI with rsync, whose temporary files the volume refuses
(`mkstemp ".<file>.XXXXXX" failed: Operation not permitted`, exit 23), and ComfyUI never
starts. Runpod's own advice is the same: keep the install local, the models global.

So the comfyui image keeps ComfyUI on `/workspace` and puts only models, inputs and
outputs on the global volume. Mount it at **`/workspace-global`** when creating the pod:

```json
"mounts": {"global": [{"volumeId": "<global volume id>", "path": "/workspace-global"}]}
```

A global volume cannot be combined with the template's volume disk, so `/workspace` is
then the container disk: ComfyUI is copied there on every start (~30 s) and anything
else under `/workspace` is lost when the pod stops. Before `/start.sh`,
[`images/comfyui/global-volume.sh`](images/comfyui/global-volume.sh):

- creates `models/<type>/` (checkpoints, loras, vae, …), `input/` and `output/` on the volume;
- writes a managed block into `/workspace/runpod-slim/comfyui_args.txt`, which the base
  script appends to ComfyUI's arguments: `--extra-model-paths-config` (the volume's model
  folders, marked `is_default` so UI downloads land there), `--input-directory` and
  `--output-directory`. Lines outside the block are left alone; without the mount the
  block is removed, so the same `/workspace` works either way;
- links `/workspace/global` to the volume, since FileBrowser and JupyterLab are rooted at
  `/workspace`.

The log line `[global-volume] models, inputs and outputs on /workspace-global` confirms
it ran. `COMFY_GLOBAL_DIR` changes the mount path. Custom nodes stay on `/workspace`
(git repositories and venvs are exactly what object storage handles badly), so with
container-disk `/workspace` they are reinstalled per pod.

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
- **"Running" is not ready.** The console says Running while the host is still pulling
  the image. The first pull on a host takes minutes: the comfyui image is 5.4 GB, 4.9 GB
  of it one layer from the Runpod base, which Docker prints as an endless stream of
  `<layer> Downloading` and Runpod as `still fetching image`. Then ComfyUI's first boot
  copies itself to `/workspace/runpod-slim` (30 s on the host-local volume, several
  minutes on a network volume). Wait for the app's own line, not the pod status.
- **A broken GPU host looks like an image bug.** On one Community Cloud host the GPU was
  visible (`CUDA device count: 1`) but the driver failed to initialise
  (`RuntimeError: CUDA unknown error`), and ComfyUI exited. The same image worked on the
  next host. Terminate the pod and deploy again elsewhere (Secure Cloud was reliable)
  rather than debugging the image.
- **Models belong on the volume, not in the image.** Download them on the pod
  (ComfyUI-Manager, `huggingface-cli`). Uploading them over a DERP-relayed tailnet
  connection is slow.

## Test results (2026-10-27)

Images `sha-02aad72`, templates as above, ephemeral auth key. Times are from the pod
logs, counted from the create call.

| | comfyui, Community | comfyui, Secure | tf, Secure |
| --- | --- | --- | --- |
| GPU, data center | RTX A6000 (host CUDA 13.0) | RTX A6000, EU-SE-1 (13.2) | RTX A4000, EUR-IS-1 (13.2) |
| Price | $0.33/h | $0.59/h | $0.25/h |
| Image pull | ~5.5 min | cached, container up in 5 s | ~7.5 min |
| Tailscale joined | 2 s after container start | 1 s after | 1 s after |
| Path from the Mac | DERP (mad), 76 ms | direct, 38 ms | direct, 66 ms |
| App | ComfyUI exited: `CUDA unknown error` (host fault) | ComfyUI on `cuda:0`, 44 GB VRAM, UI up ~70 s after create | JupyterLab up ~8 min after create, 403 without token |
| Over the tailnet | Jupyter 302, FileBrowser 200 | ComfyUI 200, Jupyter 302, FileBrowser 200 | Jupyter 302 |

Not covered: TensorFlow seeing the GPU from the `TensorFlow` kernel (no notebook was run),
SSH (no key registered on the Runpod account), PyCharm (free tier, see
[Connecting](#connecting)), and whether a pod can reach other tailnet hosts (needs a
shell in the pod). Total cost of the three pods: about $0.22.
