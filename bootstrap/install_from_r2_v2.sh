#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ENV_FILE="${SCRIPT_DIR}/r2.env"
WORKSPACE_DIR="$(pwd -P)"
COMFYUI_DIR="${WORKSPACE_DIR}/comfyui"
RCLONE_PID=""
CUSTOM_NODES_PID=""
INSTALL_START_SECONDS="$(date +%s)"
DEPENDENCIES_ONLY="false"
CUSTOM_NODES_ONLY="false"

case "${1:-}" in
    "")
        ;;
    --dependencies-only)
        DEPENDENCIES_ONLY="true"
        ;;
    --custom-nodes-only)
        CUSTOM_NODES_ONLY="true"
        ;;
    --help|-h)
        printf 'Usage: bash %s [--dependencies-only|--custom-nodes-only]\n' "${BASH_SOURCE[0]}"
        printf '  --dependencies-only  Clone/reuse ComfyUI and install base requirements; skip R2 and startup.\n'
        printf '  --custom-nodes-only  Install nodes from the local bootstrap/custom_nodes.json; skip R2 and base requirements.\n'
        exit 0
        ;;
    *)
        printf '[bootstrap-v2][fatal] Unknown option: %s\n' "$1" >&2
        printf 'Usage: bash %s [--dependencies-only|--custom-nodes-only]\n' "${BASH_SOURCE[0]}" >&2
        exit 2
        ;;
esac

if [ "${DEPENDENCIES_ONLY}" = "true" ] && [ "${CUSTOM_NODES_ONLY}" = "true" ]; then
    printf '[bootstrap-v2][fatal] Choose only one test mode.\n' >&2
    exit 2
fi

log() {
    printf '[bootstrap-v2] %s\n' "$*"
}

fatal() {
    printf '[bootstrap-v2][fatal] %s\n' "$*" >&2
    exit 1
}

cleanup_parallel_jobs() {
    local pid
    for pid in "${RCLONE_PID}" "${CUSTOM_NODES_PID}"; do
        if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
            kill "${pid}" 2>/dev/null || true
            wait "${pid}" 2>/dev/null || true
        fi
    done
}
trap cleanup_parallel_jobs EXIT INT TERM

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

check_python_version() {
    local python_version

    if ! command_exists python3; then
        fatal "python3 is required to install ComfyUI dependencies"
    fi
    if ! python_version="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"; then
        fatal "Could not determine the python3 version"
    fi
    if ! python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 10))'; then
        fatal "ComfyUI requires Python 3.10 or newer; found ${python_version} at $(command -v python3)"
    fi

    log "Using Python ${python_version}: $(command -v python3)"
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
    local manifest_path="${bucket_path}/bootstrap/custom_nodes.json"
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

    if ! rclone lsf "${manifest_path}" >/dev/null 2>&1; then
        fatal "Missing private custom-node manifest in R2: bootstrap/custom_nodes.json"
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

copy_r2_assets_to_comfyui() {
    local source_path="${R2_REMOTE_NAME}:${R2_BUCKET_NAME}"

    log "Copying filtered R2 assets into workspace"
    log "  Source: ${R2_REMOTE_NAME}:${R2_BUCKET_NAME}"
    log "  Target: ${WORKSPACE_DIR}"
    log "  Transfers: ${R2_TRANSFERS}"
    log "  Included paths: ${R2_COMFYUI_PREFIX}/models/, ${R2_COMFYUI_PREFIX}/user/"
    log "  Mode: non-destructive overlay copy"

    rclone copy "${source_path}" "${WORKSPACE_DIR}" \
        --progress \
        --transfers "${R2_TRANSFERS}" \
        --create-empty-src-dirs \
        --filter "+ /${R2_COMFYUI_PREFIX}/models/**" \
        --filter "+ /${R2_COMFYUI_PREFIX}/user/**" \
        --filter '- **'

    log "Filtered R2 assets copied into workspace"
}

copy_custom_node_manifest() {
    local source_path="${R2_REMOTE_NAME}:${R2_BUCKET_NAME}/bootstrap/custom_nodes.json"
    local target_path="${WORKSPACE_DIR}/bootstrap/custom_nodes.json"

    log "Downloading the small custom-node manifest before starting parallel setup"
    rclone copyto "${source_path}" "${target_path}"
    log "Custom-node manifest downloaded"
}

install_base_python_requirements() {
    local requirements_file="${COMFYUI_DIR}/requirements.txt"

    if [ ! -f "${requirements_file}" ]; then
        fatal "Missing ComfyUI requirements file: ${requirements_file}"
    fi

    log "Installing base ComfyUI Python requirements"
    python3 -m pip install -r "${requirements_file}"
}

install_custom_node_requirements() {
    local custom_requirements_count=0

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

print_installation_duration() {
    local elapsed_seconds=$(( $(date +%s) - INSTALL_START_SECONDS ))
    local elapsed_minutes=$((elapsed_seconds / 60))
    local remaining_seconds=$((elapsed_seconds % 60))
    local message=" INSTALLATION FINISHED IN ${elapsed_minutes} MINUTES $(printf '%02d' "${remaining_seconds}") SECONDS "
    local border

    printf -v border '%*s' "${#message}" ''
    border="${border// /*}"

    if [ -t 1 ]; then
        printf '\n\033[1;32m*%s*\n*%s*\n*%s*\033[0m\n\n' "${border}" "${message}" "${border}"
    else
        printf '\n*%s*\n*%s*\n*%s*\n\n' "${border}" "${message}" "${border}"
    fi
}

read_custom_node_manifest() {
    local manifest_file="${WORKSPACE_DIR}/bootstrap/custom_nodes.json"

    if [ ! -f "${manifest_file}" ]; then
        fatal "Custom-node manifest not found: ${manifest_file}"
    fi
    if ! command_exists python3; then
        fatal "python3 is required to validate the custom-node manifest"
    fi

    if ! python3 - "${manifest_file}" <<'PY'
import json
import re
import sys
from urllib.parse import urlparse

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as manifest_file:
        manifest = json.load(manifest_file)
except (OSError, UnicodeError, json.JSONDecodeError) as exc:
    print(f"Invalid custom-node manifest JSON: {exc}", file=sys.stderr)
    raise SystemExit(1)

if not isinstance(manifest, dict) or manifest.get("version") != 1:
    print("Manifest must be an object with version 1", file=sys.stderr)
    raise SystemExit(1)
nodes = manifest.get("custom_nodes")
if not isinstance(nodes, list):
    print("Manifest custom_nodes must be an array", file=sys.stderr)
    raise SystemExit(1)

names = set()
validated = []
for index, node in enumerate(nodes):
    if not isinstance(node, dict):
        print(f"custom_nodes[{index}] must be an object", file=sys.stderr)
        raise SystemExit(1)
    name = node.get("name")
    repository = node.get("repository")
    revision = node.get("revision", "")
    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name) or name in {".", ".."}:
        print(f"custom_nodes[{index}] has an unsafe or missing name", file=sys.stderr)
        raise SystemExit(1)
    if name in names:
        print(f"Duplicate custom-node name: {name}", file=sys.stderr)
        raise SystemExit(1)
    names.add(name)
    parsed = urlparse(repository) if isinstance(repository, str) else None
    if parsed is None or parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password or any(c.isspace() for c in repository):
        print(f"custom_nodes[{index}] repository must be an HTTPS URL", file=sys.stderr)
        raise SystemExit(1)
    if not isinstance(revision, str) or (revision and not re.fullmatch(r"[0-9a-fA-F]{40}", revision)):
        print(f"custom_nodes[{index}] revision must be empty or a full 40-character commit SHA", file=sys.stderr)
        raise SystemExit(1)
    if any("\t" in value or "\n" in value or "\r" in value for value in (name, repository, revision)):
        print(f"custom_nodes[{index}] contains an unsupported control character", file=sys.stderr)
        raise SystemExit(1)
    validated.append((name, repository, revision))

for entry in validated:
    print("\t".join(entry))
PY
    then
        fatal "Custom-node manifest validation failed"
    fi
}

install_custom_nodes_from_manifest() {
    local manifest_entries
    local node_name
    local repository
    local revision
    local node_dir
    local repo_root
    local existing_remote
    local default_branch

    if ! command_exists git; then
        fatal "git is required to install custom nodes"
    fi

    if ! manifest_entries="$(read_custom_node_manifest)"; then
        fatal "Could not read custom-node manifest"
    fi

    mkdir -p "${COMFYUI_DIR}/custom_nodes"
    while IFS=$'\t' read -r node_name repository revision; do
        [ -n "${node_name}" ] || continue
        node_dir="${COMFYUI_DIR}/custom_nodes/${node_name}"
        log "Preparing custom node ${node_name}"

        if [ -e "${node_dir}" ]; then
            if [ ! -e "${node_dir}/.git" ]; then
                fatal "Custom node target exists without Git metadata; refusing to overwrite: ${node_dir}"
            fi
            repo_root="$(git -C "${node_dir}" rev-parse --show-toplevel 2>/dev/null || true)"
            if [ "${repo_root}" != "${node_dir}" ]; then
                fatal "Custom node target is not its own Git repository: ${node_dir}"
            fi
            existing_remote="$(git -C "${node_dir}" remote get-url origin 2>/dev/null || true)"
            if [ "${existing_remote}" != "${repository}" ]; then
                fatal "Existing custom node '${node_name}' has a different origin; refusing to overwrite it"
            fi
            git -C "${node_dir}" fetch origin
        else
            log "Cloning ${repository} into ${node_dir}"
            git clone "${repository}" "${node_dir}"
        fi

        if [ -n "${revision}" ]; then
            git -C "${node_dir}" checkout --detach "${revision}"
        elif [ -e "${node_dir}/.git" ]; then
            git -C "${node_dir}" remote set-head origin --auto >/dev/null 2>&1 || true
            default_branch="$(git -C "${node_dir}" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
            if [ -z "${default_branch}" ]; then
                fatal "Could not determine default branch for custom node '${node_name}'"
            fi
            git -C "${node_dir}" checkout -B "${default_branch}" "origin/${default_branch}"
        fi
    done <<< "${manifest_entries}"
}

run_parallel_asset_copy_and_base_install() {
    local requirements_status=0
    local rclone_status=0
    local custom_nodes_status=0
    local custom_requirements_status=0

    copy_r2_assets_to_comfyui &
    RCLONE_PID=$!
    install_custom_nodes_from_manifest &
    CUSTOM_NODES_PID=$!

    if install_base_python_requirements; then
        log "Base ComfyUI requirements installed"
    else
        requirements_status=$?
        log "Base ComfyUI requirements installation failed with status ${requirements_status}"
    fi

    if wait "${CUSTOM_NODES_PID}"; then
        log "Custom-node repositories are ready"
    else
        custom_nodes_status=$?
        log "Custom-node repository setup failed with status ${custom_nodes_status}"
    fi
    CUSTOM_NODES_PID=""

    if [ "${requirements_status}" -eq 0 ] && [ "${custom_nodes_status}" -eq 0 ]; then
        if install_custom_node_requirements; then
            log "Custom-node requirements installed"
        else
            custom_requirements_status=$?
            log "Custom-node requirements installation failed with status ${custom_requirements_status}"
        fi
    fi

    if wait "${RCLONE_PID}"; then
        log "R2 asset copy completed"
    else
        rclone_status=$?
        log "R2 asset copy failed with status ${rclone_status}"
    fi
    RCLONE_PID=""

    if [ "${requirements_status}" -ne 0 ] || [ "${custom_nodes_status}" -ne 0 ] || [ "${custom_requirements_status}" -ne 0 ] || [ "${rclone_status}" -ne 0 ]; then
        fatal "Setup failed (base requirements: ${requirements_status}, custom-node repositories: ${custom_nodes_status}, custom-node requirements: ${custom_requirements_status}, R2 copy: ${rclone_status})"
    fi
}

start_comfyui() {
    local start_script="${SCRIPT_DIR}/runtime/start_comfyui.sh"

    if [ "${START_COMFYUI}" != "true" ]; then
        log "START_COMFYUI=false; skipping ComfyUI startup"
        return
    fi
    if [ ! -x "${start_script}" ]; then
        fatal "ComfyUI start script is missing or not executable: ${start_script}"
    fi

    log "Starting ComfyUI via ${start_script}"
    export COMFYUI_DIR
    export COMFYUI_HOST="${COMFYUI_HOST:-0.0.0.0}"
    export COMFYUI_PORT="${COMFYUI_PORT:-8188}"
    export COMFYUI_CORS_ORIGIN="${COMFYUI_CORS_ORIGIN:-}"
    exec "${start_script}"
}

if [ "${DEPENDENCIES_ONLY}" = "true" ]; then
    log "Dependencies-only mode: R2 configuration, asset copy, custom nodes, and ComfyUI startup are skipped"
    check_python_version
    prepare_comfyui_installation
    install_base_python_requirements
    log "Base ComfyUI dependency test completed successfully"
    exit 0
fi

if [ "${CUSTOM_NODES_ONLY}" = "true" ]; then
    if [ -f "${ENV_FILE}" ]; then
        # shellcheck disable=SC1090
        source "${ENV_FILE}"
    fi
    COMFYUI_DIR="${WORKSPACE_DIR}/comfyui"
    START_COMFYUI="${START_COMFYUI:-true}"
    check_python_version
    if [ ! -f "${COMFYUI_DIR}/main.py" ]; then
        fatal "ComfyUI installation not found at ${COMFYUI_DIR}; run the base bootstrap first"
    fi
    install_custom_nodes_from_manifest
    install_custom_node_requirements
    if [ "${START_COMFYUI}" = "true" ]; then
        print_installation_duration
    fi
    start_comfyui
    log "Custom-node-only setup completed"
    exit 0
fi

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

reject_placeholder "R2_REMOTE_NAME"
reject_placeholder "R2_BUCKET_NAME"
reject_placeholder "R2_ENDPOINT"
reject_placeholder "R2_ACCESS_KEY_ID"
reject_placeholder "R2_SECRET_ACCESS_KEY"
reject_placeholder "R2_COMFYUI_PREFIX"

# Always install under the directory from which the user invoked this script.
COMFYUI_DIR="${WORKSPACE_DIR}/comfyui"

START_COMFYUI="${START_COMFYUI:-true}"
R2_TRANSFERS="${R2_TRANSFERS:-32}"
require_bool "START_COMFYUI" "${START_COMFYUI}"
if [[ ! "${R2_TRANSFERS}" =~ ^[1-9][0-9]*$ ]]; then
    fatal "R2_TRANSFERS must be a positive integer"
fi

R2_COMFYUI_PREFIX="${R2_COMFYUI_PREFIX#/}"
R2_COMFYUI_PREFIX="${R2_COMFYUI_PREFIX%/}"

check_python_version

log "Loaded configuration from ${ENV_FILE}"
log "Configuration summary:"
log "  R2 remote name: ${R2_REMOTE_NAME}"
log "  R2 bucket: ${R2_BUCKET_NAME}"
log "  R2 endpoint: ${R2_ENDPOINT}"
log "  R2 ComfyUI prefix: ${R2_COMFYUI_PREFIX}"
log "  Workspace directory: ${WORKSPACE_DIR}"
log "  Target ComfyUI directory: ${COMFYUI_DIR}"
log "  R2 simultaneous transfers: ${R2_TRANSFERS}"
log "  Start ComfyUI after bootstrap: ${START_COMFYUI}"
log "  R2 access key id: set"
log "  R2 secret access key: set"

ensure_rclone_installed
configure_rclone_remote
validate_r2_access
copy_custom_node_manifest
prepare_comfyui_installation
run_parallel_asset_copy_and_base_install
if [ "${START_COMFYUI}" = "true" ]; then
    print_installation_duration
fi
start_comfyui

log "Bootstrap completed"
