#!/usr/bin/env bash
set -euo pipefail

# Regression test: selecting another image root must also move its derived lock
# file, without requiring edits to image-repo.cfg.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
STUB_BIN="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR" "$STUB_BIN"' EXIT

IMAGE_LIST="$TEMP_DIR/cilium.txt"
LOCAL_PATH="$TEMP_DIR/images/cilium/v1.20"
printf '%s\n' 'quay.io/cilium/cilium:v1.20.1' > "$IMAGE_LIST"

cat > "$STUB_BIN/skopeo" <<'SKOPEO_STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "copy" ]]; then
    destination="${@: -1}"
    destination="${destination#dir:}"
    mkdir -p "$destination"
    printf '{}\n' > "$destination/manifest.json"
elif [[ "$1" == "inspect" ]]; then
    printf 'sha256:test-digest\n'
fi
SKOPEO_STUB
cat > "$STUB_BIN/rsync" <<'RSYNC_STUB'
#!/usr/bin/env bash
exit 0
RSYNC_STUB
chmod +x "$STUB_BIN/skopeo" "$STUB_BIN/rsync"

PATH="$STUB_BIN:$PATH" "$REPO_ROOT/image-repo.sh" \
    --images-file "$IMAGE_LIST" \
    --local-image-path "$LOCAL_PATH" \
    --no-sync

LOCK_FILE="$LOCAL_PATH/images.lock"
[[ -f "$LOCK_FILE" ]] || { printf 'FAIL: derived lock file missing: %s\n' "$LOCK_FILE" >&2; exit 1; }
grep -Fqx 'quay.io/cilium/cilium:v1.20.1 sha256:test-digest' "$LOCK_FILE" || {
    printf 'FAIL: lock file content is incorrect\n' >&2
    exit 1
}

printf 'PASS: independent image workflow uses its own derived lock file\n'