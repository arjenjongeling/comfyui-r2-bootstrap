#!/usr/bin/env bash
set -Eeuo pipefail

COMFYUI_DIR="${COMFYUI_DIR:-/workspace/comfyui}"
COMFYUI_HOST="${COMFYUI_HOST:-0.0.0.0}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"
COMFYUI_CORS_ORIGIN="${COMFYUI_CORS_ORIGIN:-}"

log() {
    printf '[runtime] %s\n' "$*"
}

configure_cuda13_library_path() {
    local cuda13_lib_dirs
    local cuda13_lib_dir
    local added_lib_dirs=""
    local existing_lib_path="${LD_LIBRARY_PATH:-}"

    if ! command -v python3 >/dev/null 2>&1; then
        log "CUDA 13 library path not enabled: python3 is unavailable for detection"
        return
    fi

    if ! cuda13_lib_dirs="$(python3 - <<'PY'
from importlib import metadata
from pathlib import Path

lib_dirs = set()
for distribution in metadata.distributions():
    name = (distribution.metadata.get("Name") or "").lower().replace("_", "-")
    if not name.startswith("nvidia-") or not name.endswith("-cu13"):
        continue
    for package_file in distribution.files or ():
        path = Path(distribution.locate_file(package_file))
        for parent in path.parents:
            if parent.name == "lib" and "nvidia" in parent.parts and parent.is_dir():
                if any(parent.glob("*.so")) or any(parent.glob("*.so.*")):
                    lib_dirs.add(str(parent))
                break

print(":".join(sorted(lib_dirs)))
PY
)"; then
        log "CUDA 13 library path not enabled: could not inspect Python packages"
        return
    fi

    if [ -z "${cuda13_lib_dirs}" ]; then
        log "CUDA 13 library path not enabled: no installed CUDA 13 NVIDIA libraries found"
        return
    fi

    local IFS=:
    read -r -a cuda13_lib_dirs <<< "${cuda13_lib_dirs}"
    for cuda13_lib_dir in "${cuda13_lib_dirs[@]}"; do
        case ":${existing_lib_path}:" in
            *":${cuda13_lib_dir}:"*)
                ;;
            *)
                if [ -n "${added_lib_dirs}" ]; then
                    added_lib_dirs="${added_lib_dirs}:${cuda13_lib_dir}"
                else
                    added_lib_dirs="${cuda13_lib_dir}"
                fi
                ;;
        esac
    done

    if [ -n "${added_lib_dirs}" ]; then
        if [ -n "${existing_lib_path}" ]; then
            export LD_LIBRARY_PATH="${added_lib_dirs}:${existing_lib_path}"
        else
            export LD_LIBRARY_PATH="${added_lib_dirs}"
        fi
    fi

    log "CUDA 13 library path enabled: ${cuda13_lib_dirs[*]}"
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

configure_cuda13_library_path

args=(python3 main.py --listen "${COMFYUI_HOST}" --port "${COMFYUI_PORT}")

if [ -n "${COMFYUI_CORS_ORIGIN}" ]; then
    log "Enabling ComfyUI CORS header for origin: ${COMFYUI_CORS_ORIGIN}"
    args+=(--enable-cors-header "${COMFYUI_CORS_ORIGIN}")
fi

log "Starting ComfyUI on ${COMFYUI_HOST}:${COMFYUI_PORT}"
exec "${args[@]}"
