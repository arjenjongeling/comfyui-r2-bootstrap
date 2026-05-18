#!/usr/bin/env bash
set -Eeuo pipefail

COMFYUI_DIR="${COMFYUI_DIR:-/workspace/comfyui}"
COMFYUI_HOST="${COMFYUI_HOST:-0.0.0.0}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"

log() {
    printf '[runtime] %s\n' "$*"
}

fatal() {
    printf '[runtime][fatal] %s\n' "$*" >&2
    exit 1
}

if [ ! -d "${COMFYUI_DIR}" ]; then
    fatal "ComfyUI directory does not exist: ${COMFYUI_DIR}"
fi

if [ ! -f "${COMFYUI_DIR}/main.py" ]; then
    fatal "ComfyUI main.py not found in ${COMFYUI_DIR}"
fi

log "Changing directory to ${COMFYUI_DIR}"
cd "${COMFYUI_DIR}"

log "Starting ComfyUI on ${COMFYUI_HOST}:${COMFYUI_PORT}"
exec python3 main.py --listen "${COMFYUI_HOST}" --port "${COMFYUI_PORT}"
