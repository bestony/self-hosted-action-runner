#!/usr/bin/env bash
# ==============================================================================
# Podman Installer Test Suite
#
# install-podman.sh is exercised against stub podman/systemctl/journalctl
# binaries and writes its Quadlet units into a temporary directory, so the host
# needs neither Podman, nor systemd, nor root privileges.
#
# Platform checks are disabled with GHR_UNSAFE_SKIP_PLATFORM_CHECKS=1, which also
# pins install-podman.sh to the caller's privileges (never sudo) so the stubs are
# the only binaries that can be reached.
# ==============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SH="${PROJECT_ROOT}/install-podman.sh"

PASSED=0
FAILED=0

BASE_TMP="$(mktemp -d /tmp/ghr-podman-test-XXXXXX)"
STUB_DIR="${BASE_TMP}/stubs"
STUB_LOG="${BASE_TMP}/calls"
QUADLET_DIR="${BASE_TMP}/quadlet"
mkdir -p "$STUB_DIR" "$STUB_LOG" "$QUADLET_DIR"

assert_equals() {
    local expected="$1"
    local actual="$2"
    local msg="$3"
    if [ "$expected" = "$actual" ]; then
        printf "  [PASS] %s\n" "$msg"
        PASSED=$((PASSED + 1))
    else
        printf "  [FAIL] %s: expected '%s', got '%s'\n" "$msg" "$expected" "$actual" >&2
        FAILED=$((FAILED + 1))
    fi
}

assert_success() {
    local exit_code="$1"
    local msg="$2"
    if [ "$exit_code" -eq 0 ]; then
        printf "  [PASS] %s\n" "$msg"
        PASSED=$((PASSED + 1))
    else
        printf "  [FAIL] %s: command exited with code %d\n" "$msg" "$exit_code" >&2
        FAILED=$((FAILED + 1))
    fi
}

assert_failure() {
    local exit_code="$1"
    local msg="$2"
    if [ "$exit_code" -ne 0 ]; then
        printf "  [PASS] %s\n" "$msg"
        PASSED=$((PASSED + 1))
    else
        printf "  [FAIL] %s: command unexpectedly succeeded with code 0\n" "$msg" >&2
        FAILED=$((FAILED + 1))
    fi
}

assert_contains() {
    local file="$1"
    local pattern="$2"
    local msg="$3"
    if [ -f "$file" ] && grep -qF -- "$pattern" "$file" 2>/dev/null; then
        printf "  [PASS] %s\n" "$msg"
        PASSED=$((PASSED + 1))
    else
        printf "  [FAIL] %s: '%s' not found in %s\n" "$msg" "$pattern" "$file" >&2
        FAILED=$((FAILED + 1))
    fi
}

assert_not_contains() {
    local file="$1"
    local pattern="$2"
    local msg="$3"
    if [ ! -f "$file" ] || ! grep -qF -- "$pattern" "$file" 2>/dev/null; then
        printf "  [PASS] %s\n" "$msg"
        PASSED=$((PASSED + 1))
    else
        printf "  [FAIL] %s: unexpected '%s' in %s\n" "$msg" "$pattern" "$file" >&2
        FAILED=$((FAILED + 1))
    fi
}

assert_path_exists() {
    local target="$1"
    local msg="$2"
    if [ -e "$target" ]; then
        printf "  [PASS] %s\n" "$msg"
        PASSED=$((PASSED + 1))
    else
        printf "  [FAIL] %s: %s does not exist\n" "$msg" "$target" >&2
        FAILED=$((FAILED + 1))
    fi
}

assert_path_missing() {
    local target="$1"
    local msg="$2"
    if [ ! -e "$target" ]; then
        printf "  [PASS] %s\n" "$msg"
        PASSED=$((PASSED + 1))
    else
        printf "  [FAIL] %s: %s still exists\n" "$msg" "$target" >&2
        FAILED=$((FAILED + 1))
    fi
}

assert_is_symlink() {
    local target="$1"
    local msg="$2"
    if [ -L "$target" ]; then
        printf "  [PASS] %s\n" "$msg"
        PASSED=$((PASSED + 1))
    else
        printf "  [FAIL] %s: %s is not a symlink\n" "$msg" "$target" >&2
        FAILED=$((FAILED + 1))
    fi
}

count_pattern() {
    local file="$1"
    local pattern="$2"
    if [ ! -f "$file" ]; then
        echo "0"
        return 0
    fi
    grep -cE -- "$pattern" "$file" 2>/dev/null || true
}

get_file_perms() {
    local target="$1"
    # GNU stat first: on Linux `stat -f` means filesystem status and succeeds with unrelated output.
    if stat -c "%a" "$target" 2>/dev/null; then
        return 0
    fi
    stat -f "%OLp" "$target" 2>/dev/null || echo "unknown"
}

env_value_of() {
    local key="$1"
    local file="$2"
    grep -E "^${key}=" "$file" | tail -n 1 | cut -d= -f2-
}

reset_stub_logs() {
    : > "${STUB_LOG}/podman.log"
    : > "${STUB_LOG}/systemctl.log"
    : > "${STUB_LOG}/journalctl.log"
}

# install-podman.sh probes for binaries on PATH, so simulating an absent binary
# requires a PATH that cannot resolve it. Narrowing PATH is not enough: runner
# images ship real tooling in /usr/bin (GitHub's ubuntu-24.04 image includes
# Podman 4.9.3), so PATH=/usr/bin:/bin still finds a usable podman. This helper
# links the system binaries into a private directory minus the exclusions, which
# makes absence explicit and host-independent.
make_bin_sandbox() {
    local sandbox="$1"
    local excluded=" $2 "
    local src entry name
    mkdir -p "$sandbox"
    for src in /usr/local/bin /usr/bin /bin /usr/sbin /sbin /usr/local/sbin; do
        [ -d "$src" ] || continue
        for entry in "$src"/*; do
            [ -e "$entry" ] || continue
            name="${entry##*/}"
            case "$excluded" in
                *" $name "*) continue ;;
            esac
            if [ -e "$sandbox/$name" ] || [ -L "$sandbox/$name" ]; then
                continue
            fi
            ln -s "$entry" "$sandbox/$name" 2>/dev/null || true
        done
    done
}

# ------------------------------------------------------------------------------
# Stub binaries
# ------------------------------------------------------------------------------
cat > "${STUB_DIR}/podman" <<'STUB'
#!/usr/bin/env bash
printf 'podman %s\n' "$*" >> "${STUB_LOG}/podman.log"
case "${1:-}" in
    --version)
        echo "podman version 4.9.3"
        ;;
    ps)
        echo "Up 1 minute"
        ;;
    logs)
        echo "stub container logs"
        ;;
    network)
        # Bridge name reported to the egress preflight, when a test sets one.
        if [ "${2:-}" = "inspect" ] && [ -n "${STUB_PODMAN_NETWORK_IFACE:-}" ]; then
            printf '%s\n' "${STUB_PODMAN_NETWORK_IFACE}"
        fi
        ;;
    run)
        # The installer probes container egress with a short-lived container;
        # tests decide what that probe reports.
        if [ -n "${STUB_PODMAN_RUN_OUTPUT:-}" ]; then
            printf '%s\n' "${STUB_PODMAN_RUN_OUTPUT}"
        fi
        ;;
esac
exit 0
STUB

cat > "${STUB_DIR}/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "${STUB_LOG}/systemctl.log"
case "${1:-}" in
    is-active)
        echo "active"
        ;;
    is-enabled)
        echo "generated"
        ;;
esac
exit 0
STUB

cat > "${STUB_DIR}/journalctl" <<'STUB'
#!/usr/bin/env bash
printf 'journalctl %s\n' "$*" >> "${STUB_LOG}/journalctl.log"
if [ -n "${STUB_JOURNAL_TEXT:-}" ]; then
    printf '%s\n' "${STUB_JOURNAL_TEXT}"
fi
exit 0
STUB

chmod +x "${STUB_DIR}/podman" "${STUB_DIR}/systemctl" "${STUB_DIR}/journalctl"
reset_stub_logs

run_installer_with_quadlet_dir() {
    local quadlet_dir="$1"
    shift
    GHR_UNSAFE_SKIP_PLATFORM_CHECKS=1 \
    GHR_QUADLET_DIR="${quadlet_dir}" \
    STUB_LOG="${STUB_LOG}" \
    STUB_JOURNAL_TEXT="${STUB_JOURNAL_TEXT:-Listening for Jobs}" \
    PATH="${STUB_DIR}:${PATH}" \
    bash "${INSTALL_SH}" "$@"
}

run_installer() {
    run_installer_with_quadlet_dir "${QUADLET_DIR}" "$@"
}

printf "==================================================\n"
printf "Running Podman Installer Test Suite\n"
printf "==================================================\n"

# ------------------------------------------------------------------------------
# Test 1: Non-interactive generation with 2 runners + internal cache
# ------------------------------------------------------------------------------
printf "\nTest 1: Non-interactive install (2 runners + internal cache, --no-start)\n"
TEST1_DIR="$(mktemp -d "${BASE_TMP}/t1-XXXXXX")"
trap 'rm -rf "${BASE_TMP:-}"' EXIT

TOKEN_A="SECRET_PODMAN_TOKEN_A_12345"
TOKEN_B="SECRET_PODMAN_TOKEN_B_67890"

rm -f "${QUADLET_DIR}"/ghr-*.container
FOREIGN_UNIT="${QUADLET_DIR}/ghr-someone-else-deadbeef-runner-1.container"
printf '[Container]\nImage=example.invalid/other:latest\n' > "$FOREIGN_UNIT"

reset_stub_logs
set +e
GHR_RUNNER_1_URL="https://github.com/my-org/repo-a" \
GHR_RUNNER_1_TOKEN="$TOKEN_A" \
GHR_RUNNER_1_LABELS="self-hosted,linux,gpu" \
GHR_RUNNER_1_NAME_PREFIX="runner-a-" \
GHR_RUNNER_2_URL="https://github.com/my-org/repo-b" \
GHR_RUNNER_2_TOKEN="$TOKEN_B" \
GHR_RUNNER_2_NAME_PREFIX="runner-b-" \
run_installer --non-interactive --no-start --dir "$TEST1_DIR" > "${BASE_TMP}/test1.log" 2>&1
TEST1_EC=$?
set -e
assert_success "$TEST1_EC" "install-podman.sh succeeds with a valid configuration ('see ${BASE_TMP}/test1.log')"

PROJECT_NAME="$(env_value_of PROJECT_NAME "${TEST1_DIR}/.env")"
assert_equals "2" "$(env_value_of RUNNER_COUNT "${TEST1_DIR}/.env")" "RUNNER_COUNT is 2 in generated .env"
assert_equals "podman" "$(env_value_of RUNTIME "${TEST1_DIR}/.env")" ".env records the podman runtime"
assert_equals "600" "$(get_file_perms "${TEST1_DIR}/.env")" ".env has strict file permissions (600)"

RUNNER1_UNIT="${QUADLET_DIR}/${PROJECT_NAME}-runner-1.container"
CACHE_UNIT="${QUADLET_DIR}/${PROJECT_NAME}-cache.container"
RUNNER1_ENV="${TEST1_DIR}/env/${PROJECT_NAME}-runner-1.env"
CACHE_ENV="${TEST1_DIR}/env/${PROJECT_NAME}-cache.env"

ALL_FILES_PRESENT=0
for target in "$RUNNER1_UNIT" "$CACHE_UNIT" "$RUNNER1_ENV" "$CACHE_ENV"; do
    [ -f "$target" ] || ALL_FILES_PRESENT=1
done
assert_success "$ALL_FILES_PRESENT" "Expected Quadlet units and per-service env files exist"
assert_equals "600" "$(get_file_perms "$RUNNER1_ENV")" "runner env file has strict permissions (600)"
assert_equals "600" "$(get_file_perms "$CACHE_ENV")" "cache env file has strict permissions (600)"

assert_contains "$RUNNER1_ENV" "RUNNER_TOKEN=${TOKEN_A}" "Registration token is stored in the 0600 env file"
assert_not_contains "$RUNNER1_UNIT" "$TOKEN_A" "Registration token is NOT stored in the unit file"
assert_not_contains "$CACHE_UNIT" "$TOKEN_A" "Registration token is NOT stored in the cache unit"

assert_contains "$RUNNER1_UNIT" "EnvironmentFile=${RUNNER1_ENV}" "Unit loads its environment from the generated env file"
assert_contains "$RUNNER1_UNIT" "ContainerName=${PROJECT_NAME}-runner-1" "Container name matches the unit base name"
assert_contains "$RUNNER1_UNIT" "Network=${PROJECT_NAME}-net" "Unit joins the dedicated Podman network"
assert_contains "$RUNNER1_UNIT" "LogDriver=journald" "Container logs go to the journal"
assert_contains "$RUNNER1_UNIT" "Wants=${PROJECT_NAME}-cache.service" "Runner waits for the cache service (soft ordering)"
assert_contains "$RUNNER1_UNIT" "Volume=${TEST1_DIR}/work/runner-1:${TEST1_DIR}/work/runner-1" "Workspace keeps the same path inside and outside the container"
assert_contains "$RUNNER1_UNIT" "Restart=always" "Unit restarts the container on failure"
assert_contains "$RUNNER1_UNIT" "RestartSec=10" "Unit paces restarts instead of hot-looping against the GitHub API"
assert_contains "$RUNNER1_UNIT" "StartLimitIntervalSec=0" "Unit keeps retrying instead of parking in 'failed' after a fast failure"
assert_contains "$CACHE_UNIT" "StartLimitIntervalSec=0" "Cache unit keeps retrying as well"
# Quadlet rejects keys that belong to another group, so the section matters.
assert_equals "true" \
    "$([ "$(grep -n '^StartLimitIntervalSec=0$' "$RUNNER1_UNIT" | head -1 | cut -d: -f1)" -lt "$(grep -n '^\[Container\]$' "$RUNNER1_UNIT" | head -1 | cut -d: -f1)" ] && echo true || echo false)" \
    "StartLimitIntervalSec sits in the [Unit] section"
assert_contains "$RUNNER1_UNIT" "WantedBy=multi-user.target default.target" "Unit declares boot startup through [Install] WantedBy"

assert_contains "$CACHE_UNIT" "Network=${PROJECT_NAME}-net:alias=cache-server" "Internal cache mode registers the cache-server network alias"
assert_contains "$CACHE_UNIT" "HealthCmd=" "Cache unit declares a health check"
assert_contains "$CACHE_ENV" "CACHE_CLEANUP_OLDER_THAN_DAYS=90" "Cache cleanup window is derived from the stack defaults"
assert_contains "$CACHE_ENV" "STORAGE_FILESYSTEM_PATH=/data/cache" "Cache data is stored on the dedicated volume"
assert_not_contains "$CACHE_UNIT" "PublishPort=" "Internal cache mode does not publish a host port"
assert_contains "$RUNNER1_ENV" "ACTIONS_RESULTS_URL=http://cache-server:3000/" "Runner env points the cache URL at the internal DNS alias"

assert_equals "0" "$(count_pattern "${STUB_LOG}/systemctl.log" '^systemctl enable')" "Installer never calls 'systemctl enable'"
assert_equals "1" "$(count_pattern "${STUB_LOG}/systemctl.log" '^systemctl daemon-reload')" "Installer reloads systemd once to register the Quadlet units"
assert_equals "0" "$(count_pattern "${STUB_LOG}/systemctl.log" '^systemctl start')" "--no-start does not start any unit"
assert_path_exists "${TEST1_DIR}/work/runner-1" "Job workspace for runner 1 is created"
assert_path_exists "${TEST1_DIR}/work/runner-2" "Job workspace for runner 2 is created"
assert_path_exists "${TEST1_DIR}/README.txt" "README.txt with operations commands is generated"
assert_contains "${TEST1_DIR}/README.txt" "--upgrade" "README.txt documents the upgrade command"
assert_path_exists "$FOREIGN_UNIT" "Units of other projects in the Quadlet directory are left alone"

# ------------------------------------------------------------------------------
# Test 2: Full start path with registration success
# ------------------------------------------------------------------------------
printf "\nTest 2: Start path (1 runner, cache disabled) with successful registration\n"
TEST2_DIR="$(mktemp -d "${BASE_TMP}/t2-XXXXXX")"
rm -f "${QUADLET_DIR}"/ghr-*.container

reset_stub_logs
set +e
GHR_RUNNER_1_URL="https://github.com/my-org/single" \
GHR_RUNNER_1_TOKEN="SECRET_PODMAN_TOKEN_C_11111" \
GHR_CACHE=0 \
run_installer --non-interactive --dir "$TEST2_DIR" > "${BASE_TMP}/test2.log" 2>&1
TEST2_EC=$?
set -e
assert_success "$TEST2_EC" "Full install with started units exits 0 when the runner registers"

PROJECT2="$(env_value_of PROJECT_NAME "${TEST2_DIR}/.env")"
assert_equals "1" "$(count_pattern "${STUB_LOG}/systemctl.log" "^systemctl start ${PROJECT2}-runner-1.service$")" "The runner unit is started exactly once"
assert_equals "0" "$(count_pattern "${STUB_LOG}/systemctl.log" '^systemctl enable')" "Startup path never calls 'systemctl enable'"
assert_equals "1" "$(count_pattern "${STUB_LOG}/podman.log" '^podman pull ghcr.io/bestony/self-hosted-action-runner:latest$')" "Runner image is pulled before startup"
assert_path_missing "${QUADLET_DIR}/${PROJECT2}-cache.container" "Cache disabled: no cache unit is generated"
assert_not_contains "${TEST2_DIR}/env/${PROJECT2}-runner-1.env" "ACTIONS_RESULTS_URL" "Cache disabled: no cache URL is injected"
assert_contains "${BASE_TMP}/test2.log" "OK: Listening for Jobs" "Registration state is reported as OK"

# ------------------------------------------------------------------------------
# Test 3: Registration failure stops the failing runner and exits 1
# ------------------------------------------------------------------------------
printf "\nTest 3: Registration failure (404) stops the runner and exits 1\n"
TEST3_DIR="$(mktemp -d "${BASE_TMP}/t3-XXXXXX")"

reset_stub_logs
set +e
STUB_JOURNAL_TEXT="Http response code: NotFound from 'POST https://api.github.com/actions/runner-registration'" \
GHR_RUNNER_1_URL="https://github.com/my-org/broken" \
GHR_RUNNER_1_TOKEN="SECRET_PODMAN_TOKEN_D_22222" \
GHR_CACHE=0 \
run_installer --non-interactive --dir "$TEST3_DIR" > "${BASE_TMP}/test3.log" 2>&1
TEST3_EC=$?
set -e
assert_failure "$TEST3_EC" "Install fails when the registration token is rejected"
PROJECT3="$(env_value_of PROJECT_NAME "${TEST3_DIR}/.env")"
assert_equals "1" "$(count_pattern "${STUB_LOG}/systemctl.log" "^systemctl stop ${PROJECT3}-runner-1.service$")" "Failing runner unit is stopped instead of restart-looping"
assert_contains "${BASE_TMP}/test3.log" "Registration failed (404" "Failure reason is reported to the operator"

# ------------------------------------------------------------------------------
# Test 4: Host cache mode publishes the port and points runners at the host URL
# ------------------------------------------------------------------------------
printf "\nTest 4: Host cache mode\n"
TEST4_DIR="$(mktemp -d "${BASE_TMP}/t4-XXXXXX")"
rm -f "${QUADLET_DIR}"/ghr-*.container

set +e
GHR_RUNNER_1_URL="https://github.com/my-org/host-cache" \
GHR_RUNNER_1_TOKEN="SECRET_PODMAN_TOKEN_E_33333" \
GHR_CACHE_MODE=host \
GHR_CACHE_PORT=32123 \
GHR_CACHE_URL="http://203.0.113.7:32123" \
GHR_CACHE_CLEANUP_DAYS=7 \
run_installer --non-interactive --no-start --dir "$TEST4_DIR" > "${BASE_TMP}/test4.log" 2>&1
TEST4_EC=$?
set -e
assert_success "$TEST4_EC" "Host cache mode installs successfully"

PROJECT4="$(env_value_of PROJECT_NAME "${TEST4_DIR}/.env")"
assert_contains "${QUADLET_DIR}/${PROJECT4}-cache.container" "PublishPort=32123:3000" "Host cache mode publishes the configured port"
assert_contains "${TEST4_DIR}/env/${PROJECT4}-runner-1.env" "ACTIONS_RESULTS_URL=http://203.0.113.7:32123/" "Runner env uses the host-reachable cache URL"
assert_contains "${TEST4_DIR}/env/${PROJECT4}-cache.env" "CACHE_CLEANUP_OLDER_THAN_DAYS=7" "GHR_CACHE_CLEANUP_DAYS overrides the cache cleanup window"

# ------------------------------------------------------------------------------
# Test 5: Add mode keeps existing targets
# ------------------------------------------------------------------------------
printf "\nTest 5: Add mode (GHR_MODE=add) appends an instance\n"
set +e
GHR_MODE=add \
GHR_RUNNER_1_URL="https://github.com/my-org/second" \
GHR_RUNNER_1_TOKEN="SECRET_PODMAN_TOKEN_F_44444" \
run_installer --non-interactive --no-start --dir "$TEST4_DIR" > "${BASE_TMP}/test5.log" 2>&1
TEST5_EC=$?
set -e
assert_success "$TEST5_EC" "Add mode installs successfully"

assert_equals "2" "$(env_value_of RUNNER_COUNT "${TEST4_DIR}/.env")" "Add mode appends to RUNNER_COUNT"
assert_equals "https://github.com/my-org/host-cache" "$(env_value_of RUNNER_1_URL "${TEST4_DIR}/.env")" "Existing runner 1 URL is preserved"
assert_equals "https://github.com/my-org/second" "$(env_value_of RUNNER_2_URL "${TEST4_DIR}/.env")" "New target is appended as runner 2"
assert_path_exists "${QUADLET_DIR}/${PROJECT4}-runner-2.container" "Unit for the appended instance is generated"

# ------------------------------------------------------------------------------
# Test 6: Stale units of the same project are removed
# ------------------------------------------------------------------------------
printf "\nTest 6: Stale instance units are removed on reconfigure\n"
rm -f "${QUADLET_DIR}"/ghr-*.container
set +e
GHR_RUNNER_1_URL="https://github.com/my-org/host-cache" \
GHR_RUNNER_1_TOKEN="SECRET_PODMAN_TOKEN_E_33333" \
GHR_RUNNER_2_URL="https://github.com/my-org/second" \
GHR_RUNNER_2_TOKEN="SECRET_PODMAN_TOKEN_F_44444" \
run_installer --non-interactive --no-start --dir "$TEST4_DIR" > "${BASE_TMP}/test6.log" 2>&1
TEST6_EC=$?
set -e
assert_success "$TEST6_EC" "Reinstall with 2 instances succeeds"
assert_equals "2" "$(env_value_of RUNNER_COUNT "${TEST4_DIR}/.env")" "Default (new) mode replaces the instance list with the given targets"

printf '[Container]\nImage=example.invalid/stale:latest\n' > "${QUADLET_DIR}/${PROJECT4}-runner-3.container"
set +e
GHR_MODE=reconfigure \
GHR_RUNNER_1_URL="https://github.com/my-org/host-cache" \
GHR_RUNNER_1_TOKEN="SECRET_PODMAN_TOKEN_E_33333" \
run_installer --non-interactive --no-start --dir "$TEST4_DIR" > "${BASE_TMP}/test6b.log" 2>&1
TEST6B_EC=$?
set -e
assert_success "$TEST6B_EC" "Reconfigure down to 1 instance succeeds"
assert_equals "1" "$(env_value_of RUNNER_COUNT "${TEST4_DIR}/.env")" "Reconfigure replaces the instance list"
assert_path_missing "${QUADLET_DIR}/${PROJECT4}-runner-3.container" "Unit of the removed instance 3 is deleted"
assert_path_missing "${QUADLET_DIR}/${PROJECT4}-runner-2.container" "Unit of the removed instance 2 is deleted"
assert_path_exists "${QUADLET_DIR}/${PROJECT4}-runner-1.container" "Unit of the kept instance survives"

# ------------------------------------------------------------------------------
# Test 7: Configuration validation failures
# ------------------------------------------------------------------------------
printf "\nTest 7: Configuration validation failures\n"
TEST7_DIR="$(mktemp -d "${BASE_TMP}/t7-XXXXXX")"

set +e
GHR_RUNNER_1_URL="https://github.com/my-org/no-token" \
run_installer --non-interactive --no-start --dir "$TEST7_DIR" > "${BASE_TMP}/test7a.log" 2>&1
TEST7A_EC=$?
set -e
assert_failure "$TEST7A_EC" "Missing registration token fails the install"

set +e
GHR_RUNNER_1_URL="not-a-github-url" \
GHR_RUNNER_1_TOKEN="SECRET_PODMAN_TOKEN_G_55555" \
run_installer --non-interactive --no-start --dir "$TEST7_DIR" > "${BASE_TMP}/test7b.log" 2>&1
TEST7B_EC=$?
set -e
assert_failure "$TEST7B_EC" "Invalid runner URL fails the install"
assert_path_missing "${TEST7_DIR}/.env" "Failed validation writes no .env"
assert_path_missing "${TEST7_DIR}/.install.lock" "Failed validation releases the install lock"

# ------------------------------------------------------------------------------
# Test 8: Path and argument validation
# ------------------------------------------------------------------------------
printf "\nTest 8: Path and argument validation\n"
set +e
run_installer --non-interactive --no-start --dir "${BASE_TMP}/space dir" > /dev/null 2>&1
SPACE_EC=$?
run_installer --non-interactive --no-start --dir "${BASE_TMP}/colon:dir" > /dev/null 2>&1
COLON_EC=$?
run_installer --non-interactive --no-start --dir "${BASE_TMP}/percent%dir" > /dev/null 2>&1
PERCENT_EC=$?
run_installer --bogus-flag > /dev/null 2>&1
UNKNOWN_EC=$?
run_installer --dir > /dev/null 2>&1
MISSING_EC=$?
run_installer --help > "${BASE_TMP}/help.log" 2>&1
HELP_EC=$?
set -e

assert_failure "$SPACE_EC" "Paths with whitespace are rejected"
assert_failure "$COLON_EC" "Paths with a colon are rejected"
assert_failure "$PERCENT_EC" "Paths with '%' (systemd specifier) are rejected"
assert_equals "2" "$UNKNOWN_EC" "Unknown option exits with code 2"
assert_equals "2" "$MISSING_EC" "--dir without a value exits with code 2"
assert_success "$HELP_EC" "--help exits with code 0"
assert_contains "${BASE_TMP}/help.log" "--uninstall" "--help documents the uninstall action"
assert_contains "${BASE_TMP}/help.log" "Podman >= 4.4" "--help states the Podman version requirement"

# ------------------------------------------------------------------------------
# Test 9: Concurrent run protection
# ------------------------------------------------------------------------------
printf "\nTest 9: Concurrent run protection\n"
TEST9_DIR="$(mktemp -d "${BASE_TMP}/t9-XXXXXX")"
mkdir -p "${TEST9_DIR}/.install.lock"
printf 'PID=1 TIMESTAMP=now USER=other\n' > "${TEST9_DIR}/.install.lock/info"

set +e
GHR_RUNNER_1_URL="https://github.com/my-org/lock" \
GHR_RUNNER_1_TOKEN="SECRET_PODMAN_TOKEN_H_66666" \
run_installer --non-interactive --no-start --dir "$TEST9_DIR" > "${BASE_TMP}/test9.log" 2>&1
LOCK_EC=$?
set -e
assert_failure "$LOCK_EC" "A held lock makes the installer refuse to run"
assert_contains "${BASE_TMP}/test9.log" "Concurrent run detected" "The lock failure names the conflicting run"

rm -rf "${TEST9_DIR}/.install.lock"
set +e
GHR_RUNNER_1_URL="https://github.com/my-org/lock" \
GHR_RUNNER_1_TOKEN="SECRET_PODMAN_TOKEN_H_66666" \
run_installer --non-interactive --no-start --dir "$TEST9_DIR" > "${BASE_TMP}/test9b.log" 2>&1
LOCK2_EC=$?
set -e
assert_success "$LOCK2_EC" "Installer runs once the lock is gone"
assert_path_missing "${TEST9_DIR}/.install.lock" "The lock is released when the installer exits"

# ------------------------------------------------------------------------------
# Test 10: Lifecycle subcommands
# ------------------------------------------------------------------------------
printf "\nTest 10: Lifecycle subcommands (--status/--stop/--restart/--upgrade)\n"
PROJECT9="$(env_value_of PROJECT_NAME "${TEST9_DIR}/.env")"

reset_stub_logs
set +e
run_installer --non-interactive --dir "$TEST9_DIR" --status > "${BASE_TMP}/test10-status.log" 2>&1
STATUS_EC=$?
set -e
assert_success "$STATUS_EC" "--status exits 0"
assert_contains "${BASE_TMP}/test10-status.log" "systemd units:" "--status prints the systemd unit table"
assert_contains "${BASE_TMP}/test10-status.log" "${PROJECT9}-runner-1.service" "--status lists the runner unit"

reset_stub_logs
set +e
run_installer --non-interactive --dir "$TEST9_DIR" --stop > "${BASE_TMP}/test10-stop.log" 2>&1
STOP_EC=$?
set -e
assert_success "$STOP_EC" "--stop exits 0"
assert_equals "1" "$(count_pattern "${STUB_LOG}/systemctl.log" "^systemctl stop ${PROJECT9}-runner-1.service$")" "--stop stops the runner unit"
assert_equals "0" "$(count_pattern "${STUB_LOG}/systemctl.log" '^systemctl start')" "--stop starts nothing"

reset_stub_logs
set +e
run_installer --non-interactive --dir "$TEST9_DIR" --upgrade > "${BASE_TMP}/test10-upgrade.log" 2>&1
UPGRADE_EC=$?
set -e
assert_success "$UPGRADE_EC" "--upgrade exits 0"
assert_equals "1" "$(count_pattern "${STUB_LOG}/podman.log" '^podman pull ghcr.io/bestony/self-hosted-action-runner:latest$')" "--upgrade pulls the configured image"
assert_equals "1" "$(count_pattern "${STUB_LOG}/systemctl.log" "^systemctl restart ${PROJECT9}-runner-1.service$")" "--upgrade restarts the unit on the new image"

reset_stub_logs
set +e
run_installer --non-interactive --dir "$TEST9_DIR" --restart > "${BASE_TMP}/test10-restart.log" 2>&1
RESTART_EC=$?
set -e
assert_success "$RESTART_EC" "--restart exits 0"
assert_equals "1" "$(count_pattern "${STUB_LOG}/systemctl.log" "^systemctl restart ${PROJECT9}-runner-1.service$")" "--restart restarts the runner unit"

# ------------------------------------------------------------------------------
# Test 11: Uninstall keeps data unless explicitly authorized
# ------------------------------------------------------------------------------
printf "\nTest 11: Uninstall\n"
FOREIGN2_UNIT="${QUADLET_DIR}/ghr-other-project-cafebabe-cache.container"
printf '[Container]\nImage=example.invalid/other:latest\n' > "$FOREIGN2_UNIT"

reset_stub_logs
set +e
run_installer --non-interactive --dir "$TEST9_DIR" --uninstall > "${BASE_TMP}/test11.log" 2>&1
UNINSTALL_EC=$?
set -e
assert_success "$UNINSTALL_EC" "--uninstall exits 0"
assert_path_missing "${QUADLET_DIR}/${PROJECT9}-runner-1.container" "Stack unit files are removed"
assert_path_missing "${QUADLET_DIR}/${PROJECT9}-cache.container" "Cache unit file is removed"
assert_path_exists "$FOREIGN2_UNIT" "Units of other projects survive the uninstall"
assert_path_exists "${TEST9_DIR}/.env" ".env is kept for traceability"
assert_equals "1" "$(count_pattern "${STUB_LOG}/systemctl.log" "^systemctl stop ${PROJECT9}-runner-1.service$")" "Uninstall stops the runner unit"
assert_equals "1" "$(count_pattern "${STUB_LOG}/systemctl.log" '^systemctl daemon-reload')" "Uninstall reloads systemd after removing units"
assert_equals "1" "$(count_pattern "${STUB_LOG}/podman.log" "^podman rm -f ${PROJECT9}-runner-1$")" "Uninstall removes the container"
assert_equals "0" "$(count_pattern "${STUB_LOG}/podman.log" '^podman volume rm')" "Volumes are kept without an explicit opt-in"
assert_path_exists "${TEST9_DIR}/work/runner-1" "Job workspaces are kept without an explicit opt-in"

reset_stub_logs
set +e
GHR_UNINSTALL_VOLUMES=yes \
GHR_UNINSTALL_WORKDIR=yes \
run_installer --non-interactive --dir "$TEST9_DIR" --uninstall > "${BASE_TMP}/test11b.log" 2>&1
UNINSTALL2_EC=$?
set -e
assert_success "$UNINSTALL2_EC" "--uninstall is idempotent when the stack is already gone"
assert_equals "1" "$(count_pattern "${STUB_LOG}/podman.log" "^podman volume rm ${PROJECT9}-runner-1-data$")" "GHR_UNINSTALL_VOLUMES=yes removes the runner volume"
assert_path_missing "${TEST9_DIR}/work/runner-1" "GHR_UNINSTALL_WORKDIR=yes removes the job workspace"
assert_equals "0" "$(count_pattern "${STUB_LOG}/systemctl.log" '^systemctl enable')" "Uninstall never calls 'systemctl enable'"

# ------------------------------------------------------------------------------
# Test 12: Interactive collection (prompts scripted through a pipe)
# ------------------------------------------------------------------------------
printf "\nTest 12: Interactive collection with scripted answers\n"
TEST12_DIR="$(mktemp -d "${BASE_TMP}/t12-XXXXXX")"
INTERACTIVE_TOKEN="SECRET_PODMAN_TOKEN_I_77777"

# Prompts in order: runner URL, token, name prefix (default), labels (default),
# instances (default), add another (n), cache server (n), images (defaults),
# write configuration (y).
printf '%s\n' \
    "https://github.com/my-org/interactive" \
    "$INTERACTIVE_TOKEN" \
    "" \
    "" \
    "" \
    "n" \
    "n" \
    "" \
    "" \
    "y" > "${BASE_TMP}/interactive-input.txt"

set +e
# The pty-less scripted conversation needs the GHR_PROMPT_STDIN test hook.
GHR_PROMPT_STDIN=1 GHR_UNSAFE_SKIP_PLATFORM_CHECKS=1 \
GHR_QUADLET_DIR="${QUADLET_DIR}" \
STUB_LOG="${STUB_LOG}" \
STUB_JOURNAL_TEXT="${STUB_JOURNAL_TEXT:-Listening for Jobs}" \
PATH="${STUB_DIR}:${PATH}" \
    bash "${INSTALL_SH}" --no-start --dir "$TEST12_DIR" \
    < "${BASE_TMP}/interactive-input.txt" > "${BASE_TMP}/test12.log" 2>&1
TEST12_EC=$?
set -e
assert_success "$TEST12_EC" "Interactive install completes with scripted answers"

PROJECT12="$(env_value_of PROJECT_NAME "${TEST12_DIR}/.env")"
assert_equals "1" "$(env_value_of RUNNER_COUNT "${TEST12_DIR}/.env")" "Interactive mode writes the configured instance count"
assert_equals "https://github.com/my-org/interactive" "$(env_value_of RUNNER_1_URL "${TEST12_DIR}/.env")" "Interactive mode records the entered URL"
assert_equals "false" "$(env_value_of CACHE_ENABLED "${TEST12_DIR}/.env")" "Answering 'n' to the cache question disables the cache"
assert_path_missing "${QUADLET_DIR}/${PROJECT12}-cache.container" "Declined cache generates no cache unit"
assert_contains "${TEST12_DIR}/env/${PROJECT12}-runner-1.env" "RUNNER_TOKEN=${INTERACTIVE_TOKEN}" "Interactive token lands in the 0600 env file"
assert_not_contains "${BASE_TMP}/test12.log" "$INTERACTIVE_TOKEN" "Secret input is never echoed back to the console"

# ------------------------------------------------------------------------------
# Test 13: Optional Quadlet generator validation
# ------------------------------------------------------------------------------
printf "\nTest 13: Quadlet generator validation (optional)\n"
GENERATOR=""
for candidate in \
    "$(command -v podman-system-generator 2>/dev/null || true)" \
    /usr/lib/systemd/system-generators/podman-system-generator \
    /usr/libexec/systemd/system-generators/podman-system-generator \
    /usr/local/lib/systemd/system-generators/podman-system-generator; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        GENERATOR="$candidate"
        break
    fi
done

if [ -z "$GENERATOR" ]; then
    printf "  [SKIP] podman-system-generator is not installed on this host\n"
else
    set +e
    QUADLET_UNIT_DIRS="${QUADLET_DIR}" "$GENERATOR" --dryrun > "${BASE_TMP}/quadlet-dryrun.out" 2>&1
    DRYRUN_EC=$?
    set -e
    assert_success "$DRYRUN_EC" "podman-system-generator parses the generated units (--dryrun)"
    assert_contains "${BASE_TMP}/quadlet-dryrun.out" "---${PROJECT12}-runner-1.service---" "Generator converts the runner unit into a service"
    assert_contains "${BASE_TMP}/quadlet-dryrun.out" "ExecStart=/usr/bin/podman run" "Generated service runs the container through podman"
    assert_contains "${BASE_TMP}/quadlet-dryrun.out" "WantedBy=multi-user.target" "Generated service keeps the boot startup target"
    # Podman builds differ in whether a rejected key fails the run or is only
    # reported, so assert the reporting as well: a silently dropped directive
    # would otherwise leave the stack running with a setting missing.
    assert_not_contains "${BASE_TMP}/quadlet-dryrun.out" "unsupported key" "Generator reports no unsupported keys"
    assert_not_contains "${BASE_TMP}/quadlet-dryrun.out" "is deprecated" "Generator reports no deprecated keys"

    # Boot startup cannot use `systemctl enable` for generated units: Quadlet has
    # to materialise the <target>.wants symlinks itself, and only a real
    # generator run proves that wiring exists. Cache is enabled here so both
    # unit kinds are covered.
    GEN_UNITS="${BASE_TMP}/generator-units"
    GEN_OUT="${BASE_TMP}/generator-out"
    rm -rf "$GEN_UNITS" "$GEN_OUT"
    mkdir -p "$GEN_UNITS" "$GEN_OUT"

    set +e
    # Stubs drive the installer here: the real generator is exercised below, but
    # the install itself must not depend on a booted systemd or a real Podman.
    GHR_RUNNER_1_URL="https://github.com/my-org/generator-check" \
    GHR_RUNNER_1_TOKEN="SECRET_GENERATOR_TOKEN_77777" \
        run_installer_with_quadlet_dir "${GEN_UNITS}" --non-interactive --no-start \
        --dir "${BASE_TMP}/generator-stack" > "${BASE_TMP}/test13-install.log" 2>&1
    GEN_INSTALL_EC=$?
    set -e
    assert_success "$GEN_INSTALL_EC" "Cache-enabled stack for generator validation is generated"

    GEN_UNIT_COUNT="$(find "${GEN_UNITS}" -maxdepth 1 -type f -name '*.container' | wc -l | tr -d ' ')"
    assert_equals "2" "$GEN_UNIT_COUNT" "Generator check stack writes both runner and cache units"

    GEN_RUNNER_UNIT="$(find "${GEN_UNITS}" -maxdepth 1 -type f -name '*-runner-1.container' -print -quit)"
    GEN_CACHE_UNIT="$(find "${GEN_UNITS}" -maxdepth 1 -type f -name '*-cache.container' -print -quit)"
    GEN_RUNNER_BASE="$(basename "${GEN_RUNNER_UNIT:-unit-not-found}" .container)"
    GEN_CACHE_BASE="$(basename "${GEN_CACHE_UNIT:-unit-not-found}" .container)"

    set +e
    QUADLET_UNIT_DIRS="${GEN_UNITS}" "$GENERATOR" "$GEN_OUT" > "${BASE_TMP}/generator.out" 2>&1
    GEN_RUN_EC=$?
    set -e
    assert_success "$GEN_RUN_EC" "Generator materialises units into the systemd generator directory"
    assert_is_symlink "${GEN_OUT}/multi-user.target.wants/${GEN_RUNNER_BASE}.service" "Generator wires the runner unit into multi-user.target.wants"
    assert_is_symlink "${GEN_OUT}/multi-user.target.wants/${GEN_CACHE_BASE}.service" "Generator wires the cache unit into multi-user.target.wants"
    assert_is_symlink "${GEN_OUT}/default.target.wants/${GEN_RUNNER_BASE}.service" "Generator wires the runner unit into default.target.wants"

    if command -v systemd-analyze >/dev/null 2>&1; then
        set +e
        systemd-analyze verify "${GEN_OUT}/${GEN_RUNNER_BASE}.service" "${GEN_OUT}/${GEN_CACHE_BASE}.service" \
            > "${BASE_TMP}/systemd-analyze.out" 2>&1
        VERIFY_EC=$?
        set -e
        assert_success "$VERIFY_EC" "systemd accepts the generated services (systemd-analyze verify)"
        if [ "$VERIFY_EC" -ne 0 ] && [ -s "${BASE_TMP}/systemd-analyze.out" ]; then
            sed 's/^/         /' "${BASE_TMP}/systemd-analyze.out" >&2
        fi
    else
        printf "  [SKIP] systemd-analyze is not installed on this host\n"
    fi
fi

# ------------------------------------------------------------------------------
# Test 14: SELinux opt-in (GHR_SELINUX=1)
# ------------------------------------------------------------------------------
printf "\nTest 14: SELinux opt-in (GHR_SELINUX=1)\n"
TEST14_DIR="$(mktemp -d "${BASE_TMP}/t14-XXXXXX")"

set +e
GHR_SELINUX=1 \
GHR_RUNNER_1_URL="https://github.com/my-org/selinux" \
GHR_RUNNER_1_TOKEN="SECRET_PODMAN_TOKEN_J_88888" \
GHR_CACHE=0 \
run_installer --non-interactive --no-start --dir "$TEST14_DIR" > "${BASE_TMP}/test14.log" 2>&1
TEST14_EC=$?
set -e
assert_success "$TEST14_EC" "GHR_SELINUX=1 installs successfully"

PROJECT14="$(env_value_of PROJECT_NAME "${TEST14_DIR}/.env")"
UNIT14="${QUADLET_DIR}/${PROJECT14}-runner-1.container"
assert_not_contains "$UNIT14" "SecurityLabelDisable=true" "GHR_SELINUX=1 keeps SELinux label separation enabled"
assert_contains "$UNIT14" "Volume=${TEST14_DIR}/work/runner-1:${TEST14_DIR}/work/runner-1:z" "GHR_SELINUX=1 relabels the job workspace mount"
assert_equals "false" "$(env_value_of SELINUX_DISABLE "${TEST14_DIR}/.env")" ".env records the SELinux decision for later runs"

# ------------------------------------------------------------------------------
# Test 15: Podman version floor and missing-Podman remediation
# ------------------------------------------------------------------------------
printf "\nTest 15: Podman version floor and missing-Podman remediation\n"
TEST15_DIR="$(mktemp -d "${BASE_TMP}/t15-XXXXXX")"
OLD_STUB_DIR="${BASE_TMP}/old-podman-stub"
mkdir -p "$OLD_STUB_DIR"
cat > "${OLD_STUB_DIR}/podman" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    --version)
        echo "podman version 4.3.1"
        ;;
    ps)
        echo ""
        ;;
esac
exit 0
STUB
chmod +x "${OLD_STUB_DIR}/podman"

set +e
# Unchecked mode does not enforce the floor; the operator still gets told about it.
GHR_UNSAFE_SKIP_PLATFORM_CHECKS=1 \
GHR_QUADLET_DIR="${QUADLET_DIR}" \
STUB_LOG="${STUB_LOG}" \
GHR_RUNNER_1_URL="https://github.com/my-org/old-podman" \
GHR_RUNNER_1_TOKEN="SECRET_PODMAN_TOKEN_K_99999" \
PATH="${OLD_STUB_DIR}:${STUB_DIR}:${PATH}" \
    bash "${INSTALL_SH}" --non-interactive --no-start \
    --dir "$TEST15_DIR" > "${BASE_TMP}/test15a.log" 2>&1
TEST15A_EC=$?
set -e
assert_success "$TEST15A_EC" "Unchecked mode does not enforce the Podman version floor"
assert_contains "${BASE_TMP}/test15a.log" "Podman 4.3.1 is below the required 4.4" "Too-old Podman is reported even when checks are disabled"

set +e
# No podman binary reachable at all: the installer must refuse with remediation.
NOPODMAN_BIN="${BASE_TMP}/t15-bin-without-podman"
make_bin_sandbox "$NOPODMAN_BIN" podman
if PATH="${NOPODMAN_BIN}" command -v podman >/dev/null 2>&1; then
    SANDBOX_EXCLUDES_PODMAN=false
else
    SANDBOX_EXCLUDES_PODMAN=true
fi
assert_equals "true" "$SANDBOX_EXCLUDES_PODMAN" "Fixture: the sandbox PATH cannot resolve podman"

GHR_UNSAFE_SKIP_PLATFORM_CHECKS=1 \
GHR_QUADLET_DIR="${QUADLET_DIR}" \
PATH="${NOPODMAN_BIN}" \
    bash "${INSTALL_SH}" --non-interactive --no-start --skip-podman-install \
    --dir "${BASE_TMP}/t15-missing" > "${BASE_TMP}/test15b.log" 2>&1
TEST15B_EC=$?
set -e
assert_failure "$TEST15B_EC" "Missing Podman with --skip-podman-install fails the install"
assert_contains "${BASE_TMP}/test15b.log" "--skip-podman-install was specified" "The failure names the flag that blocked installation"
assert_path_missing "${BASE_TMP}/t15-missing/.env" "Missing Podman fails before any configuration is written"

# ------------------------------------------------------------------------------
# Test 16: Registration verification must not report success it cannot back up
# ------------------------------------------------------------------------------
printf "\nTest 16: Registration verification edge cases\n"

# (a) First boot: the entrypoint logs "No existing runner configuration
# detected". It contains the words of the reuse message, and reading it as one
# reported success for a runner that was restart-looping on a rejected token.
printf "\n  (a) 'No existing runner configuration detected' is not a success\n"
TEST16A_DIR="$(mktemp -d "${BASE_TMP}/t16a-XXXXXX")"
reset_stub_logs
set +e
STUB_JOURNAL_TEXT="No existing runner configuration detected (.runner missing). Performing initial registration..." \
GHR_REGISTRATION_WAIT=2 \
GHR_RUNNER_1_URL="https://github.com/my-org/first-boot" \
GHR_RUNNER_1_TOKEN="SECRET_PODMAN_TOKEN_M_11111" \
GHR_CACHE=0 \
run_installer --non-interactive --dir "$TEST16A_DIR" > "${BASE_TMP}/test16a.log" 2>&1
TEST16A_EC=$?
set -e
assert_success "$TEST16A_EC" "An unverifiable registration is reported as a warning, not a hard failure"
assert_not_contains "${BASE_TMP}/test16a.log" "OK Runner #1 registered" "First-boot log text is never reported as a registered runner"
assert_contains "${BASE_TMP}/test16a.log" "No registration result within" "The operator is told that no registration result was observed"

# (b) Reused credentials plus the listener marker is a success.
printf "\n  (b) Reused credentials that come online are reported as OK\n"
TEST16B_DIR="$(mktemp -d "${BASE_TMP}/t16b-XXXXXX")"
reset_stub_logs
set +e
STUB_JOURNAL_TEXT="Existing runner configuration detected (.runner present). Skipping registration.
Listening for Jobs" \
GHR_REGISTRATION_WAIT=5 \
GHR_RUNNER_1_URL="https://github.com/my-org/reused" \
GHR_RUNNER_1_TOKEN="SECRET_PODMAN_TOKEN_N_22222" \
GHR_CACHE=0 \
run_installer --non-interactive --dir "$TEST16B_DIR" > "${BASE_TMP}/test16b.log" 2>&1
TEST16B_EC=$?
set -e
assert_success "$TEST16B_EC" "A reused configuration that reports itself online installs successfully"
assert_contains "${BASE_TMP}/test16b.log" "OK Runner #1 registered (OK_LISTENING)" "Success is based on the listener marker"

# (c) Credentials exist but the runner never comes online: not a success.
printf "\n  (c) Credentials without a listener are not reported as a success\n"
TEST16C_DIR="$(mktemp -d "${BASE_TMP}/t16c-XXXXXX")"
reset_stub_logs
set +e
STUB_JOURNAL_TEXT="Existing runner configuration detected (.runner present). Skipping registration." \
GHR_REGISTRATION_WAIT=2 \
GHR_RUNNER_1_URL="https://github.com/my-org/stale-creds" \
GHR_RUNNER_1_TOKEN="SECRET_PODMAN_TOKEN_O_33333" \
GHR_CACHE=0 \
run_installer --non-interactive --dir "$TEST16C_DIR" > "${BASE_TMP}/test16c.log" 2>&1
TEST16C_EC=$?
set -e
assert_success "$TEST16C_EC" "Present credentials alone do not fail the install"
assert_not_contains "${BASE_TMP}/test16c.log" "OK Runner #1 registered" "Present credentials alone are not reported as a registered runner"
assert_contains "${BASE_TMP}/test16c.log" "Credentials are in place, but the runner did not report" "The operator is told that the runner never reported itself online"

# (d) A stale success from an earlier container must not outvote a fresh failure.
printf "\n  (d) A fresh failure outvotes an earlier success in the same log\n"
TEST16D_DIR="$(mktemp -d "${BASE_TMP}/t16d-XXXXXX")"
reset_stub_logs
set +e
STUB_JOURNAL_TEXT="Listening for Jobs
Http response code: NotFound from 'POST https://api.github.com/actions/runner-registration'" \
GHR_REGISTRATION_WAIT=5 \
GHR_RUNNER_1_URL="https://github.com/my-org/restarted" \
GHR_RUNNER_1_TOKEN="SECRET_PODMAN_TOKEN_P_44444" \
GHR_CACHE=0 \
run_installer --non-interactive --dir "$TEST16D_DIR" > "${BASE_TMP}/test16d.log" 2>&1
TEST16D_EC=$?
set -e
assert_failure "$TEST16D_EC" "A container that failed after an earlier success fails the install"
assert_contains "${BASE_TMP}/test16d.log" "Registration failed (404" "The newest failure is the reported state"

# ------------------------------------------------------------------------------
# Test 17: Container egress preflight
# ------------------------------------------------------------------------------
printf "\nTest 17: Container egress preflight\n"
TEST17_DIR="$(mktemp -d "${BASE_TMP}/t17-XXXXXX")"

printf "\n  (a) A successful probe installs without warnings and uses --entrypoint\n"
reset_stub_logs
set +e
STUB_PODMAN_RUN_OUTPUT="PROBE_HTTP_200" \
GHR_RUNNER_1_URL="https://github.com/my-org/egress-ok" \
GHR_RUNNER_1_TOKEN="SECRET_PODMAN_TOKEN_Q_55555" \
GHR_CACHE=0 \
run_installer --non-interactive --dir "$TEST17_DIR" > "${BASE_TMP}/test17a.log" 2>&1
TEST17A_EC=$?
set -e
assert_success "$TEST17A_EC" "A reachable GitHub API passes the egress preflight"
assert_contains "${BASE_TMP}/test17a.log" "can reach the GitHub API" "The passing probe is reported"
assert_equals "1" "$(count_pattern "${STUB_LOG}/podman.log" '^podman run .*--entrypoint /bin/sh')" "The probe overrides the image entrypoint so it cannot register a runner"

printf "\n  (a2) An anonymous rate limit (403) is reachability, not a failure\n"
TEST17A2_DIR="$(mktemp -d "${BASE_TMP}/t17a2-XXXXXX")"
set +e
STUB_PODMAN_RUN_OUTPUT="PROBE_HTTP_403" \
GHR_RUNNER_1_URL="https://github.com/my-org/egress-rate-limited" \
GHR_RUNNER_1_TOKEN="SECRET_PODMAN_TOKEN_Q2_55556" \
GHR_CACHE=0 \
run_installer --non-interactive --dir "$TEST17A2_DIR" > "${BASE_TMP}/test17a2.log" 2>&1
TEST17A2_EC=$?
set -e
assert_success "$TEST17A2_EC" "A 403 from the anonymous probe does not block the installation"
assert_contains "${BASE_TMP}/test17a2.log" "reach the GitHub API (HTTP 403)" "The refusal is reported as a rate limit, not as a broken network"

printf "\n  (b) Blocked forwarding fails the install with the host fix\n"
TEST17B_DIR="$(mktemp -d "${BASE_TMP}/t17b-XXXXXX")"
set +e
STUB_PODMAN_RUN_OUTPUT="PROBE_EGRESS_FAILED" \
STUB_PODMAN_NETWORK_IFACE="podman1" \
GHR_RUNNER_1_URL="https://github.com/my-org/egress-blocked" \
GHR_RUNNER_1_TOKEN="SECRET_PODMAN_TOKEN_R_66666" \
GHR_CACHE=0 \
run_installer --non-interactive --dir "$TEST17B_DIR" > "${BASE_TMP}/test17b.log" 2>&1
TEST17B_EC=$?
set -e
assert_failure "$TEST17B_EC" "Blocked container egress stops the installation"
assert_contains "${BASE_TMP}/test17b.log" "cannot reach the GitHub API even though DNS resolves" "The diagnosis names dropped forwarding"
assert_contains "${BASE_TMP}/test17b.log" "sudo ufw route allow in on podman1" "The operator gets the concrete host fix for the detected bridge"
assert_contains "${BASE_TMP}/test17b.log" "GHR_SKIP_EGRESS_CHECK=yes" "The escape hatch is documented in the failure"

printf "\n  (b2) Without a reported bridge name the advice stays generic\n"
set +e
STUB_PODMAN_RUN_OUTPUT="PROBE_EGRESS_FAILED" \
GHR_RUNNER_1_URL="https://github.com/my-org/egress-no-iface" \
GHR_RUNNER_1_TOKEN="SECRET_PODMAN_TOKEN_R2_66667" \
GHR_CACHE=0 \
run_installer --non-interactive --dir "$(mktemp -d "${BASE_TMP}/t17b2-XXXXXX")" > "${BASE_TMP}/test17b2.log" 2>&1
TEST17B2_EC=$?
set -e
assert_failure "$TEST17B2_EC" "An unknown bridge name still stops the installation"
assert_contains "${BASE_TMP}/test17b2.log" "Allow forwarding from the container bridge" "The generic forwarding advice is used when the bridge name is unknown"

printf "\n  (c) A DNS failure and a missing probe image are reported differently\n"
TEST17C_DIR="$(mktemp -d "${BASE_TMP}/t17c-XXXXXX")"
set +e
STUB_PODMAN_RUN_OUTPUT="PROBE_DNS_FAILED" \
GHR_RUNNER_1_URL="https://github.com/my-org/egress-dns" \
GHR_RUNNER_1_TOKEN="SECRET_PODMAN_TOKEN_S_77777" \
GHR_CACHE=0 \
run_installer --non-interactive --dir "$TEST17C_DIR" > "${BASE_TMP}/test17c.log" 2>&1
TEST17C_EC=$?
set -e
assert_failure "$TEST17C_EC" "A container DNS failure stops the installation"
assert_contains "${BASE_TMP}/test17c.log" "cannot resolve api.github.com" "DNS failures are distinguished from blocked forwarding"

TEST17D_DIR="$(mktemp -d "${BASE_TMP}/t17d-XXXXXX")"
reset_stub_logs
set +e
GHR_SKIP_EGRESS_CHECK=yes \
GHR_RUNNER_1_URL="https://github.com/my-org/egress-skipped" \
GHR_RUNNER_1_TOKEN="SECRET_PODMAN_TOKEN_T_88888" \
GHR_CACHE=0 \
run_installer --non-interactive --dir "$TEST17D_DIR" > "${BASE_TMP}/test17d.log" 2>&1
TEST17D_EC=$?
set -e
assert_success "$TEST17D_EC" "GHR_SKIP_EGRESS_CHECK=yes installs without probing"
assert_contains "${BASE_TMP}/test17d.log" "Skipping the container egress check" "The skipped check is stated explicitly"
assert_equals "0" "$(count_pattern "${STUB_LOG}/podman.log" '^podman run')" "No probe container is started when the check is skipped"

# ------------------------------------------------------------------------------
# Test 18: Reconfigure keeps the recorded topology
# ------------------------------------------------------------------------------
printf "\nTest 18: Reconfigure keeps the recorded topology\n"
TEST18_DIR="$(mktemp -d "${BASE_TMP}/t18-XXXXXX")"

set +e
GHR_RUNNER_1_URL="https://github.com/my-org/two" \
GHR_RUNNER_1_TOKEN="SECRET_PODMAN_TOKEN_U_99991" \
GHR_RUNNER_1_INSTANCES=2 \
GHR_CACHE=internal \
run_installer --non-interactive --no-start --dir "$TEST18_DIR" > "${BASE_TMP}/test18-seed.log" 2>&1
TEST18_SEED_EC=$?
set -e
assert_success "$TEST18_SEED_EC" "Seed install configures a two-instance target"

PROJECT18="$(env_value_of PROJECT_NAME "${TEST18_DIR}/.env")"

# (a) Interactive reconfigure: the recorded topology comes back as prompt
# defaults, so pressing Enter must not shrink two runners down to one.
printf '%s\n' \
    "R" \
    "" \
    "SECRET_PODMAN_TOKEN_V_99992" \
    "" \
    "" \
    "" \
    "n" \
    "" \
    "" \
    "" \
    "" \
    "y" > "${BASE_TMP}/test18-input.txt"

set +e
GHR_PROMPT_STDIN=1 GHR_UNSAFE_SKIP_PLATFORM_CHECKS=1 \
GHR_QUADLET_DIR="${QUADLET_DIR}" \
STUB_LOG="${STUB_LOG}" \
STUB_JOURNAL_TEXT="${STUB_JOURNAL_TEXT:-Listening for Jobs}" \
PATH="${STUB_DIR}:${PATH}" \
    bash "${INSTALL_SH}" --no-start --dir "$TEST18_DIR" \
    < "${BASE_TMP}/test18-input.txt" > "${BASE_TMP}/test18a.log" 2>&1
TEST18A_EC=$?
set -e
assert_success "$TEST18A_EC" "Interactive reconfigure completes on Enter-only answers"
assert_contains "${BASE_TMP}/test18a.log" "[default: https://github.com/my-org/two]" "The recorded URL is offered as the prompt default"
assert_contains "${BASE_TMP}/test18a.log" "Number of runner instances for this target (to run jobs concurrently) [default: 2]" "The recorded instance count is offered as the prompt default"
assert_equals "2" "$(env_value_of RUNNER_COUNT "${TEST18_DIR}/.env")" "Reconfigure keeps the instance count"
assert_equals "true" "$(env_value_of CACHE_ENABLED "${TEST18_DIR}/.env")" "Reconfigure keeps the cache setting"
assert_path_exists "${QUADLET_DIR}/${PROJECT18}-runner-2.container" "The second instance unit survives a reconfigure"

# (b) Non-interactive reconfigure with only URL and token: GHR_* override the
# record, everything else comes from it instead of collapsing to defaults.
set +e
GHR_MODE=reconfigure \
GHR_RUNNER_1_URL="https://github.com/my-org/two" \
GHR_RUNNER_1_TOKEN="SECRET_PODMAN_TOKEN_W_99993" \
run_installer --non-interactive --no-start --dir "$TEST18_DIR" > "${BASE_TMP}/test18b.log" 2>&1
TEST18B_EC=$?
set -e
assert_success "$TEST18B_EC" "Non-interactive reconfigure completes with only URL and token"
assert_equals "2" "$(env_value_of RUNNER_COUNT "${TEST18_DIR}/.env")" "Non-interactive reconfigure keeps the instance count"
assert_equals "true" "$(env_value_of CACHE_ENABLED "${TEST18_DIR}/.env")" "Non-interactive reconfigure keeps the cache setting"
assert_equals "internal" "$(env_value_of CACHE_MODE "${TEST18_DIR}/.env")" "Non-interactive reconfigure keeps the cache mode"
assert_contains "${TEST18_DIR}/env/${PROJECT18}-runner-2.env" "RUNNER_TOKEN=SECRET_PODMAN_TOKEN_W_99993" "The new token reaches every instance"

printf "\n==================================================\n"
printf "Test Summary: %d passed, %d failed\n" "$PASSED" "$FAILED"
printf "==================================================\n"

if [ "$FAILED" -ne 0 ]; then
    exit 1
fi
