#!/usr/bin/env bash
set -euo pipefail

# Regression test: @System packages must be filtered by their resolved source
# repository, not by the DNF origin marker.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
STUB_BIN="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR" "$STUB_BIN"' EXIT

cat >"$STUB_BIN/dnf" <<'DNF_STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    repolist)
        printf '%s\n' "repo id    repo name" "selected_repo Selected Repository"
        ;;
    repoquery)
        printf '%s\n' "system-pkg|0|1.2|3.el9|x86_64|@System"
        ;;
esac
DNF_STUB
chmod +x "$STUB_BIN/dnf"
export PATH="$STUB_BIN:$PATH"
export MYREPO_SOURCE_ONLY=1
export ELEVATE_COMMANDS=0
export LOCAL_REPO_PATH="$TEMP_DIR/repo"
export GLOBAL_ENABLED_REPOS_CACHE_POPULATED=0

# shellcheck source=/dev/null
source "$REPO_ROOT/myrepo.sh"
REPOS="selected_repo"
EXCLUDE_REPOS=""
repo_package_lookup=()
available_repo_packages["selected_repo"]="system-pkg|0|1.2|3.el9|x86_64"
set +e
build_repo_lookup_index
set -e

set +e
result="$(gather_installed_packages)"
status=$?
set -e
expected="system-pkg|0|1.2|3.el9|x86_64|selected_repo"

if [[ $status -ne 0 || "$result" != "$expected" ]]; then
    printf 'FAIL: expected %s, got %s\n' "$expected" "$result" >&2
    exit 1
fi

printf 'PASS: @System package retained through selected repository filter\n'
