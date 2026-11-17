#!/usr/bin/env bash
set -Eeuo pipefail

COMFYUI_DIR="${COMFYUI_DIR:-/workspace/comfyui}"
COMFYUI_HOST="${COMFYUI_HOST:-0.0.0.0}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"
COMFYUI_CORS_ORIGIN="${COMFYUI_CORS_ORIGIN:-}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

log() {
    printf '[runtime] %s\n' "$*"
}

configure_cuda13_environment() {
    local helper="${SCRIPT_DIR}/configure_cuda13.py"
    local configured_library_path

    if [ ! -f "${helper}" ]; then
        fatal "CUDA/PyTorch setup helper is missing: ${helper}"
    fi

    if ! configured_library_path="$(python3 "${helper}")"; then
        fatal "CUDA/PyTorch setup or validation failed; ComfyUI will not be started"
    fi

    export LD_LIBRARY_PATH="${configured_library_path}"
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

configure_cuda13_environment

args=(python3 main.py --listen "${COMFYUI_HOST}" --port "${COMFYUI_PORT}")

if [ -n "${COMFYUI_CORS_ORIGIN}" ]; then
    log "Enabling ComfyUI CORS header for origin: ${COMFYUI_CORS_ORIGIN}"
    args+=(--enable-cors-header "${COMFYUI_CORS_ORIGIN}")
fi

log "Starting ComfyUI on ${COMFYUI_HOST}:${COMFYUI_PORT}"
exec "${args[@]}"
