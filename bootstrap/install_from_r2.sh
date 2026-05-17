#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ENV_FILE="${SCRIPT_DIR}/r2.env"

log() {
    printf '[bootstrap] %s\n' "$*"
}

fatal() {
    printf '[bootstrap][fatal] %s\n' "$*" >&2
    exit 1
}

require_env() {
    local name="$1"
    if [ -z "${!name:-}" ]; then
        fatal "Missing required setting: ${name}"
    fi
}

if [ ! -f "${ENV_FILE}" ]; then
    fatal "Missing ${ENV_FILE}. Copy bootstrap/r2.env.example to bootstrap/r2.env and fill in your R2 settings."
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

require_env "R2_REMOTE_NAME"
require_env "R2_BUCKET_NAME"
require_env "R2_ENDPOINT"
require_env "R2_ACCESS_KEY_ID"
require_env "R2_SECRET_ACCESS_KEY"
require_env "R2_COMFYUI_PREFIX"
require_env "COMFYUI_DIR"

START_COMFYUI="${START_COMFYUI:-true}"

log "Loaded configuration from ${ENV_FILE}"
log "Target ComfyUI directory: ${COMFYUI_DIR}"
log "R2 source: ${R2_REMOTE_NAME}:${R2_BUCKET_NAME}/${R2_COMFYUI_PREFIX}"

cat <<'EOF'

This bootstrap script is currently a scaffold.

Planned implementation:
1. Install rclone when it is not available.
2. Configure an rclone remote for Cloudflare R2.
3. Validate access to the configured bucket/prefix.
4. Install or update ComfyUI in COMFYUI_DIR.
5. Sync models, custom nodes, workflows, and user data from R2.
6. Start ComfyUI through bootstrap/runtime/start_comfyui.sh.

EOF

fatal "R2 restore implementation is not complete yet."
