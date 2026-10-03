#!/usr/bin/env bash
# ==============================================================================
# Image Contract Test Suite
# ==============================================================================
# Runs the real container entrypoint with a stub runner and examines the
# GitHub-hosted runner compatibility contract (lib/hosted-compat.sh).
#
# The stub replaces run.sh in the runner volume. The entrypoint starts it as
# the runner user, in the same environment that a real runner process gets.
# The stub runs runner-doctor and then the assertion script of the test case.
#
# Usage:
#   tests/image_contract_test.sh [image]
#
# Without an image argument, the script builds the image from the repository.
# The apt package case needs network access. Set CONTRACT_TEST_OFFLINE=1 to
# skip it.

# The assertion scripts are single-quoted on purpose: they must expand in the
# container, not in this shell.
# shellcheck disable=SC2016

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMAGE="${1:-}"
RESOURCE_PREFIX="runner-contract-test-$$"
RUNNER_VOLUME="${RESOURCE_PREFIX}-runner"
TOOL_VOLUME="${RESOURCE_PREFIX}-tools"
INIT_VOLUME="${RESOURCE_PREFIX}-init"
RESTART_CONTAINER="${RESOURCE_PREFIX}-restart"

PASSED=0
FAILED=0
LAST_OUTPUT=""

cleanup() {
    docker rm -f "$RESTART_CONTAINER" >/dev/null 2>&1 || true
    docker volume rm -f "$RUNNER_VOLUME" "$TOOL_VOLUME" "$INIT_VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

record_pass() {
    printf "  [PASS] %s\n" "$1"
    PASSED=$((PASSED + 1))
}

record_fail() {
    printf "  [FAIL] %s\n" "$1" >&2
    if [ -n "${2:-}" ]; then
        printf "%s\n" "$2" | sed 's/^/         | /' >&2
    fi
    FAILED=$((FAILED + 1))
}

# Run a throwaway helper container without the entrypoint (always as root).
helper() {
    docker run --rm --user root --entrypoint bash "$@"
}

# Start a container through the real entrypoint. The stub runner executes
# runner-doctor and then the assertion script as the runner user.
# Usage: run_case <name> <assertion script> [docker run options...]
run_case() {
    local name="$1"
    local assertion="$2"
    shift 2
    local status=0
    LAST_OUTPUT="$(docker run --rm \
        -v "${RUNNER_VOLUME}:/runner" \
        -e RUNNER_WORKDIR=/runner/_work \
        -e CONTRACT_ASSERT="$assertion" \
        "$@" "$IMAGE" 2>&1)" || status=$?
    if [ "$status" -eq 0 ]; then
        record_pass "$name"
    else
        record_fail "${name} (exit code ${status})" "$LAST_OUTPUT"
    fi
}

assert_log_contains() {
    local pattern="$1"
    local name="$2"
    if printf "%s\n" "$LAST_OUTPUT" | grep -q -- "$pattern"; then
        record_pass "$name"
    else
        record_fail "${name}: log does not contain '${pattern}'" "$LAST_OUTPUT"
    fi
}

# ------------------------------------------------------------------------------
# Setup
# ------------------------------------------------------------------------------
if [ -z "$IMAGE" ]; then
    IMAGE="self-hosted-runner:contract-test"
    echo "==> Building ${IMAGE} from ${PROJECT_ROOT}"
    docker build -t "$IMAGE" "$PROJECT_ROOT"
fi
echo "==> Testing image: ${IMAGE}"

docker volume create "$RUNNER_VOLUME" >/dev/null
docker volume create "$TOOL_VOLUME" >/dev/null
docker volume create "$INIT_VOLUME" >/dev/null

# Seed a registered runner volume: the entrypoint skips hydration and
# registration, and starts the stub as the runner process.
helper -v "${RUNNER_VOLUME}:/runner" "$IMAGE" -c '
    set -e
    cp /opt/runner-dist/.image-runner-version /runner/.image-runner-version
    printf "{}\n" > /runner/.runner
    printf "#!/usr/bin/env bash\nexit 0\n" > /runner/config.sh
    cat > /runner/run.sh <<"STUB"
#!/usr/bin/env bash
# Stub for the runner listener (see tests/image_contract_test.sh).
set -euo pipefail
runner-doctor --quiet
if [ -n "${CONTRACT_ASSERT:-}" ]; then
    bash -euo pipefail -c "$CONTRACT_ASSERT"
fi
STUB
    chmod +x /runner/config.sh /runner/run.sh
'

# A tool cache volume that an operator mounts, with content owned by root.
helper -v "${TOOL_VOLUME}:/opt/hostedtoolcache" "$IMAGE" -c '
    set -e
    mkdir -p /opt/hostedtoolcache/Node/1.0.0
    chown -R root:root /opt/hostedtoolcache
'

# Operator init scripts: one that succeeds and one that fails.
helper -v "${INIT_VOLUME}:/opt/runner-init.d" "$IMAGE" -c '
    set -e
    printf "touch /opt/init-marker\nchmod 644 /opt/init-marker\n" > /opt/runner-init.d/10-marker.sh
    printf "exit 3\n" > /opt/runner-init.d/20-fail.sh
'

# ------------------------------------------------------------------------------
# Test cases
# ------------------------------------------------------------------------------
echo "==> Runner identity and environment"
run_case "runner process has the hosted-runner environment" '
    [ "$(id -un)" = "runner" ]
    [ "$HOME" = "/home/runner" ]
    [ "$RUNNER_TOOL_CACHE" = "/opt/hostedtoolcache" ]
    [ "$AGENT_TOOLSDIRECTORY" = "/opt/hostedtoolcache" ]
    [ "$LANG" = "C.UTF-8" ]
'
assert_log_contains "Hosted-runner compatibility check passed" "entrypoint reports a passed contract check"

echo "==> Tool cache"
# setup-ruby makes /opt/hostedtoolcache/Ruby/<version>/<arch> and a marker file.
run_case "tool cache is writable and linked into the runner volume" '
    [ "$(readlink -f /opt/hostedtoolcache)" = "/runner/_tool-cache" ]
    mkdir -p /opt/hostedtoolcache/Ruby/9.9.9/x64
    touch /opt/hostedtoolcache/Ruby/9.9.9/x64.complete
'
run_case "tool cache content stays available in a new container" '
    [ -f /opt/hostedtoolcache/Ruby/9.9.9/x64.complete ]
'

restart_status=0
restart_output="$(docker create --name "$RESTART_CONTAINER" \
    -v "${RUNNER_VOLUME}:/runner" \
    -e RUNNER_WORKDIR=/runner/_work \
    -e CONTRACT_ASSERT='touch /opt/hostedtoolcache/restart-probe' \
    "$IMAGE" 2>&1 \
    && docker start -a "$RESTART_CONTAINER" 2>&1 \
    && docker start -a "$RESTART_CONTAINER" 2>&1)" || restart_status=$?
if [ "$restart_status" -eq 0 ]; then
    record_pass "tool cache link is used again after a container restart"
else
    record_fail "tool cache link is used again after a container restart (exit code ${restart_status})" "$restart_output"
fi

run_case "operator volume at the tool cache path is given to the runner user" '
    [ ! -L /opt/hostedtoolcache ]
    [ -O /opt/hostedtoolcache/Node/1.0.0 ]
    touch /opt/hostedtoolcache/Node/1.0.0/probe
' -v "${TOOL_VOLUME}:/opt/hostedtoolcache"

run_case "RUNNER_TOOL_CACHE_PERSIST=false keeps the tool cache in the container" '
    [ ! -L /opt/hostedtoolcache ]
    touch /opt/hostedtoolcache/probe
' -e RUNNER_TOOL_CACHE_PERSIST=false

run_case "custom RUNNER_TOOL_CACHE is prepared and exported" '
    [ "$RUNNER_TOOL_CACHE" = "/opt/custom-tools" ]
    [ "$AGENT_TOOLSDIRECTORY" = "/opt/custom-tools" ]
    touch /opt/custom-tools/probe
    touch /opt/hostedtoolcache/probe
' -e RUNNER_TOOL_CACHE=/opt/custom-tools

run_case "job hook gives root-owned tool cache files back to the runner user" '
    sudo mkdir -p "$RUNNER_TOOL_CACHE/Go/1.0.0"
    sudo touch "$RUNNER_TOOL_CACHE/Go/1.0.0/root-owned"
    [ ! -O "$RUNNER_TOOL_CACHE/Go/1.0.0/root-owned" ]
    RUNNER_WORKSPACE="" RUNNER_TEMP="" /opt/runner-hooks/fix-workspace-ownership.sh
    [ -O "$RUNNER_TOOL_CACHE/Go/1.0.0/root-owned" ]
'

echo "==> Baseline toolchain"
run_case "native extensions can be compiled" '
    cd "$(mktemp -d)"
    printf "#include <openssl/ssl.h>\n#include <yaml.h>\n#include <ffi.h>\n#include <zlib.h>\nint main(void) { return 0; }\n" > probe.c
    gcc -o probe probe.c $(pkg-config --cflags --libs openssl yaml-0.1 libffi zlib)
    ./probe
    python3 -c "import ssl, sqlite3"
    git lfs version >/dev/null
'

echo "==> Extension points"
run_case "RUNNER_WRITABLE_PATHS makes runner-owned directories" '
    touch /opt/custom-a/probe
    touch /opt/custom-b/nested/probe
    [ ! -O /usr ]
' -e RUNNER_WRITABLE_PATHS=/opt/custom-a:/opt/custom-b/nested:relative/path:/usr
assert_log_contains "'/usr' is a system directory" "RUNNER_WRITABLE_PATHS refuses a system directory"
assert_log_contains "'relative/path' is not an absolute path" "RUNNER_WRITABLE_PATHS refuses a relative path"

if [ "${CONTRACT_TEST_OFFLINE:-0}" = "1" ]; then
    echo "  [SKIP] RUNNER_EXTRA_APT_PACKAGES (CONTRACT_TEST_OFFLINE=1)"
else
    run_case "RUNNER_EXTRA_APT_PACKAGES installs packages at startup" '
        command -v tree >/dev/null
    ' -e "RUNNER_EXTRA_APT_PACKAGES=tree, --allow-unauthenticated"
    assert_log_contains "'--allow-unauthenticated' is not a valid package name" "RUNNER_EXTRA_APT_PACKAGES refuses an apt option"
fi

run_case "init scripts run before the runner starts" '
    [ -f /opt/init-marker ]
' -v "${INIT_VOLUME}:/opt/runner-init.d:ro"
assert_log_contains "Init script failed (exit code 3)" "failed init script is reported and does not stop the runner"

echo "==> Start modes and diagnostics"
run_case "container started as the runner user satisfies the contract" '
    [ "$(id -un)" = "runner" ]
    touch /opt/hostedtoolcache/probe
' --user runner

# Negative case: runner-doctor must detect a broken contract (HOME of root).
doctor_status=0
doctor_output="$(docker run --rm --user runner --entrypoint runner-doctor -e HOME=/root "$IMAGE" 2>&1)" || doctor_status=$?
if [ "$doctor_status" -eq 1 ] && printf "%s\n" "$doctor_output" | grep -q "FAIL home"; then
    record_pass "runner-doctor detects a broken contract"
else
    record_fail "runner-doctor detects a broken contract (exit code ${doctor_status})" "$doctor_output"
fi

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo "Image contract tests: ${PASSED} passed, ${FAILED} failed"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
