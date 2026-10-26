#!/bin/bash
# Joins the pod to the tailnet, then hands off to the image's own start command.
#
# Runpod pods are unprivileged containers (no /dev/net/tun, no NET_ADMIN), so
# tailscaled runs with userspace networking: inbound tailnet connections are
# forwarded to the pod's local ports, outbound tailnet traffic goes through the
# SOCKS5/HTTP proxy on localhost:1055.
#
# Tailscale runs in the background and never blocks or fails the pod: the base
# images' start scripts use `set -e`, and a failed hook would restart the pod in
# a loop. Without TS_AUTHKEY this script is a plain pass-through.
#
# Environment:
#   TS_AUTHKEY     auth key (pass as {{ RUNPOD_SECRET_ts_authkey }}); unset = no Tailscale
#   TS_HOSTNAME    tailnet name, default runpod-<pod id>
#   TS_STATE_DIR   node state, default /workspace/.tailscale/<hostname>;
#                  "mem" keeps it in memory (pair with an ephemeral auth key)
#   TS_EXTRA_ARGS  extra flags for `tailscale up`
set -u

TS_SOCKET=/var/run/tailscale/tailscaled.sock
TS_LOG=/var/log/tailscaled.log

ts_log() {
    echo "[tailscale] $*"
}

start_tailscale() {
    local hostname="${TS_HOSTNAME:-runpod-${RUNPOD_POD_ID:-$(hostname)}}"
    local state_dir="${TS_STATE_DIR:-/workspace/.tailscale/${hostname}}"
    local state_flag

    if [[ "$state_dir" == "mem" ]]; then
        state_flag="--state=mem:"
    elif mkdir -p "$state_dir" 2>/dev/null; then
        chmod 700 "$state_dir" 2>/dev/null
        state_flag="--statedir=${state_dir}"
    else
        ts_log "cannot create ${state_dir}; keeping node state in memory"
        state_flag="--state=mem:"
    fi

    mkdir -p "$(dirname "$TS_SOCKET")"
    tailscaled --tun=userspace-networking "$state_flag" --socket="$TS_SOCKET" \
        --socks5-server=localhost:1055 --outbound-http-proxy-listen=localhost:1055 \
        </dev/null >>"$TS_LOG" 2>&1 &

    for _ in $(seq 1 30); do
        [[ -S "$TS_SOCKET" ]] && break
        sleep 1
    done
    if [[ ! -S "$TS_SOCKET" ]]; then
        ts_log "tailscaled did not start; see ${TS_LOG}"
        return 1
    fi

    # TS_EXTRA_ARGS is split on purpose: it carries several flags.
    # shellcheck disable=SC2086
    if ! tailscale --socket="$TS_SOCKET" up --auth-key="$TS_AUTHKEY" \
        --hostname="$hostname" ${TS_EXTRA_ARGS:-} >>"$TS_LOG" 2>&1; then
        ts_log "tailscale up failed; see ${TS_LOG}"
        return 1
    fi

    ts_log "joined the tailnet as ${hostname} ($(tailscale --socket="$TS_SOCKET" ip -4 2>/dev/null))"
}

if [[ -n "${TS_AUTHKEY:-}" ]]; then
    start_tailscale &
else
    ts_log "TS_AUTHKEY not set; skipping Tailscale"
fi

exec "$@"
