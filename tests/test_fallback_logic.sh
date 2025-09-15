#!/usr/bin/env bash
set -euo pipefail

# Purpose: Test adaptive fallback logic in batch_download_packages.
# Strategy: Provide synthetic package list and stub dnf that fails
#           when more than 4 packages are requested, forcing shrink.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

temp_dir="$(mktemp -d)"
export LOCAL_REPO_PATH="$temp_dir"
export ELEVATE_COMMANDS=0
export DEBUG_LEVEL=2
export BATCH_SIZE=50
export MAX_PARALLEL_DOWNLOADS=8
export DNF_QUERY_TIMEOUT=2
export DNF_DOWNLOAD_TIMEOUT=10
export MYREPO_SOURCE_ONLY=1   # prevent auto main execution

# Create stub dnf binary in temp dir
STUB_BIN_DIR="$(mktemp -d)"
cat >"$STUB_BIN_DIR/dnf" <<'DNFSTUB'
#!/usr/bin/env bash
set -euo pipefail
# Very small simulator: 'dnf download <pkgs>' fails if >4 pkgs, succeeds otherwise.
if [[ $# -eq 0 ]]; then exit 0; fi
mode=$1; shift || true
if [[ "$mode" == "repolist" ]]; then
  # minimal output to satisfy is_repo_enabled / cache functions when invoked indirectly
  echo "repo id    repo name"
  echo "testrepo   Test Repository"
  exit 0
elif [[ "$mode" == "repoquery" ]]; then
  # Provide minimal fake installed package list so build_repo_cache / gather won't fail if called
  echo "dummy|0|1.0|1.el9|x86_64|testrepo"
  exit 0
elif [[ "$mode" == "download" ]]; then
  destdir="."
  pkgs=()
  # Parse remaining args, ignoring options
  while [[ $# -gt 0 ]]; do
    a=$1; shift || true
    case "$a" in
      --destdir=*) destdir="${a#--destdir=}" ;;
      --destdir) destdir="$1"; shift || true ;;
      --setopt=*|--enablerepo=*|--disablerepo=*|--timeout=*|--retries=*|--repofrompath=*|--releasever=*|--config=*|-y|--quiet) ;;
      --setopt|--enablerepo|--disablerepo|--timeout|--retries) shift || true ;;
      -*) ;; # ignore other flags
      *) pkgs+=("$a") ;;
    esac
  done
  count=${#pkgs[@]}
  if (( count > 4 )); then
    exit 1
  fi
  mkdir -p "$destdir"
  for p in "${pkgs[@]}"; do
    : >"$destdir/${p}.rpm"
  done
  exit 0
else
  # treat as success for other subcommands
  exit 0
fi
DNFSTUB
chmod +x "$STUB_BIN_DIR/dnf"
export PATH="$STUB_BIN_DIR:$PATH"

# Source the script without running main
# shellcheck source=/dev/null
source "$REPO_ROOT/myrepo.sh"

# Build synthetic package list for a single repo (repo|name|epoch|ver|rel|arch)
repo="testrepo"
mkdir -p "${LOCAL_REPO_PATH}/${repo}/getPackage"
package_lines=""
for i in $(seq 1 12); do
  package_lines+="${repo}|pkg${i}|0|1.0|1.el9|x86_64\n"
  # Pre-mark stats arrays to avoid SC2034 lint illusions when script ends
  stats_new_count["$repo"]=0
  stats_update_count["$repo"]=0
  stats_exists_count["$repo"]=0
done

# Feed to batch_download_packages (expects repo|name|epoch|ver|rel|arch input) and capture output
output=$(echo -e "$package_lines" | batch_download_packages 2>&1)
echo "$output" >&2

expected=12
actual=$(find "${LOCAL_REPO_PATH}/${repo}/getPackage" -maxdepth 1 -name '*.rpm' -type f 2>/dev/null | wc -l | tr -d ' ')

if [[ "$actual" -ne "$expected" ]]; then
  echo "FAIL: Expected $expected RPMs via adaptive fallback; got $actual" >&2
  exit 1
fi

# Assertions on adaptive fallback log behavior
echo "$output" | grep -q "Entering adaptive fallback" || { echo "FAIL: Missing 'Entering adaptive fallback' log" >&2; exit 1; }
echo "$output" | grep -q "Switching to individual package fallback" || { echo "FAIL: Missing 'Switching to individual package fallback' log" >&2; exit 1; }
echo "$output" | grep -q "Adaptive fallback result: 12/12 packages downloaded" || { echo "FAIL: Missing final adaptive fallback result log" >&2; exit 1; }
echo "$output" | grep -q "Fallback batch (" || { echo "FAIL: Missing intermediate fallback batch success log" >&2; exit 1; }

echo "PASS: Adaptive fallback logic triggered shrink->individual->regrow sequence and downloaded $actual/$expected packages." >&2
