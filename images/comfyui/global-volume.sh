#!/bin/bash
# Points ComfyUI at a Runpod global volume, then hands off to the image's start command.
#
# A global volume is object storage presented as files: fine for models and outputs,
# which are written once and read whole, but it refuses the temporary-file-and-rename
# pattern that installing ComfyUI relies on. So the install stays on /workspace (volume
# disk, network volume or container disk) and only models, inputs and outputs go to
# the global volume.
#
# When $COMFY_GLOBAL_DIR is mounted, this creates the model folders there and writes a
# managed block into /workspace/runpod-slim/comfyui_args.txt, which the base start
# script appends to ComfyUI's arguments. Without the mount it removes that block, so
# the same /workspace also works without a global volume. Like the Tailscale
# entrypoint, it never fails the pod.
#
# Environment:
#   COMFY_GLOBAL_DIR  global volume mount, default /workspace-global
set -u

GLOBAL_DIR="${COMFY_GLOBAL_DIR:-/workspace-global}"
ARGS_FILE=/workspace/runpod-slim/comfyui_args.txt
MODEL_PATHS_TEMPLATE=/opt/runpods/extra_model_paths.yaml
MODEL_PATHS=/opt/runpods/extra_model_paths.rendered.yaml
BEGIN_MARK="# >>> runpods global volume (managed, rewritten on every boot) >>>"
END_MARK="# <<< runpods global volume <<<"
MODEL_DIRS=(checkpoints clip clip_vision configs controlnet diffusers diffusion_models
    embeddings gligen hypernetworks loras photomaker style_models text_encoders unet
    upscale_models vae vae_approx)

gv_log() {
    echo "[global-volume] $*"
}

drop_block() {
    [[ -f "$ARGS_FILE" ]] || return 0
    sed -i "\|^${BEGIN_MARK}\$|,\|^${END_MARK}\$|d" "$ARGS_FILE"
}

setup_global_volume() {
    local dir
    for dir in "${MODEL_DIRS[@]}"; do
        mkdir -p "$GLOBAL_DIR/models/$dir" || return 1
    done
    mkdir -p "$GLOBAL_DIR/input" "$GLOBAL_DIR/output" || return 1
    sed "s|__GLOBAL_DIR__|${GLOBAL_DIR}|" "$MODEL_PATHS_TEMPLATE" >"$MODEL_PATHS" || return 1

    mkdir -p "$(dirname "$ARGS_FILE")" || return 1
    drop_block
    {
        echo "$BEGIN_MARK"
        echo "--extra-model-paths-config $MODEL_PATHS"
        echo "--input-directory $GLOBAL_DIR/input"
        echo "--output-directory $GLOBAL_DIR/output"
        echo "$END_MARK"
    } >>"$ARGS_FILE" || return 1

    # FileBrowser and JupyterLab are rooted at /workspace; give them a way in.
    [[ -e /workspace/global ]] || ln -s "$GLOBAL_DIR" /workspace/global
}

if mountpoint -q "$GLOBAL_DIR" 2>/dev/null; then
    if setup_global_volume; then
        gv_log "models, inputs and outputs on ${GLOBAL_DIR}"
    else
        gv_log "could not prepare ${GLOBAL_DIR}; ComfyUI keeps its local folders"
        drop_block
    fi
else
    drop_block
fi

exec "$@"
