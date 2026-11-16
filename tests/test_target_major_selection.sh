#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

export MYREPO_SOURCE_ONLY=1 ELEVATE_COMMANDS=0 DEBUG_LEVEL=0 REPO_OS_MAJOR=10
# shellcheck source=/dev/null
source "$REPO_ROOT/myrepo.sh"
LOCAL_REPO_PATH="$TEMP_DIR/repo"
MANUAL_REPOS=("ol10_edge")
REPOSITORIES=("ol10_edge" "ol10_u2_developer_EPEL")
REPOS='' EXCLUDE_REPOS=''
GLOBAL_ENABLED_REPOS_CACHE_POPULATED=1
export INSTALLED='nagios-plugins-load|0|2.5|2.el9|x86_64|@System'
export TEST_ORIGIN='@ol9_developer_EPEL'
VENDOR='Oracle America'
rpm() {
    if [[ "$1" == -q && "$2" == --qf ]]; then
        printf '%s\n' "$VENDOR"
    else
        command rpm "$@"
    fi
}
cat >"$TEMP_DIR/dnf" <<'DNF_STUB'
#!/usr/bin/env bash
    case "$1" in
        repoquery) printf '%s\n' "$INSTALLED" ;;
        list) printf 'leapp.noarch 0.20.0-1.el9 %s\n' "$TEST_ORIGIN" ;;
    esac
DNF_STUB
chmod +x "$TEMP_DIR/dnf"
get_dnf_cmd() { DNF_CMD=("$TEMP_DIR/dnf"); }
available_repo_packages["ol10_u2_developer_EPEL"]=$'nagios-plugins-load|0|2.4.12|4.el10_2|x86_64\nnagios-plugins-load|0|2.4.9|1.el10_2|x86_64\nnagios-plugins-load|0|99|1.el10_2|aarch64'

expected='nagios-plugins-load|0|2.4.12|4.el10_2|x86_64|ol10_u2_developer_EPEL'
for REPOS in '' ol10_u2_developer_EPEL; do
    result="$(gather_installed_packages)"
    [[ "$result" == "$expected" ]]
done
REPOS=''
printf 'PASS: foreign Oracle NEVRA selects lower-version OL10 candidate, including explicit repo filter\n'

available_repo_packages["ol10_u2_developer_EPEL"]+=$'\nnagios-plugins-load|1|1.0|1.el10_2|x86_64'
result="$(gather_installed_packages)"
[[ "$result" == 'nagios-plugins-load|1|1.0|1.el10_2|x86_64|ol10_u2_developer_EPEL' ]]
available_repo_packages["ol10_appstream"]='nagios-plugins-load|1|1.0|1.el10_2|x86_64'
if gather_installed_packages >"$TEMP_DIR/ambiguous.out" 2>"$TEMP_DIR/ambiguous.err"; then exit 1; fi
grep -q 'No unambiguous OL10 candidate' "$TEMP_DIR/ambiguous.err"
EXCLUDE_REPOS=ol10_appstream
result="$(gather_installed_packages)"
[[ "$result" == 'nagios-plugins-load|1|1.0|1.el10_2|x86_64|ol10_u2_developer_EPEL' ]]
EXCLUDE_REPOS=''
available_repo_packages=()
if gather_installed_packages >"$TEMP_DIR/missing.out" 2>"$TEMP_DIR/missing.err"; then exit 1; fi
grep -q 'No unambiguous OL10 candidate' "$TEMP_DIR/missing.err"
printf 'PASS: epoch ordering, ambiguity, exclusion and missing-candidate failures\n'

INSTALLED='nagios-plugins-load|0|2.4.12|4.el10_2|x86_64|@System'
[[ "$(gather_installed_packages)" == "$INSTALLED" ]]
INSTALLED='nagios-plugins-load|0|2.5|2.el9|x86_64|@System'
REPO_OS_MAJOR=''
[[ "$(gather_installed_packages)" == "$INSTALLED" ]]
REPO_OS_MAJOR=10
VENDOR='Third Party'
[[ "$(gather_installed_packages)" == "$INSTALLED" ]]
VENDOR='Oracle America'
repo_package_lookup["nagios-plugins-load|0|2.5|2.el9|x86_64"]=code
[[ "$(gather_installed_packages)" == "$INSTALLED" ]]
repo_package_lookup["nagios-plugins-load|0|2.5|2.el9|x86_64"]=ol10_edge
[[ "$(gather_installed_packages)" == "$INSTALLED" ]]
repo_package_lookup=()
printf 'PASS: native, legacy, third-party and exact selected manual metadata remain unchanged\n'

TEST_ORIGIN='@System'
if determine_repo_source leapp 0 0.20.0 1.el9 noarch >"$TEMP_DIR/origin"; then exit 1; fi
[[ "$(cat "$TEMP_DIR/origin")" == Invalid ]]
mkdir -p "$LOCAL_REPO_PATH/ol10_edge/getPackage"
: >"$LOCAL_REPO_PATH/ol10_edge/getPackage/leapp-0.20.0-1.el9.noarch.rpm"
[[ "$(determine_repo_source leapp 0 0.20.0 1.el9 noarch)" == ol10_edge ]]
printf 'PASS: explicit major disables OL9 vendor guesses but retains exact manual files\n'
