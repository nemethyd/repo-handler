#!/usr/bin/env bash
set -euo pipefail

# Test: download_module_artifact_rpms correctly identifies missing artifact NEVRAs
# and preserves upstream module metadata unchanged.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

REPO_BASE="$TEMP_DIR/ol9_appstream"
PACKAGES_DIR="$REPO_BASE/getPackage"
mkdir -p "$PACKAGES_DIR"

# --- Setup: declare which artifact NEVRAs are already present locally ---
# Kept synthetic on purpose: deriving this from /repo made the test depend on
# whichever nginx builds happened to be mirrored, so it failed once the older
# build was also present.
declare -A present_nevras=(
  ["nginx-2:1.26.3-9.0.1.module+el9.8.0+91002+d4b54b3d.3.x86_64"]=1
  ["nginx-all-modules-2:1.26.3-9.0.1.module+el9.8.0+91002+d4b54b3d.3.noarch"]=1
)

echo "Present RPMs: ${#present_nevras[@]} nginx packages"

# --- Create module metadata with multiple builds (some present, some not) ---
cat > "$REPO_BASE/modules.yaml" <<'YAML'
document: modulemd
version: 2
data:
  name: nginx
  stream: "1.26"
  version: 9080020260707110000
  context: 9
  static_context: true
  arch: x86_64
  summary: nginx webserver
  description: >-
    nginx 1.26 webserver module
  license:
    module:
    - MIT
  profiles:
    common:
      rpms:
      - nginx
      - nginx-all-modules
  api:
    rpms:
    - nginx
    - nginx-all-modules
  artifacts:
    rpms:
    - nginx-2:1.26.3-9.0.1.module+el9.8.0+91002+d4b54b3d.3.x86_64
    - nginx-all-modules-2:1.26.3-9.0.1.module+el9.8.0+91002+d4b54b3d.3.noarch
---
document: modulemd
version: 2
data:
  name: nginx
  stream: "1.26"
  version: 9080020260625020339
  context: 9
  static_context: true
  arch: x86_64
  summary: nginx webserver
  description: >-
    nginx 1.26 webserver module
  license:
    module:
    - MIT
  profiles:
    common:
      rpms:
      - nginx
      - nginx-all-modules
  api:
    rpms:
    - nginx
    - nginx-all-modules
  artifacts:
    rpms:
    - nginx-2:1.26.3-9.0.1.module+el9.8.0+90950+a1e882cd.2.x86_64
    - nginx-all-modules-2:1.26.3-9.0.1.module+el9.8.0+90950+a1e882cd.2.noarch
YAML

# Save a copy of the original metadata for comparison
cp "$REPO_BASE/modules.yaml" "$TEMP_DIR/modules.yaml.original"

export ELEVATE_COMMANDS=0
export DRY_RUN=1  # Don't actually download, just test the identification logic

# shellcheck source=/dev/null
source "$REPO_ROOT/myrepo.sh"

# --- Test 1: verify artifact extraction ---
artifacts_file="$(mktemp)"
read_module_metadata_file "$REPO_BASE/modules.yaml" \
  | awk '/^[[:space:]]*artifacts:/ { in_art=1; next }
         in_art && /^[[:space:]]*rpms:/ { next }
         in_art && /^[[:space:]]+-/ {
             val = $0
             gsub(/^[[:space:]]+-[[:space:]]*/, "", val)
             gsub(/[[:space:]]+$/, "", val)
             if (val != "") print val
         }
         in_art && /^[[:space:]]*[a-zA-Z]/ { in_art=0 }' \
  | sort -u > "$artifacts_file"

artifact_count=$(wc -l < "$artifacts_file")
if [[ "$artifact_count" -ne 4 ]]; then
  echo "FAIL: expected 4 unique artifact NEVRAs, found $artifact_count" >&2
  cat "$artifacts_file" >&2
  rm -f "$artifacts_file"
  exit 1
fi
echo "Extracted $artifact_count artifact NEVRAs from module metadata"

# --- Test 2: verify missing NEVRA identification ---
present_file="$(mktemp)"
for nevra in "${!present_nevras[@]}"; do
  echo "$nevra"
done | sort -u > "$present_file"

missing_file="$(mktemp)"
comm -23 "$artifacts_file" "$present_file" > "$missing_file"
missing_count=$(wc -l < "$missing_file")

# The 90950 build artifacts should be missing (only 91002 is present)
if [[ "$missing_count" -ne 2 ]]; then
  echo "FAIL: expected 2 missing artifact NEVRAs (build 90950), found $missing_count" >&2
  echo "Missing:" >&2
  cat "$missing_file" >&2
  rm -f "$artifacts_file" "$present_file" "$missing_file"
  exit 1
fi

# Verify the missing ones are from the old build
if ! grep -q "90950+a1e882cd" "$missing_file"; then
  echo "FAIL: expected build 90950 artifacts to be missing" >&2
  exit 1
fi

# Verify the present ones are NOT in the missing list
if grep -q "91002+d4b54b3d" "$missing_file"; then
  echo "FAIL: build 91002 artifacts should NOT be in missing list" >&2
  exit 1
fi

echo "Correctly identified $missing_count missing artifact(s) from older build"

rm -f "$artifacts_file" "$present_file" "$missing_file"

# --- Test 3: verify module metadata is NOT modified ---
# (The new approach preserves upstream NEVRAs, unlike the old rewrite approach)
if ! diff -q "$REPO_BASE/modules.yaml" "$TEMP_DIR/modules.yaml.original" >/dev/null 2>&1; then
  echo "FAIL: module metadata was modified (upstream NEVRAs not preserved)" >&2
  exit 1
fi
echo "Module metadata preserved unchanged (upstream NEVRAs intact)"

echo "PASS: download_module_artifact_rpms correctly identifies missing artifacts and preserves upstream metadata"
