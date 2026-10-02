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
    if stat -f "%OLp" "$target" 2>/dev/null; then
        return 0
    fi
    stat -c "%a" "$target" 2>/dev/null || echo "unknown"
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

# Clean up
rm -rf "$TEST1_DIR" "$TEST2_DIR"

printf "\n==================================================\n"
printf "Test Summary: %d passed, %d failed\n" "$PASSED" "$FAILED"
printf "==================================================\n"

if [ "$FAILED" -ne 0 ]; then
    exit 1
fi
