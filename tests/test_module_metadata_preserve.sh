#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
REPO_BASE="$TEMP_DIR/repo"
mkdir -p "$REPO_BASE"

cat > "$REPO_BASE/modules.yaml" <<'YAML'
document: modulemd
data:
  name: nginx
  stream: 1.22
  profiles:
    default: [default]
---
document: modulemd
data:
  name: nginx
  stream: 1.26
  profiles:
    default: [default]
YAML

export MYREPO_SOURCE_ONLY=1
export ELEVATE_COMMANDS=0
unset MODULE_STREAMS

mkdir -p "$REPO_BASE/getPackage"
: > "$REPO_BASE/getPackage/nginx-1.26.2-1.el9.x86_64.rpm"

# shellcheck source=/dev/null
source "$REPO_ROOT/myrepo.sh"

backup_dir="$(preserve_module_metadata "$REPO_BASE")"
if [[ -z "$backup_dir" || ! -d "$backup_dir" ]]; then
  echo "FAIL: preserve_module_metadata did not create a backup directory" >&2
  exit 1
fi

if [[ ! -f "$backup_dir/modules.yaml" ]]; then
  echo "FAIL: backup directory does not contain modules.yaml" >&2
  exit 1
fi

inferred_streams="$(infer_module_streams_for_repo "$REPO_BASE" "$REPO_BASE/getPackage")"
if [[ "$inferred_streams" != "1.26" ]]; then
  echo "FAIL: auto-detected stream list was '$inferred_streams' instead of '1.26'" >&2
  exit 1
fi

filter_module_metadata_for_streams "$REPO_BASE" "$inferred_streams"
if grep -q "stream: 1.22" "$REPO_BASE/modules.yaml"; then
  echo "FAIL: module stream filter did not remove the non-selected stream" >&2
  exit 1
fi
if ! grep -q "stream: 1.26" "$REPO_BASE/modules.yaml"; then
  echo "FAIL: module stream filter did not keep the selected stream" >&2
  exit 1
fi

rm -f "$REPO_BASE/modules.yaml"
restore_preserved_module_metadata "$REPO_BASE" "$backup_dir"

if [[ ! -f "$REPO_BASE/modules.yaml" ]]; then
  echo "FAIL: restore_preserved_module_metadata did not restore modules.yaml" >&2
  exit 1
fi

grep -q "name: nginx" "$REPO_BASE/modules.yaml" || {
  echo "FAIL: restored module metadata content is incorrect" >&2
  exit 1
}

echo "PASS: module metadata backup, stream filtering, and restore works correctly"
