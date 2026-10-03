#!/usr/bin/env bash
set -e

RUNNER_DIR="/runner"
DIST_DIR="/opt/runner-dist"
LOG_LEVEL="${LOG_LEVEL:-info}"

# Logging helper with ISO-8601 UTC timestamp and log level filtering
log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    level_val() {
        case "$1" in
            [Dd][Ee][Bb][Uu][Gg]) echo 1 ;;
            [Ii][Nn][Ff][Oo])   echo 2 ;;
            [Ww][Aa][Rr][Nn]*) echo 3 ;;
            [Ee][Rr][Rr]*)     echo 4 ;;
            *) echo 2 ;;
        esac
    }

    local current_val
    current_val=$(level_val "$LOG_LEVEL")
    local msg_val
    msg_val=$(level_val "$level")

    if [ "$msg_val" -ge "$current_val" ]; then
        local tag
        case "$level" in
            [Dd][Ee][Bb][Uu][Gg]) tag="DEBUG" ;;
            [Ii][Nn][Ff][Oo])   tag="INFO" ;;
            [Ww][Aa][Rr][Nn]*) tag="WARN" ;;
            [Ee][Rr][Rr]*)     tag="ERROR" ;;
            *) tag="INFO" ;;
        esac

        if [ "$msg_val" -ge 3 ]; then
            echo "${ts} [${tag}] ${msg}" >&2
        else
            echo "${ts} [${tag}] ${msg}"
        fi
    fi
}

# Step 1: Volume hydration and automated binary upgrades
CURRENT_IMG_VERSION=""
if [ -f "${DIST_DIR}/.image-runner-version" ]; then
    CURRENT_IMG_VERSION=$(cat "${DIST_DIR}/.image-runner-version")
fi

VOLUME_VERSION=""
if [ -f "${RUNNER_DIR}/.image-runner-version" ]; then
    VOLUME_VERSION=$(cat "${RUNNER_DIR}/.image-runner-version")
fi

if [ ! -f "${RUNNER_DIR}/config.sh" ]; then
    log "info" "Empty runner volume detected. Hydrating initial runtime (version: ${CURRENT_IMG_VERSION:-unknown}) from ${DIST_DIR}..."
    if [ -d "${DIST_DIR}" ]; then
        cp -a "${DIST_DIR}/." "${RUNNER_DIR}/"
    fi
elif [ -n "${CURRENT_IMG_VERSION}" ] && [ "${VOLUME_VERSION}" != "${CURRENT_IMG_VERSION}" ]; then
    log "info" "Runner image update detected: volume version '${VOLUME_VERSION:-none}' -> image version '${CURRENT_IMG_VERSION}'. Syncing runtime binaries..."
    # Clean stale runner binaries and backup directories left by runner self-updates
    rm -rf "${RUNNER_DIR:?}/bin" "${RUNNER_DIR:?}/externals"
    rm -rf "${RUNNER_DIR:?}"/bin.* "${RUNNER_DIR:?}"/externals.* 2>/dev/null || true
    
    # Overwrite runtime binaries and root files while preserving configuration and credentials (.runner, .credentials, _work, etc.)
    cp -a "${DIST_DIR}/bin" "${RUNNER_DIR}/bin"
    cp -a "${DIST_DIR}/externals" "${RUNNER_DIR}/externals"
    for f in "${DIST_DIR}"/*; do
        if [ -f "$f" ]; then
            cp -f "$f" "${RUNNER_DIR}/"
        fi
    done
    cp -f "${DIST_DIR}/.image-runner-version" "${RUNNER_DIR}/.image-runner-version"
    log "info" "Runtime sync to version ${CURRENT_IMG_VERSION} complete."
else
    log "debug" "Volume runtime binaries match image version (${CURRENT_IMG_VERSION}). Skipping sync."
fi

# Step 2: Handle permissions, work directory & Docker socket
RUNNER_WORKDIR="${RUNNER_WORKDIR:-/runner/_work}"
mkdir -p "${RUNNER_WORKDIR}"

IS_ROOT=false
if [ "$(id -u)" -eq 0 ]; then
    IS_ROOT=true
fi

if [ "$IS_ROOT" = true ]; then
    chown -R runner:runner "${RUNNER_DIR}"
    chown -R runner:runner "${RUNNER_WORKDIR}"

    # Docker socket GID detection and group assignment
    DOCKER_SOCK="/var/run/docker.sock"
    if [ -S "$DOCKER_SOCK" ]; then
        DOCKER_GID=$(stat -c '%g' "$DOCKER_SOCK" 2>/dev/null || stat -f '%g' "$DOCKER_SOCK" 2>/dev/null || true)
        if [ -n "$DOCKER_GID" ]; then
            EXISTING_GROUP=$(getent group "$DOCKER_GID" | cut -d: -f1 || true)
            if [ -z "$EXISTING_GROUP" ]; then
                EXISTING_GROUP="docker-host"
                log "info" "Creating group '${EXISTING_GROUP}' with GID ${DOCKER_GID} for host Docker socket."
                groupadd -g "$DOCKER_GID" "$EXISTING_GROUP" 2>/dev/null || true
            fi
            log "info" "Adding runner user to Docker socket group '${EXISTING_GROUP}' (GID ${DOCKER_GID})."
            usermod -aG "$EXISTING_GROUP" runner 2>/dev/null || true
        fi
    fi
fi

# Step 3: Cache server environment validation & normalization
if [ -n "${ACTIONS_RESULTS_URL:-}" ]; then
    case "${ACTIONS_RESULTS_URL}" in
        http://*|https://*) ;;
        *)
            log "error" "Invalid ACTIONS_RESULTS_URL: '${ACTIONS_RESULTS_URL}'. URL must begin with http:// or https://"
            exit 1
            ;;
    esac

    case "$ACTIONS_RESULTS_URL" in
        */) ;;
        *) ACTIONS_RESULTS_URL="${ACTIONS_RESULTS_URL}/" ;;
    esac
    export ACTIONS_RESULTS_URL
    log "info" "Normalized ACTIONS_RESULTS_URL=${ACTIONS_RESULTS_URL}"
fi

# Step 4: Runner Name resolution (precedence: RUNNER_NAME > RUNNER_NAME_PREFIX + HOSTNAME > HOSTNAME)
RUNNER_NAME_VALUE="${RUNNER_NAME:-}"
if [ -n "$RUNNER_NAME_VALUE" ]; then
    log "info" "Using explicitly configured RUNNER_NAME: ${RUNNER_NAME_VALUE}"
elif [ -n "${RUNNER_NAME_PREFIX:-}" ]; then
    RUNNER_NAME_VALUE="${RUNNER_NAME_PREFIX}$(hostname)"
    log "info" "Resolved runner name from prefix: ${RUNNER_NAME_VALUE}"
else
    RUNNER_NAME_VALUE="$(hostname)"
    log "info" "Using container hostname as runner name: ${RUNNER_NAME_VALUE}"
fi

cd "${RUNNER_DIR}"

RUNNER_USER="runner"
RUNNER_HOME="$(getent passwd "${RUNNER_USER}" | cut -d: -f6)"
RUNNER_HOME="${RUNNER_HOME:-/home/${RUNNER_USER}}"

# `sudo -E` keeps the caller environment, including HOME=/root. Reset the
# identity variables, otherwise git and actions/checkout fail with
# "EACCES: permission denied, stat '/root/.gitconfig'".
run_as_runner() {
    if [ "$IS_ROOT" = true ]; then
        sudo -E -H -u "${RUNNER_USER}" \
            env HOME="${RUNNER_HOME}" USER="${RUNNER_USER}" LOGNAME="${RUNNER_USER}" \
            "$@"
    else
        "$@"
    fi
}
log "debug" "Runner process identity: user=${RUNNER_USER} home=${RUNNER_HOME}"

# Step 5: Runner registration if .runner does not exist
if [ ! -f "${RUNNER_DIR}/.runner" ]; then
    log "info" "No existing runner configuration detected (.runner missing). Performing initial registration..."
    if [ -z "${RUNNER_URL:-}" ] || [ -z "${RUNNER_TOKEN:-}" ]; then
        log "error" "Both RUNNER_URL and RUNNER_TOKEN must be specified for initial registration."
        exit 1
    fi

    CONFIG_ARGS=(
        "--unattended"
        "--url" "$RUNNER_URL"
        "--token" "$RUNNER_TOKEN"
        "--name" "$RUNNER_NAME_VALUE"
        "--work" "$RUNNER_WORKDIR"
        "--replace"
    )
    log "info" "Configured runner work directory: ${RUNNER_WORKDIR}"

    if [ -n "${RUNNER_LABELS:-}" ]; then
        CONFIG_ARGS+=("--labels" "$RUNNER_LABELS")
    fi

    if [ -n "${RUNNER_GROUP:-}" ]; then
        CONFIG_ARGS+=("--runnergroup" "$RUNNER_GROUP")
    fi

    if [ -n "${ACTIONS_RESULTS_URL:-}" ] || [ "${DISABLE_AUTO_UPDATE:-}" = "true" ]; then
        log "info" "Applying --disableupdate flag to preserve patched binaries."
        CONFIG_ARGS+=("--disableupdate")
    fi

    log "info" "Executing runner registration with URL: ${RUNNER_URL} and Name: ${RUNNER_NAME_VALUE}"
    run_as_runner ./config.sh "${CONFIG_ARGS[@]}"
else
    log "info" "Existing runner configuration detected (.runner present). Skipping registration."
fi

# Step 6: Job hooks. Restore workspace ownership after Docker steps that ran as root.
OWNERSHIP_HOOK="/opt/runner-hooks/fix-workspace-ownership.sh"
if [ "${FIX_WORKSPACE_OWNERSHIP:-true}" = "true" ] && [ -x "$OWNERSHIP_HOOK" ]; then
    export ACTIONS_RUNNER_HOOK_JOB_STARTED="${ACTIONS_RUNNER_HOOK_JOB_STARTED:-$OWNERSHIP_HOOK}"
    export ACTIONS_RUNNER_HOOK_JOB_COMPLETED="${ACTIONS_RUNNER_HOOK_JOB_COMPLETED:-$OWNERSHIP_HOOK}"
    log "info" "Job hooks enabled: started=${ACTIONS_RUNNER_HOOK_JOB_STARTED} completed=${ACTIONS_RUNNER_HOOK_JOB_COMPLETED}"
else
    log "info" "Workspace ownership hook disabled (FIX_WORKSPACE_OWNERSHIP=${FIX_WORKSPACE_OWNERSHIP:-true})."
fi

# Step 7: Graceful signal handling and execution
_term() {
    log "info" "Caught termination signal! Forwarding SIGTERM to runner process..."
    if [ -n "${RUNNER_PID:-}" ]; then
        kill -TERM "$RUNNER_PID" 2>/dev/null || true
        wait "$RUNNER_PID" 2>/dev/null || true
    fi
    log "info" "Runner shutdown complete."
    exit 0
}

trap _term SIGTERM SIGINT

log "info" "Starting GitHub Actions runner process..."
run_as_runner ./run.sh &
RUNNER_PID=$!

wait "$RUNNER_PID"
