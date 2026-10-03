#!/usr/bin/env bash
# GitHub-hosted runner compatibility layer.
#
# Marketplace actions are written for the GitHub-hosted runner images. They
# rely on conventions that a bare self-hosted container does not have. This
# library makes the container obey those conventions (the "contract"):
#
#   1. Tool cache: RUNNER_TOOL_CACHE (/opt/hostedtoolcache) exists and the
#      runner user can write to it. setup-ruby and setup-python install
#      prebuilt binaries that embed this path.
#   2. Writable paths: RUNNER_WRITABLE_PATHS adds more runner-owned
#      directories.
#   3. Packages: RUNNER_EXTRA_APT_PACKAGES adds apt packages at startup.
#   4. Init scripts: scripts in RUNNER_INIT_DIR run before the runner starts.
#
# Items 2 to 4 are extension points. Use them when a workflow needs something
# that the image does not supply; an image rebuild is not necessary.
# bin/runner-doctor examines the contract as the runner user.
#
# The caller must define log() and set IS_ROOT, RUNNER_USER and RUNNER_DIR.
# All functions are fail-soft: they log a problem and return 0, so that a
# compatibility problem cannot stop the runner.

COMPAT_DEFAULT_TOOL_CACHE="/opt/hostedtoolcache"
COMPAT_DEFAULT_INIT_DIR="/opt/runner-init.d"

# Directories that RUNNER_WRITABLE_PATHS must not give to the runner user.
# A recursive chown of these paths breaks the operating system.
COMPAT_PROTECTED_PATHS="/ /bin /boot /dev /etc /home /lib /lib32 /lib64 /opt /proc /root /run /sbin /sys /tmp /usr /var"

compat_dir_is_empty() {
    [ -z "$(ls -A "$1" 2>/dev/null)" ]
}

# Give a directory tree to the runner user. The recursive chown is skipped
# when all entries are already owned by the runner user.
compat_give_to_runner() {
    local target
    # Resolve symbolic links: find and chown do not follow a link operand.
    target="$(realpath -e -- "$1" 2>/dev/null)" || {
        log "warn" "Cannot give '$1' to ${RUNNER_USER}: path does not exist."
        return 0
    }
    if [ -z "$(find "$target" ! -user "$RUNNER_USER" -print -quit 2>/dev/null)" ]; then
        log "debug" "Ownership is already correct: ${target}"
        return 0
    fi
    if chown -R "${RUNNER_USER}:" "$target"; then
        log "info" "Gave ${target} to user ${RUNNER_USER}."
    else
        log "warn" "Could not give ${target} to user ${RUNNER_USER}."
    fi
    return 0
}

# Contract item 1: the tool cache.
#
# Storage is selected in this sequence:
#   - an operator volume mounted at the tool cache path is used as-is;
#   - a path below RUNNER_DIR is already persistent and is used as-is;
#   - an empty tool cache becomes a symbolic link to RUNNER_DIR/_tool-cache,
#     so that installed tools stay available when the container is recreated;
#   - a tool cache with content (tools baked into a derived image) stays in
#     the container filesystem.
compat_prepare_tool_cache() {
    local tool_cache="${RUNNER_TOOL_CACHE:-$COMPAT_DEFAULT_TOOL_CACHE}"
    local persist="${RUNNER_TOOL_CACHE_PERSIST:-true}"
    local persist_dir="${RUNNER_DIR}/_tool-cache"
    local storage

    # The runner reads these variables. Keep them equal.
    export RUNNER_TOOL_CACHE="$tool_cache"
    export AGENT_TOOLSDIRECTORY="$tool_cache"

    if [ "$IS_ROOT" != true ]; then
        mkdir -p "$tool_cache" 2>/dev/null || true
        if [ -d "$tool_cache" ] && [ -w "$tool_cache" ]; then
            log "info" "Tool cache ready: path=${tool_cache} storage=unmanaged (container does not run as root)"
        else
            log "warn" "Tool cache ${tool_cache} is not writable and the container does not run as root. setup-* actions will fail."
        fi
        return 0
    fi

    if [ -L "$tool_cache" ]; then
        # The link was made on an earlier start of this container.
        mkdir -p "$(readlink -f -- "$tool_cache")" 2>/dev/null || true
        storage="link to $(readlink -f -- "$tool_cache")"
    elif mountpoint -q "$tool_cache" 2>/dev/null; then
        storage="operator volume"
    elif [ "${tool_cache#"${RUNNER_DIR}"/}" != "$tool_cache" ]; then
        mkdir -p "$tool_cache" 2>/dev/null || true
        storage="runner volume"
    elif [ "$persist" = "true" ] && { [ ! -e "$tool_cache" ] || compat_dir_is_empty "$tool_cache"; }; then
        if mkdir -p "$persist_dir" "$(dirname "$tool_cache")" \
            && { [ ! -d "$tool_cache" ] || rmdir "$tool_cache"; } \
            && ln -s "$persist_dir" "$tool_cache" \
            && chown -h "${RUNNER_USER}:" "$tool_cache"; then
            storage="link to ${persist_dir}"
        else
            log "warn" "Could not link ${tool_cache} to ${persist_dir}. The tool cache will not be persistent."
            mkdir -p "$tool_cache" 2>/dev/null || true
            storage="container filesystem (not persistent)"
        fi
    else
        mkdir -p "$tool_cache" 2>/dev/null || true
        storage="container filesystem (not persistent)"
    fi

    compat_give_to_runner "$tool_cache"
    log "info" "Tool cache ready: path=${tool_cache} storage=${storage}"
    return 0
}

# Contract item 2: more runner-owned directories.
# RUNNER_WRITABLE_PATHS is a colon-separated list of absolute paths.
compat_prepare_writable_paths() {
    local raw="${RUNNER_WRITABLE_PATHS:-}"
    if [ -z "$raw" ]; then
        log "debug" "RUNNER_WRITABLE_PATHS is empty. No additional writable paths."
        return 0
    fi
    if [ "$IS_ROOT" != true ]; then
        log "warn" "RUNNER_WRITABLE_PATHS is ignored: the container does not run as root."
        return 0
    fi

    local -a paths
    IFS=':' read -r -a paths <<< "$raw"
    local path resolved protected
    for path in "${paths[@]}"; do
        if [ -z "$path" ]; then
            continue
        fi
        case "$path" in
            /*) ;;
            *)
                log "warn" "RUNNER_WRITABLE_PATHS: '${path}' is not an absolute path. Ignored."
                continue
                ;;
        esac
        resolved="$(realpath -m -- "$path")"
        for protected in $COMPAT_PROTECTED_PATHS; do
            if [ "$resolved" = "$protected" ]; then
                log "warn" "RUNNER_WRITABLE_PATHS: '${path}' is a system directory. Ignored."
                continue 2
            fi
        done
        if mkdir -p "$resolved"; then
            compat_give_to_runner "$resolved"
            log "info" "Writable path ready: ${resolved}"
        else
            log "warn" "RUNNER_WRITABLE_PATHS: could not create '${resolved}'."
        fi
    done
    return 0
}

# Contract item 3: more apt packages.
# RUNNER_EXTRA_APT_PACKAGES is a list of package names, separated by spaces
# or commas. "name=version" is permitted.
compat_install_extra_packages() {
    local raw="${RUNNER_EXTRA_APT_PACKAGES:-}"
    if [ -z "$raw" ]; then
        log "debug" "RUNNER_EXTRA_APT_PACKAGES is empty. No additional packages."
        return 0
    fi
    if [ "$IS_ROOT" != true ]; then
        log "warn" "RUNNER_EXTRA_APT_PACKAGES is ignored: the container does not run as root."
        return 0
    fi

    local -a requested missing=()
    read -r -a requested <<< "${raw//,/ }"
    local pkg
    for pkg in "${requested[@]}"; do
        # A strict pattern prevents apt option injection through the variable.
        if ! [[ "$pkg" =~ ^[a-z0-9][a-z0-9+.-]*(=[A-Za-z0-9.+:~-]+)?$ ]]; then
            log "warn" "RUNNER_EXTRA_APT_PACKAGES: '${pkg}' is not a valid package name. Ignored."
            continue
        fi
        if dpkg-query -W -f='${Status}' "${pkg%%=*}" 2>/dev/null | grep -q "install ok installed"; then
            log "debug" "Package is already installed: ${pkg}"
        else
            missing+=("$pkg")
        fi
    done

    if [ "${#missing[@]}" -eq 0 ]; then
        log "info" "All packages in RUNNER_EXTRA_APT_PACKAGES are installed."
        return 0
    fi

    log "info" "Installing additional apt packages: ${missing[*]}"
    if apt-get update -qq \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}" >/dev/null; then
        log "info" "Additional apt packages installed: ${missing[*]}"
    else
        log "error" "Could not install additional apt packages: ${missing[*]}. Jobs that use them will fail."
    fi
    rm -rf /var/lib/apt/lists/*
    return 0
}

# Contract item 4: operator init scripts.
# Each *.sh file in RUNNER_INIT_DIR runs with bash, in name sequence, as the
# user that started the container.
compat_run_init_scripts() {
    local init_dir="${RUNNER_INIT_DIR:-$COMPAT_DEFAULT_INIT_DIR}"
    if [ ! -d "$init_dir" ]; then
        log "debug" "Init script directory ${init_dir} does not exist. No init scripts."
        return 0
    fi

    local script status
    for script in "$init_dir"/*.sh; do
        if [ ! -f "$script" ]; then
            continue
        fi
        log "info" "Running init script: ${script}"
        status=0
        bash "$script" || status=$?
        if [ "$status" -eq 0 ]; then
            log "info" "Init script completed: ${script}"
        else
            log "warn" "Init script failed (exit code ${status}): ${script}"
        fi
    done
    return 0
}

# Apply the full contract. Call this function before the runner starts.
compat_prepare_hosted_env() {
    compat_prepare_tool_cache
    compat_prepare_writable_paths
    compat_install_extra_packages
    compat_run_init_scripts
    return 0
}
