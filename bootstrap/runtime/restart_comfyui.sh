#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
BOOTSTRAP_DIR="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
ENV_FILE="${BOOTSTRAP_DIR}/r2.env"
START_SCRIPT="${SCRIPT_DIR}/start_comfyui.sh"

COMFYUI_DIR="${COMFYUI_DIR:-/workspace/comfyui}"

log() {
    printf '[restart] %s\n' "$*"
}

fatal() {
    printf '[restart][fatal] %s\n' "$*" >&2
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

install_python_dependencies() {
    local requirements_file="${COMFYUI_DIR}/requirements.txt"
    local custom_requirements_count=0

    if ! command_exists python3; then
        fatal "python3 is required to install ComfyUI dependencies"
    fi

    if [ ! -f "${requirements_file}" ]; then
        fatal "Missing ComfyUI requirements file: ${requirements_file}"
    fi

    log "Installing base ComfyUI Python requirements"
    python3 -m pip install -r "${requirements_file}"

    if [ -d "${COMFYUI_DIR}/custom_nodes" ]; then
        while IFS= read -r custom_requirements_file; do
            custom_requirements_count=$((custom_requirements_count + 1))
            log "Installing custom node requirements: ${custom_requirements_file}"
            python3 -m pip install -r "${custom_requirements_file}"
        done < <(find "${COMFYUI_DIR}/custom_nodes" -mindepth 2 -maxdepth 3 -type f -name requirements.txt | sort)
    fi

    if [ "${custom_requirements_count}" -eq 0 ]; then
        log "No custom node requirements found"
    fi

    if [ -n "${EXTRA_PIP_PACKAGES:-}" ]; then
        log "Installing extra Python packages: ${EXTRA_PIP_PACKAGES}"
        # Intentionally split EXTRA_PIP_PACKAGES so users can provide a normal shell-style package list.
        python3 -m pip install ${EXTRA_PIP_PACKAGES}
    fi
}

if [ -f "${ENV_FILE}" ]; then
    log "Loading environment from ${ENV_FILE}"
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
else
    log "No ${ENV_FILE} found; using runtime defaults"
fi

COMFYUI_DIR="${COMFYUI_DIR:-/workspace/comfyui}"

if [ ! -d "${COMFYUI_DIR}" ]; then
    fatal "ComfyUI directory does not exist: ${COMFYUI_DIR}"
fi

if [ ! -f "${COMFYUI_DIR}/main.py" ]; then
    fatal "ComfyUI main.py not found in ${COMFYUI_DIR}"
fi

if [ ! -x "${START_SCRIPT}" ]; then
    fatal "ComfyUI start script is missing or not executable: ${START_SCRIPT}"
fi

install_python_dependencies

export COMFYUI_DIR
export COMFYUI_HOST="${COMFYUI_HOST:-0.0.0.0}"
export COMFYUI_PORT="${COMFYUI_PORT:-8188}"
export COMFYUI_CORS_ORIGIN="${COMFYUI_CORS_ORIGIN:-}"

log "Starting ComfyUI"
exec "${START_SCRIPT}"
