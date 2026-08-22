#!/usr/bin/env bash
set -euo pipefail

# image-repo.sh
# Build a minimal local image repository from an explicit image list
# and optionally sync it to an internal host (myrepo-style workflow).

VERSION="0.1.0"

LOCAL_IMAGE_PATH="${LOCAL_IMAGE_PATH:-/repo/images/kubernetes/v1.36}"
IMAGES_FILE="${IMAGES_FILE:-./images/kubernetes-v1.36.4.txt}"
ARCHIVE_DIGESTS_FILE="${ARCHIVE_DIGESTS_FILE:-${LOCAL_IMAGE_PATH}/images.lock}"

SYNC_ONLY="${SYNC_ONLY:-0}"
NO_SYNC="${NO_SYNC:-0}"
DRY_RUN="${DRY_RUN:-0}"
FORCE_REFRESH="${FORCE_REFRESH:-0}"
PUBLISH="${PUBLISH:-0}"
PUBLISH_ONLY="${PUBLISH_ONLY:-0}"
COPY_ALL_ARCHES="${COPY_ALL_ARCHES:-0}"
IMAGE_OS="${IMAGE_OS:-linux}"
IMAGE_ARCH="${IMAGE_ARCH:-amd64}"

SYNC_MODE="${SYNC_MODE:-remote}"           # remote | none
REMOTE_SYNC_HOST="${REMOTE_SYNC_HOST:-}"
REMOTE_SYNC_USER="${REMOTE_SYNC_USER:-}"
REMOTE_SYNC_TARGET_BASE="${REMOTE_SYNC_TARGET_BASE:-}"
REMOTE_SYNC_TARGET_STYLE="${REMOTE_SYNC_TARGET_STYLE:-gitbash}"   # gitbash | cygwin | unix
REMOTE_SYNC_REMOTE_OS="${REMOTE_SYNC_REMOTE_OS:-windows}"         # windows | unix
REMOTE_SYNC_SSH_OPTS="${REMOTE_SYNC_SSH_OPTS:-}"

TARGET_REGISTRY="${TARGET_REGISTRY:-}"                   # e.g. mgmt2.kafir.police.hu:5000
TARGET_NAMESPACE="${TARGET_NAMESPACE:-registry.k8s.io}" # preserves kubeadm-style naming
DEST_TLS_VERIFY="${DEST_TLS_VERIFY:-true}"              # true | false
PUBLISH_RETRY_TIMES="${PUBLISH_RETRY_TIMES:-3}"
PUBLISH_RETRY_DELAY="${PUBLISH_RETRY_DELAY:-10s}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG_FILE="${SCRIPT_DIR}/image-repo.cfg"

function now() {
    date '+%Y-%m-%d %H:%M:%S'
}

function log_info() {
    printf '[%s] [INFO] %s\n' "$(now)" "$*"
}

function log_ok() {
    printf '[%s] [ OK ] %s\n' "$(now)" "$*"
}

function log_warn() {
    printf '[%s] [WARN] %s\n' "$(now)" "$*"
}

function log() {
    log_info "$*"
}

function fail() {
    printf '[%s] [FAIL] %s\n' "$(now)" "$*" >&2
    exit 1
}

function usage() {
    cat <<EOF
image-repo.sh ${VERSION}

Usage:
  ./image-repo.sh [options]

Options:
  --images-file FILE              Path to text file with one image reference per line.
  --local-image-path PATH         Local output root for mirrored images.
  --sync-only                     Skip mirror/update, perform sync only.
    --publish                       Execute publish step after mirror/sync.
    --publish-only                  Run only the publish step.
    --all-arches                    Copy all image architectures (slower).
    --single-arch                   Copy only IMAGE_OS/IMAGE_ARCH (faster, default).
    --image-os OS                   Source/target image OS for single-arch mode (default: linux).
    --image-arch ARCH               Source/target image arch for single-arch mode (default: amd64).
  --no-sync                       Do not run remote sync.
  --sync-mode MODE                remote|none (default: remote)
  --remote-sync-host HOST         Remote host for rsync.
  --remote-sync-user USER         Remote SSH user for rsync.
  --remote-sync-target-base PATH  Remote target base path.
  --remote-sync-target-style S    gitbash|cygwin|unix (default: gitbash)
  --remote-sync-remote-os OS      windows|unix (default: windows)
  --remote-sync-ssh-opts OPTS     Extra SSH options for rsync.
    --target-registry REG           Internal registry host[:port].
    --target-namespace NS           Namespace prefix in target registry.
    --dest-tls-verify BOOL          true|false for destination registry TLS check.
    --publish-retry-times N         Retry count for image publication (default: 3).
    --publish-retry-delay DUR       Delay between publication retries (default: 10s).
  --force-refresh                 Re-copy even if image exists locally.
  --dry-run                       Print actions but do not execute.
    -V, --version                  Show image-repo.sh version.
  -h, --help                      Show this help.

Images file format:
  - one image per line
  - comments begin with '#'
  - empty lines are ignored

Example:
  ./image-repo.sh --images-file ./images/kubernetes-v1.36.4.txt
EOF
}

if [[ -f "${CFG_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CFG_FILE}"
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --images-file)
            IMAGES_FILE="$2"; shift 2;;
        --local-image-path)
            LOCAL_IMAGE_PATH="$2"; shift 2;;
        --sync-only)
            SYNC_ONLY=1; shift;;
        --publish)
            PUBLISH=1; shift;;
        --publish-only)
            PUBLISH=1; PUBLISH_ONLY=1; shift;;
        --all-arches)
            COPY_ALL_ARCHES=1; shift;;
        --single-arch)
            COPY_ALL_ARCHES=0; shift;;
        --image-os)
            IMAGE_OS="$2"; shift 2;;
        --image-arch)
            IMAGE_ARCH="$2"; shift 2;;
        --no-sync)
            NO_SYNC=1; shift;;
        --sync-mode)
            SYNC_MODE="$2"; shift 2;;
        --remote-sync-host)
            REMOTE_SYNC_HOST="$2"; shift 2;;
        --remote-sync-user)
            REMOTE_SYNC_USER="$2"; shift 2;;
        --remote-sync-target-base)
            REMOTE_SYNC_TARGET_BASE="$2"; shift 2;;
        --remote-sync-target-style)
            REMOTE_SYNC_TARGET_STYLE="$2"; shift 2;;
        --remote-sync-remote-os)
            REMOTE_SYNC_REMOTE_OS="$2"; shift 2;;
        --remote-sync-ssh-opts)
            REMOTE_SYNC_SSH_OPTS="$2"; shift 2;;
        --target-registry)
            TARGET_REGISTRY="$2"; shift 2;;
        --target-namespace)
            TARGET_NAMESPACE="$2"; shift 2;;
        --dest-tls-verify)
            DEST_TLS_VERIFY="$2"; shift 2;;
        --publish-retry-times)
            PUBLISH_RETRY_TIMES="$2"; shift 2;;
        --publish-retry-delay)
            PUBLISH_RETRY_DELAY="$2"; shift 2;;
        --force-refresh)
            FORCE_REFRESH=1; shift;;
        --dry-run)
            DRY_RUN=1; shift;;
        -V|--version)
            printf 'image-repo.sh version %s\n' "${VERSION}"; exit 0;;
        -h|--help)
            usage; exit 0;;
        *)
            fail "Unknown option: $1";;
    esac
done

log_info "Starting image-repo.sh version ${VERSION}"

# Resolve relative defaults against the script directory so aliases work from any cwd.
if [[ "${IMAGES_FILE}" != /* ]]; then
    IMAGES_FILE="${SCRIPT_DIR}/${IMAGES_FILE#./}"
fi

if [[ "${ARCHIVE_DIGESTS_FILE}" != /* ]]; then
    ARCHIVE_DIGESTS_FILE="${SCRIPT_DIR}/${ARCHIVE_DIGESTS_FILE#./}"
fi

command -v skopeo >/dev/null 2>&1 || fail "skopeo is required"
command -v rsync >/dev/null 2>&1 || fail "rsync is required"

[[ -f "${IMAGES_FILE}" ]] || fail "Images file not found: ${IMAGES_FILE}"

mkdir -p "${LOCAL_IMAGE_PATH}"
: > "${ARCHIVE_DIGESTS_FILE}.tmp"

function rsync_target_path() {
    local raw="$1"
    if [[ "${REMOTE_SYNC_REMOTE_OS}" == "unix" ]]; then
        printf '%s' "${raw}"
        return
    fi

    case "${REMOTE_SYNC_TARGET_STYLE}" in
        gitbash)
            if [[ "${raw}" =~ ^([A-Za-z]):/(.*)$ ]]; then
                local drive="${BASH_REMATCH[1],,}"
                local rest="${BASH_REMATCH[2]}"
                printf '/%s/%s' "${drive}" "${rest}"
            else
                printf '%s' "${raw}"
            fi
            ;;
        cygwin)
            if [[ "${raw}" =~ ^([A-Za-z]):/(.*)$ ]]; then
                local drive="${BASH_REMATCH[1],,}"
                local rest="${BASH_REMATCH[2]}"
                printf '/cygdrive/%s/%s' "${drive}" "${rest}"
            else
                printf '%s' "${raw}"
            fi
            ;;
        unix)
            printf '%s' "${raw}"
            ;;
        *)
            fail "Unsupported REMOTE_SYNC_TARGET_STYLE: ${REMOTE_SYNC_TARGET_STYLE}"
            ;;
    esac
}

function sanitize_ref_to_path() {
    local image_ref="$1"
    local registry_and_repo="${image_ref%:*}"
    local tag="${image_ref##*:}"
    printf '%s/%s' "${registry_and_repo}" "${tag}"
}

function mirror_images() {
    local image_count=0
    log_info "Mirror step started"
    log_info "Image list: ${IMAGES_FILE}"
    log_info "Local path: ${LOCAL_IMAGE_PATH}"
    if [[ "${COPY_ALL_ARCHES}" == "1" ]]; then
        log_info "Arch mode: all architectures"
    else
        log_info "Arch mode: single architecture (${IMAGE_OS}/${IMAGE_ARCH})"
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        [[ -z "${line}" ]] && continue

        local src_image="${line}"
        local rel_path
        rel_path="$(sanitize_ref_to_path "${src_image}")"
        local dest_dir="${LOCAL_IMAGE_PATH}/${rel_path}"

        ((image_count+=1))
        log_info "[${image_count}] ${src_image}"

        if [[ ${FORCE_REFRESH} -eq 0 && -f "${dest_dir}/manifest.json" ]]; then
            log_ok "already mirrored, skipping"
        else
            log_info "mirror target: ${dest_dir}"
            if [[ ${DRY_RUN} -eq 0 ]]; then
                mkdir -p "${dest_dir}"
                if [[ "${COPY_ALL_ARCHES}" == "1" ]]; then
                    skopeo copy --all "docker://${src_image}" "dir:${dest_dir}"
                else
                    skopeo copy --override-os "${IMAGE_OS}" --override-arch "${IMAGE_ARCH}" "docker://${src_image}" "dir:${dest_dir}"
                fi
                log_ok "mirrored"
            fi
        fi

        local digest="unknown"
        if [[ ${DRY_RUN} -eq 0 ]]; then
            digest="$(skopeo inspect --format '{{.Digest}}' "docker://${src_image}" 2>/dev/null || echo unknown)"
        fi
        printf '%s %s\n' "${src_image}" "${digest}" >> "${ARCHIVE_DIGESTS_FILE}.tmp"
    done < "${IMAGES_FILE}"

    if [[ ${DRY_RUN} -eq 0 ]]; then
        mv "${ARCHIVE_DIGESTS_FILE}.tmp" "${ARCHIVE_DIGESTS_FILE}"
        log_ok "lock file updated: ${ARCHIVE_DIGESTS_FILE}"
    else
        rm -f "${ARCHIVE_DIGESTS_FILE}.tmp"
        log_warn "dry-run mode: lock file not written"
    fi

    log_ok "Images processed: ${image_count}"
}

function do_remote_sync() {
    [[ "${SYNC_MODE}" == "remote" ]] || { log_warn "Sync mode is '${SYNC_MODE}', skipping sync"; return; }
    [[ -n "${REMOTE_SYNC_HOST}" ]] || fail "REMOTE_SYNC_HOST is required for remote sync"
    [[ -n "${REMOTE_SYNC_USER}" ]] || fail "REMOTE_SYNC_USER is required for remote sync"
    [[ -n "${REMOTE_SYNC_TARGET_BASE}" ]] || fail "REMOTE_SYNC_TARGET_BASE is required for remote sync"

    local remote_target
    remote_target="$(rsync_target_path "${REMOTE_SYNC_TARGET_BASE}")"

    local -a rsync_cmd
    rsync_cmd=(rsync -a --delete --human-readable --info=progress2)
    if [[ -n "${REMOTE_SYNC_SSH_OPTS}" ]]; then
        rsync_cmd+=("-e" "ssh ${REMOTE_SYNC_SSH_OPTS}")
    fi

    rsync_cmd+=("${LOCAL_IMAGE_PATH}/" "${REMOTE_SYNC_USER}@${REMOTE_SYNC_HOST}:${remote_target}/")

    log_info "Sync step started"
    log_info "Sync source: ${LOCAL_IMAGE_PATH}/"
    log_info "Sync target: ${REMOTE_SYNC_USER}@${REMOTE_SYNC_HOST}:${remote_target}/"

    if [[ ${DRY_RUN} -eq 1 ]]; then
        printf 'DRY_RUN: '; printf '%q ' "${rsync_cmd[@]}"; printf '\n'
    else
        "${rsync_cmd[@]}"
        log_ok "Sync completed"
    fi
}

function do_publish() {
    [[ -n "${TARGET_REGISTRY}" ]] || fail "TARGET_REGISTRY is required for publish"

    local count=0
    log_info "Publish step started"
    log_info "Registry: ${TARGET_REGISTRY}"
    log_info "Namespace: ${TARGET_NAMESPACE}"
    if [[ "${COPY_ALL_ARCHES}" == "1" ]]; then
        log_info "Arch mode: all architectures"
    else
        log_info "Arch mode: single architecture (${IMAGE_OS}/${IMAGE_ARCH})"
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        [[ -z "${line}" ]] && continue

        local src_image="${line}"
        local registry_and_repo="${src_image%:*}"
        local tag="${src_image##*:}"

        local src_dir="${LOCAL_IMAGE_PATH}/${registry_and_repo}/${tag}"
        if [[ "${DRY_RUN}" == "0" ]]; then
            [[ -f "${src_dir}/manifest.json" ]] || fail "Mirrored image missing locally: ${src_dir}"
        fi

        local repo_no_registry="${registry_and_repo#*/}"
        local dest_image="${TARGET_REGISTRY}/${TARGET_NAMESPACE}/${repo_no_registry}:${tag}"

        count=$((count + 1))
        log_info "[${count}] ${src_dir} -> ${dest_image}"

        if [[ "${DRY_RUN}" == "0" ]]; then
            if [[ "${COPY_ALL_ARCHES}" == "1" ]]; then
                skopeo copy --all --retry-times="${PUBLISH_RETRY_TIMES}" --retry-delay="${PUBLISH_RETRY_DELAY}" --dest-tls-verify="${DEST_TLS_VERIFY}" "dir:${src_dir}" "docker://${dest_image}"
            else
                skopeo copy --override-os "${IMAGE_OS}" --override-arch "${IMAGE_ARCH}" --retry-times="${PUBLISH_RETRY_TIMES}" --retry-delay="${PUBLISH_RETRY_DELAY}" --dest-tls-verify="${DEST_TLS_VERIFY}" "dir:${src_dir}" "docker://${dest_image}"
            fi
            skopeo inspect --tls-verify="${DEST_TLS_VERIFY}" "docker://${dest_image}" >/dev/null \
                || fail "Published image manifest verification failed: ${dest_image}"
        fi
    done < "${IMAGES_FILE}"

    log_ok "Published images: ${count}"
}

if [[ ${PUBLISH_ONLY} -eq 1 ]]; then
    do_publish
else
    if [[ ${SYNC_ONLY} -eq 0 ]]; then
        mirror_images
    else
        log_warn "SYNC_ONLY=1 -> skipping image mirroring"
    fi

    if [[ ${NO_SYNC} -eq 0 ]]; then
        do_remote_sync
    else
        log_warn "NO_SYNC=1 -> skipping sync"
    fi

    if [[ ${PUBLISH} -eq 1 ]]; then
        do_publish
    else
        log_warn "PUBLISH=0 -> skipping publish"
    fi
fi

log_ok "Done"
