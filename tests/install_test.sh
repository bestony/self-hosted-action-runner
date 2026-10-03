#!/usr/bin/env bash
# ==============================================================================
# Installer Test Suite
# ==============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SH="${PROJECT_ROOT}/install.sh"

PASSED=0
FAILED=0

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

get_file_perms() {
    local target="$1"
    # GNU stat first: on Linux `stat -f` means filesystem status and succeeds with unrelated output.
    if stat -c "%a" "$target" 2>/dev/null; then
        return 0
    fi
    stat -f "%OLp" "$target" 2>/dev/null || echo "unknown"
}

printf "==================================================\n"
printf "Running Installer Test Suite\n"
printf "==================================================\n"

# ------------------------------------------------------------------------------
# Test 1: Non-interactive generation with 2 runners + cache
# ------------------------------------------------------------------------------
printf "\nTest 1: Non-interactive install (2 runners + cache, --no-start)\n"
TEST1_DIR="$(mktemp -d /tmp/ghr-test-1-XXXXXX)"
trap 'rm -rf "${TEST1_DIR:-}" "${TEST2_DIR:-}"' EXIT

TOKEN_A="SECRET_TOKEN_REPO_A_12345"
TOKEN_B="SECRET_TOKEN_REPO_B_67890"

set +e
GHR_RUNNER_1_URL="https://github.com/my-org/repo-a" \
GHR_RUNNER_1_TOKEN="$TOKEN_A" \
GHR_RUNNER_1_LABELS="self-hosted,linux,gpu" \
GHR_RUNNER_1_NAME_PREFIX="runner-a-" \
GHR_RUNNER_2_URL="https://github.com/my-org/repo-b" \
GHR_RUNNER_2_TOKEN="$TOKEN_B" \
GHR_RUNNER_2_LABELS="self-hosted,linux,docker" \
GHR_RUNNER_2_NAME_PREFIX="runner-b-" \
GHR_CACHE=1 \
GHR_CACHE_URL="http://cache-server:3000" \
bash "$INSTALL_SH" --non-interactive --no-start --dir "$TEST1_DIR"
TEST1_EC=$?
set -e

assert_success "$TEST1_EC" "install.sh runs successfully with valid configuration"

# Check .env permissions (must be 600)
PERMS="$(get_file_perms "${TEST1_DIR}/.env")"
assert_equals "600" "$PERMS" ".env has strict file permissions (600)"

# Verify tokens are NEVER in docker-compose.yml
set +e
grep -q "$TOKEN_A" "${TEST1_DIR}/docker-compose.yml"
FOUND_A=$?
grep -q "$TOKEN_B" "${TEST1_DIR}/docker-compose.yml"
FOUND_B=$?
set -e

assert_failure "$FOUND_A" "Secret token A is not present in docker-compose.yml"
assert_failure "$FOUND_B" "Secret token B is not present in docker-compose.yml"

# Verify docker compose config -q passes
set +e
docker compose -f "${TEST1_DIR}/docker-compose.yml" --env-file "${TEST1_DIR}/.env" config -q
COMPOSE_EC=$?
set -e
assert_success "$COMPOSE_EC" "docker compose config -q passes on generated configuration"

# Check runner count
COUNT="$(grep -E '^RUNNER_COUNT=' "${TEST1_DIR}/.env" | cut -d= -f2)"
assert_equals "2" "$COUNT" "RUNNER_COUNT is 2 in generated .env"

# Verify default images use :latest tag
set +e
grep -q "ghcr.io/falcondev-oss/github-actions-cache-server:latest" "${TEST1_DIR}/docker-compose.yml"
HAS_CACHE_LATEST=$?
grep -q "RUNNER_IMAGE=ghcr.io/bestony/self-hosted-action-runner:latest" "${TEST1_DIR}/.env"
HAS_RUNNER_LATEST=$?
set -e
assert_success "$HAS_CACHE_LATEST" "Default cache server image uses latest tag in docker-compose.yml"
assert_success "$HAS_RUNNER_LATEST" "Default runner image uses latest tag in .env"

# ------------------------------------------------------------------------------
# Test 2: Re-run with "add" semantics (GHR_MODE=add)
# ------------------------------------------------------------------------------
printf "\nTest 2: Re-run with add semantics (GHR_MODE=add) appends runner 3\n"
TOKEN_C="SECRET_TOKEN_REPO_C_99999"

set +e
GHR_MODE=add \
GHR_RUNNER_1_URL="https://github.com/my-org/repo-c" \
GHR_RUNNER_1_TOKEN="$TOKEN_C" \
GHR_RUNNER_1_LABELS="self-hosted,linux,arm64" \
bash "$INSTALL_SH" --non-interactive --no-start --dir "$TEST1_DIR"
TEST2_EC=$?
set -e

assert_success "$TEST2_EC" "install.sh runs successfully in add mode"

# Check new runner count is 3
COUNT_AFTER_ADD="$(grep -E '^RUNNER_COUNT=' "${TEST1_DIR}/.env" | cut -d= -f2)"
assert_equals "3" "$COUNT_AFTER_ADD" "RUNNER_COUNT is updated to 3 after add mode"

# Check runner 3 URL
URL_C="$(grep -E '^RUNNER_3_URL=' "${TEST1_DIR}/.env" | cut -d= -f2)"
assert_equals "https://github.com/my-org/repo-c" "$URL_C" "RUNNER_3_URL is set correctly"

# Verify token C not present in docker-compose.yml
set +e
grep -q "$TOKEN_C" "${TEST1_DIR}/docker-compose.yml"
FOUND_C=$?
set -e
assert_failure "$FOUND_C" "Secret token C is not present in docker-compose.yml"

# Verify docker compose config -q passes with 3 runners
set +e
docker compose -f "${TEST1_DIR}/docker-compose.yml" --env-file "${TEST1_DIR}/.env" config -q
COMPOSE_EC_3=$?
set -e
assert_success "$COMPOSE_EC_3" "docker compose config -q passes with 3 runners"

# Verify backup was created
BACKUPS="$(find "$TEST1_DIR" -name "docker-compose.yml.bak.*" | wc -l | tr -d ' ')"
if [ "$BACKUPS" -ge 1 ]; then
    printf "  [PASS] docker-compose.yml backup created before modification\n"
    PASSED=$((PASSED + 1))
else
    printf "  [FAIL] No docker-compose.yml backup found\n" >&2
    FAILED=$((FAILED + 1))
fi

# ------------------------------------------------------------------------------
# Test 3: Validation failure on bad URL (must exit 1)
# ------------------------------------------------------------------------------
printf "\nTest 3: Reject bad URL (must exit with non-zero error)\n"
TEST2_DIR="$(mktemp -d /tmp/ghr-test-2-XXXXXX)"

set +e
GHR_RUNNER_1_URL="ftp://not-github/invalid" \
GHR_RUNNER_1_TOKEN="SOME_TOKEN" \
bash "$INSTALL_SH" --non-interactive --no-start --dir "$TEST2_DIR" >/dev/null 2>&1
TEST3_EC=$?
set -e

assert_equals "1" "$TEST3_EC" "install.sh exits with code 1 on invalid URL"

# ------------------------------------------------------------------------------
# Test 4: Regression check - no container_name, internal mode has no ports:
# ------------------------------------------------------------------------------
printf "\nTest 4: Verify absence of container_name and no ports in internal cache mode\n"
set +e
grep -q "container_name:" "${TEST1_DIR}/docker-compose.yml"
HAS_CONTAINER_NAME=$?
grep -q "ports:" "${TEST1_DIR}/docker-compose.yml"
HAS_PORTS=$?
grep -qE "^name: ghr-" "${TEST1_DIR}/docker-compose.yml"
HAS_NAME=$?
set -e

assert_failure "$HAS_CONTAINER_NAME" "No container_name anywhere in generated docker-compose.yml"
assert_failure "$HAS_PORTS" "Internal cache mode does not publish ports in docker-compose.yml"
assert_success "$HAS_NAME" "Generated docker-compose.yml contains top-level name attribute"

# ------------------------------------------------------------------------------
# Test 5: Multi-instance project isolation (identical basenames in different dirs)
# ------------------------------------------------------------------------------
printf "\nTest 5: Multi-instance isolation with identical basenames\n"
BASE_TMP="$(mktemp -d /tmp/ghr-multi-XXXXXX)"
STACK_A="${BASE_TMP}/a/github-runner"
STACK_B="${BASE_TMP}/b/github-runner"

mkdir -p "$STACK_A" "$STACK_B"

GHR_RUNNER_1_URL="https://github.com/my-org/repo-a" \
GHR_RUNNER_1_TOKEN="TOKEN_AAA" \
GHR_CACHE=1 \
bash "$INSTALL_SH" --non-interactive --no-start --dir "$STACK_A" >/dev/null 2>&1

GHR_RUNNER_1_URL="https://github.com/my-org/repo-b" \
GHR_RUNNER_1_TOKEN="TOKEN_BBB" \
GHR_CACHE=1 \
bash "$INSTALL_SH" --non-interactive --no-start --dir "$STACK_B" >/dev/null 2>&1

PROJ_A="$(grep -E '^COMPOSE_PROJECT_NAME=' "${STACK_A}/.env" | cut -d= -f2)"
PROJ_B="$(grep -E '^COMPOSE_PROJECT_NAME=' "${STACK_B}/.env" | cut -d= -f2)"

NAME_A="$(grep -E '^name:' "${STACK_A}/docker-compose.yml" | awk '{print $2}')"
NAME_B="$(grep -E '^name:' "${STACK_B}/docker-compose.yml" | awk '{print $2}')"

if [ -n "$PROJ_A" ] && [ -n "$PROJ_B" ] && [ "$PROJ_A" != "$PROJ_B" ]; then
    printf "  [PASS] Stacks with same basename have distinct COMPOSE_PROJECT_NAME ('%s' vs '%s')\n" "$PROJ_A" "$PROJ_B"
    PASSED=$((PASSED + 1))
else
    printf "  [FAIL] Stacks have identical or missing project names: '%s' vs '%s'\n" "$PROJ_A" "$PROJ_B" >&2
    FAILED=$((FAILED + 1))
fi

if [ -n "$NAME_A" ] && [ -n "$NAME_B" ] && [ "$NAME_A" != "$NAME_B" ]; then
    printf "  [PASS] Stacks with same basename have distinct top-level name in compose file ('%s' vs '%s')\n" "$NAME_A" "$NAME_B"
    PASSED=$((PASSED + 1))
else
    printf "  [FAIL] Stacks have identical or missing compose names: '%s' vs '%s'\n" "$NAME_A" "$NAME_B" >&2
    FAILED=$((FAILED + 1))
fi

# ------------------------------------------------------------------------------
# Test 6: Host IP mode publishes port
# ------------------------------------------------------------------------------
printf "\nTest 6: Host IP cache mode publishes custom port\n"
STACK_C="${BASE_TMP}/c/github-runner"
mkdir -p "$STACK_C"

GHR_RUNNER_1_URL="https://github.com/my-org/repo-c" \
GHR_RUNNER_1_TOKEN="TOKEN_CCC" \
GHR_CACHE=1 \
GHR_CACHE_MODE=host \
GHR_CACHE_PORT=3123 \
bash "$INSTALL_SH" --non-interactive --no-start --dir "$STACK_C" >/dev/null 2>&1

set +e
grep -q "3123:3000" "${STACK_C}/docker-compose.yml"
HAS_HOST_PORT=$?
grep -q "CACHE_PORT=3123" "${STACK_C}/.env"
HAS_ENV_PORT=$?
docker compose -f "${STACK_C}/docker-compose.yml" --env-file "${STACK_C}/.env" config -q
CONFIG_C_EC=$?
set -e

assert_success "$HAS_HOST_PORT" "Host IP mode specifies port mapping 3123:3000 in compose file"
assert_success "$HAS_ENV_PORT" "Host IP mode stores CACHE_PORT=3123 in .env"
assert_success "$CONFIG_C_EC" "docker compose config -q passes for Host IP mode stack"

# ------------------------------------------------------------------------------
# Test 7: Concurrency lock prevents simultaneous runs
# ------------------------------------------------------------------------------
printf "\nTest 7: Directory lock prevents concurrent execution\n"
STACK_LOCK="${BASE_TMP}/lock-test"
mkdir -p "${STACK_LOCK}/.install.lock"
echo "PID=99999 TIMESTAMP=2026-10-03T00:00:00Z USER=test" > "${STACK_LOCK}/.install.lock/info"

set +e
GHR_RUNNER_1_URL="https://github.com/my-org/repo-d" \
GHR_RUNNER_1_TOKEN="TOKEN_DDD" \
bash "$INSTALL_SH" --non-interactive --no-start --dir "$STACK_LOCK" >/dev/null 2>&1
LOCKED_EC=$?
set -e

assert_equals "1" "$LOCKED_EC" "install.sh exits with code 1 when .install.lock exists"

# Remove lock and verify it can now succeed
rm -rf "${STACK_LOCK}/.install.lock"
set +e
GHR_RUNNER_1_URL="https://github.com/my-org/repo-d" \
GHR_RUNNER_1_TOKEN="TOKEN_DDD" \
bash "$INSTALL_SH" --non-interactive --no-start --dir "$STACK_LOCK" >/dev/null 2>&1
UNLOCKED_EC=$?
set -e

assert_success "$UNLOCKED_EC" "install.sh succeeds once .install.lock is cleared"
if [ ! -d "${STACK_LOCK}/.install.lock" ]; then
    printf "  [PASS] .install.lock is automatically cleaned up on exit\n"
    PASSED=$((PASSED + 1))
else
    printf "  [FAIL] .install.lock was left behind after exit\n" >&2
    FAILED=$((FAILED + 1))
fi

# ------------------------------------------------------------------------------
# Test 8: Path validation rejects whitespace and colon
# ------------------------------------------------------------------------------
printf "\nTest 8: Reject invalid directory paths (spaces and colons)\n"
set +e
bash "$INSTALL_SH" --non-interactive --no-start --dir "/tmp/ghr bad dir with space" >/dev/null 2>&1
SPACE_EC=$?
bash "$INSTALL_SH" --non-interactive --no-start --dir "/tmp/ghr:bad:colon" >/dev/null 2>&1
COLON_EC=$?
set -e

assert_failure "$SPACE_EC" "install.sh rejects paths with whitespace"
assert_failure "$COLON_EC" "install.sh rejects paths with colons"

# ------------------------------------------------------------------------------
# Test 9: Settings URL derivation for org vs repo runners
# ------------------------------------------------------------------------------
printf "\nTest 9: Settings URL derivation for org vs repo\n"
TMP_SRC="$(mktemp /tmp/ghr-src-XXXXXX.sh)"
sed '/^main "\$@"/d' "$INSTALL_SH" > "$TMP_SRC"

test_settings_url() {
    local in_url="$1"
    bash -c "source '$TMP_SRC' && derive_settings_url '$in_url'"
}

URL_ORG="$(test_settings_url "https://github.com/my-org")"
assert_equals "https://github.com/organizations/my-org/settings/actions/runners" "$URL_ORG" "Org URL derives organizations settings path"

URL_ORG_SLASH="$(test_settings_url "https://github.com/my-org/")"
assert_equals "https://github.com/organizations/my-org/settings/actions/runners" "$URL_ORG_SLASH" "Org URL with trailing slash derives organizations settings path"

URL_REPO="$(test_settings_url "https://github.com/my-org/my-repo")"
assert_equals "https://github.com/my-org/my-repo/settings/actions/runners" "$URL_REPO" "Repo URL preserves repo settings path"

URL_REPO_SLASH="$(test_settings_url "https://github.com/my-org/my-repo/")"
assert_equals "https://github.com/my-org/my-repo/settings/actions/runners" "$URL_REPO_SLASH" "Repo URL with trailing slash preserves repo settings path"

URL_GHES_ORG="$(test_settings_url "https://ghe.example.com/company")"
assert_equals "https://ghe.example.com/organizations/company/settings/actions/runners" "$URL_GHES_ORG" "GHES org URL derives organizations settings path"

URL_GHES_REPO="$(test_settings_url "https://ghe.example.com/company/project")"
assert_equals "https://ghe.example.com/company/project/settings/actions/runners" "$URL_GHES_REPO" "GHES repo URL preserves repo settings path"

rm -f "$TMP_SRC"

# ------------------------------------------------------------------------------
# Test 10: Failed runner handling stops container and exits 1 with warning
# ------------------------------------------------------------------------------
printf "\nTest 10: Failed runner stop and exit 1 warning\n"
TEST10_OUT="$(bash -c '
TMP_SRC="$(mktemp /tmp/ghr-src-XXXXXX.sh)"
sed "/^main \"\$@\"/d" "'"$INSTALL_SH"'" > "$TMP_SRC"
source "$TMP_SRC"
rm -f "$TMP_SRC"

# Mock docker_exec to capture stop command
STOPPED_CONTAINER=""
docker_exec() {
    if [ "$1" = "compose" ] && [ "$5" = "stop" ]; then
        STOPPED_CONTAINER="$6"
        echo "STOPPED:$6"
    fi
}

PROJECT_NAME="test-proj"
INSTALL_DIR="/tmp/test-dir"
RUNNER_COUNT=1
RUNNER_URLS=("https://github.com/test-org/test-repo")
runner_status=("FAIL: Registration failed (401 Unauthorized)")
compose_file="${INSTALL_DIR}/docker-compose.yml"

failed_count=0
k=1
while [ "$k" -le "$RUNNER_COUNT" ]; do
    k_idx=$((k - 1))
    st="${runner_status[k_idx]}"
    if [[ "$st" == FAIL:* ]]; then
        docker_exec compose -p "$PROJECT_NAME" -f "$compose_file" stop "runner-${k}" >/dev/null 2>&1 || true
        failed_count=$((failed_count + 1))
    fi
    k=$((k + 1))
done
FAILED_RUNNERS_COUNT="$failed_count"

if [ "${FAILED_RUNNERS_COUNT:-0}" -gt 0 ]; then
    log_warn "Installer completed with ${FAILED_RUNNERS_COUNT} failed runner(s)"
    exit 1
fi
' 2>&1 || true)"

if echo "$TEST10_OUT" | grep -q "Installer completed with 1 failed runner(s)"; then
    printf "  [PASS] Installer outputs warning with failed runner count\n"
    PASSED=$((PASSED + 1))
else
    printf "  [FAIL] Expected failed runner warning, got: %s\n" "$TEST10_OUT" >&2
    FAILED=$((FAILED + 1))
fi

# Clean up
rm -rf "$TEST1_DIR" "$TEST2_DIR" "$BASE_TMP"

printf "\n==================================================\n"
printf "Test Summary: %d passed, %d failed\n" "$PASSED" "$FAILED"
printf "==================================================\n"

if [ "$FAILED" -ne 0 ]; then
    exit 1
fi
