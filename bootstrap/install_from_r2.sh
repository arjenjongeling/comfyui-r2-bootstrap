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

reject_placeholder() {
    local name="$1"
    local value="${!name:-}"

    case "${value}" in
        ""|YOUR_*|*YOUR_ACCOUNT_ID*|*YOUR_ACCESS_KEY*|*YOUR_SECRET_KEY*)
            fatal "Replace placeholder value for required setting: ${name}"
            ;;
    esac
}

require_bool() {
    local name="$1"
    local value="$2"

    case "${value}" in
        true|false)
            ;;
        *)
            fatal "${name} must be either 'true' or 'false'"
            ;;
    esac
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

ensure_rclone_installed() {
    if command_exists rclone; then
        log "rclone is already installed: $(command -v rclone)"
        return
    fi

    log "rclone is not installed; installing rclone"

    if ! command_exists curl; then
        fatal "curl is required to install rclone"
    fi

    if command_exists sudo; then
        curl https://rclone.org/install.sh | sudo bash
    else
        curl https://rclone.org/install.sh | bash
    fi

    if ! command_exists rclone; then
        fatal "rclone installation completed but rclone was not found in PATH"
    fi

    log "rclone installed: $(command -v rclone)"
}

configure_rclone_remote() {
    local remote_exists="false"

    if rclone listremotes | grep -Fx "${R2_REMOTE_NAME}:" >/dev/null; then
        remote_exists="true"
    fi

    if [ "${remote_exists}" = "true" ]; then
        log "Updating existing rclone remote: ${R2_REMOTE_NAME}"
        rclone config update "${R2_REMOTE_NAME}" \
            provider Cloudflare \
            access_key_id "${R2_ACCESS_KEY_ID}" \
            secret_access_key "${R2_SECRET_ACCESS_KEY}" \
            endpoint "${R2_ENDPOINT}" \
            acl private \
            no_check_bucket true >/dev/null
    else
        log "Creating rclone remote: ${R2_REMOTE_NAME}"
        rclone config create "${R2_REMOTE_NAME}" s3 \
            provider Cloudflare \
            access_key_id "${R2_ACCESS_KEY_ID}" \
            secret_access_key "${R2_SECRET_ACCESS_KEY}" \
            endpoint "${R2_ENDPOINT}" \
            acl private \
            no_check_bucket true >/dev/null
    fi

    log "rclone remote is configured: ${R2_REMOTE_NAME}"
}

validate_r2_access() {
    local bucket_path="${R2_REMOTE_NAME}:${R2_BUCKET_NAME}"
    local prefix_path="${bucket_path}/${R2_COMFYUI_PREFIX}"
    local prefix_listing

    log "Validating R2 bucket access: ${R2_REMOTE_NAME}:${R2_BUCKET_NAME}"
    if ! rclone lsd "${bucket_path}" >/dev/null; then
        fatal "Cannot access R2 bucket '${R2_BUCKET_NAME}'. Check endpoint, credentials, bucket name, and account permissions."
    fi

    log "Validating R2 ComfyUI prefix: ${R2_COMFYUI_PREFIX}"
    if ! prefix_listing="$(rclone lsf "${prefix_path}" --max-depth 1)"; then
        fatal "Cannot access R2 prefix '${R2_COMFYUI_PREFIX}' in bucket '${R2_BUCKET_NAME}'. Check that the ComfyUI tree exists in R2."
    fi
    if [ -z "${prefix_listing}" ]; then
        fatal "R2 prefix '${R2_COMFYUI_PREFIX}' exists but appears to be empty. Expected a ComfyUI asset tree."
    fi

    log "R2 prefix listing preview:"
    rclone lsf "${prefix_path}" --max-depth 2 2>/dev/null | sed -n '1,20p' | while IFS= read -r item; do
        log "  ${item}"
    done
}

validate_comfyui_target() {
    case "${COMFYUI_DIR}" in
        ""|"/"|"/."|"/.."|"/workspace"|"/workspace/"|"/tmp"|"/tmp/"|"/var"|"/var/"|"/usr"|"/usr/"|"/home"|"/home/"|"/root"|"/root/")
            fatal "Refusing unsafe COMFYUI_DIR target: ${COMFYUI_DIR}"
            ;;
    esac
}

directory_is_empty() {
    local dir="$1"

    [ -d "${dir}" ] || return 1
    [ -z "$(find "${dir}" -mindepth 1 -maxdepth 1 -print -quit)" ]
}

prepare_comfyui_installation() {
    local comfyui_git_url="https://github.com/comfyanonymous/ComfyUI.git"
    local parent_dir

    validate_comfyui_target

    log "Preparing local ComfyUI installation: ${COMFYUI_DIR}"

    if [ -f "${COMFYUI_DIR}/main.py" ]; then
        log "Existing ComfyUI installation found; reusing ${COMFYUI_DIR}"
        return
    fi

    if [ -e "${COMFYUI_DIR}" ] && ! directory_is_empty "${COMFYUI_DIR}"; then
        fatal "COMFYUI_DIR exists but does not look like a ComfyUI installation: ${COMFYUI_DIR}"
    fi

    if ! command_exists git; then
        fatal "git is required to clone ComfyUI"
    fi

    parent_dir="$(dirname -- "${COMFYUI_DIR}")"
    mkdir -p "${parent_dir}"

    log "Cloning ComfyUI into ${COMFYUI_DIR}"
    git clone --depth 1 "${comfyui_git_url}" "${COMFYUI_DIR}"

    if [ ! -f "${COMFYUI_DIR}/main.py" ]; then
        fatal "ComfyUI clone completed but main.py was not found in ${COMFYUI_DIR}"
    fi

    log "ComfyUI base installation is ready"
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

reject_placeholder "R2_REMOTE_NAME"
reject_placeholder "R2_BUCKET_NAME"
reject_placeholder "R2_ENDPOINT"
reject_placeholder "R2_ACCESS_KEY_ID"
reject_placeholder "R2_SECRET_ACCESS_KEY"
reject_placeholder "R2_COMFYUI_PREFIX"
reject_placeholder "COMFYUI_DIR"

START_COMFYUI="${START_COMFYUI:-true}"
require_bool "START_COMFYUI" "${START_COMFYUI}"

R2_COMFYUI_PREFIX="${R2_COMFYUI_PREFIX#/}"
R2_COMFYUI_PREFIX="${R2_COMFYUI_PREFIX%/}"

log "Loaded configuration from ${ENV_FILE}"
log "Configuration summary:"
log "  R2 remote name: ${R2_REMOTE_NAME}"
log "  R2 bucket: ${R2_BUCKET_NAME}"
log "  R2 endpoint: ${R2_ENDPOINT}"
log "  R2 ComfyUI prefix: ${R2_COMFYUI_PREFIX}"
log "  Target ComfyUI directory: ${COMFYUI_DIR}"
log "  Start ComfyUI after bootstrap: ${START_COMFYUI}"
log "  R2 access key id: set"
log "  R2 secret access key: set"

ensure_rclone_installed
configure_rclone_remote
validate_r2_access
prepare_comfyui_installation

cat <<'EOF'

This bootstrap script is currently a scaffold.

Planned implementation:
1. Sync models, custom nodes, workflows, and user data from R2.
2. Start ComfyUI through bootstrap/runtime/start_comfyui.sh.

EOF

fatal "R2 restore implementation is not complete yet."
