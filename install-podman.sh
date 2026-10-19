#!/usr/bin/env bash
# ==============================================================================
# GitHub Actions Runner & Cache Server - Podman + systemd (Quadlet) Installer
#
# Deploys the runner image on a Podman host and lets systemd own the lifecycle:
# Quadlet unit files are generated into /etc/containers/systemd/, so the stack
# starts on boot and is managed with systemctl / journalctl.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install-podman.sh | sudo bash
#   sudo bash install-podman.sh --non-interactive --dir /opt/github-runner
#
# Invariants held by this script:
#   * ${INSTALL_DIR}/.env is the only authoritative configuration record.
#   * Unit files live in the Quadlet search path, never in a second copy.
#   * Registration tokens are written to 0600 env files, never into unit files.
#   * Container names equal systemd unit base names, so one name addresses both.
#   * Job workspaces keep the same absolute path inside and outside containers.
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Global Defaults and State
# ------------------------------------------------------------------------------
INSTALLER_VERSION="1.0.0"
REPO_SLUG="bestony/self-hosted-action-runner"
REPO_URL="https://github.com/${REPO_SLUG}"
DEFAULT_IMAGE="ghcr.io/bestony/self-hosted-action-runner:latest"
DEFAULT_CACHE_IMAGE="ghcr.io/falcondev-oss/github-actions-cache-server:latest"

# Quadlet ships with podman-system-generator since Podman 4.4.
MIN_PODMAN_VERSION="4.4"
DEFAULT_QUADLET_DIR="/etc/containers/systemd"
DEFAULT_PODMAN_SOCKET="/run/podman/podman.sock"
CONTAINER_PODMAN_SOCKET="/run/podman/podman.sock"
CONTAINER_DOCKER_SOCKET="/var/run/docker.sock"
CACHE_ALIAS="cache-server"
CACHE_CONTAINER_PORT="3000"
DEFAULT_LABELS="self-hosted,linux,docker"
REGISTRATION_WAIT_SECONDS="${GHR_REGISTRATION_WAIT:-90}"

# Extra variables forwarded to every runner container when they are set. The
# list is a whitelist: unknown keys in .env are ignored instead of injected.
PASSTHROUGH_KEYS=(
    LOG_LEVEL
    FIX_WORKSPACE_OWNERSHIP
    RUNNER_EXTRA_APT_PACKAGES
    RUNNER_WRITABLE_PATHS
    RUNNER_TOOL_CACHE
    RUNNER_TOOL_CACHE_PERSIST
    RUNNER_INIT_DIR
    DISABLE_AUTO_UPDATE
    RUNNER_GROUP
    DOCKER_API_VERSION
    HTTP_PROXY
    HTTPS_PROXY
    NO_PROXY
)
PASSTHROUGH_DEFAULTS=(
    "info"
    "true"
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
    ""
)
PROXY_KEYS=(HTTP_PROXY HTTPS_PROXY NO_PROXY)

INSTALL_DIR=""
NON_INTERACTIVE=false
NO_START=false
SKIP_PODMAN_INSTALL=false
DEBUG_MODE=false
ACTION="install"

PROJECT_NAME=""
CURRENT_LOCK_DIR=""
LOG_FILE=""
SUDO=()
SKIP_PLATFORM_CHECKS=false

QUADLET_DIR="${GHR_QUADLET_DIR:-$DEFAULT_QUADLET_DIR}"
PODMAN_SOCKET="${GHR_PODMAN_SOCKET:-$DEFAULT_PODMAN_SOCKET}"
# The mounted socket cannot be relabeled by Podman, so keeping SELinux labels
# breaks workflows only when the host is enforcing; opt back in with GHR_SELINUX=1.
SELINUX_DISABLE=true
if [ "${GHR_SELINUX:-0}" = "1" ]; then
    SELINUX_DISABLE=false
fi
AUTO_UPDATE=false
if [ "${GHR_AUTO_UPDATE:-0}" = "1" ]; then
    AUTO_UPDATE=true
fi

RUNNER_COUNT=0
FAILED_RUNNERS_COUNT=0
declare -a RUNNER_STATUS_ARRAY=()
declare -a RUNNER_URLS=()
declare -a RUNNER_TOKENS=()
declare -a RUNNER_LABELS=()
declare -a RUNNER_PREFIXES=()
declare -a RUNNER_WORKDIR_LIST=()

CACHE_ENABLED=true
CACHE_MODE="internal"
CACHE_URL=""
CACHE_PORT=""
CACHE_CLEANUP_DAYS="${GHR_CACHE_CLEANUP_DAYS:-90}"
CACHE_MAX_USAGE_PERCENT="${GHR_CACHE_MAX_USAGE_PERCENT:-90}"
RUNNER_IMAGE="${DEFAULT_IMAGE}"
CACHE_IMAGE="${DEFAULT_CACHE_IMAGE}"
RAW_INSTALL_URL="https://raw.githubusercontent.com/${REPO_SLUG}/main/install-podman.sh"

# Colors (only if stdout is a TTY)
if [ -t 1 ]; then
    COLOR_RED="\033[0;31m"
    COLOR_GREEN="\033[0;32m"
    COLOR_YELLOW="\033[0;33m"
    COLOR_BLUE="\033[0;34m"
    COLOR_BOLD="\033[1m"
    COLOR_RESET="\033[0m"
else
    COLOR_RED=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_BLUE=""
    COLOR_BOLD=""
    COLOR_RESET=""
fi

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
log_info() {
    printf "${COLOR_BLUE}[INFO]${COLOR_RESET} %s\n" "$*"
}

log_warn() {
    printf "${COLOR_YELLOW}[WARN]${COLOR_RESET} %s\n" "$*" >&2
}

log_error() {
    printf "${COLOR_RED}[ERROR]${COLOR_RESET} %s\n" "$*" >&2
}

log_debug() {
    if [ "${DEBUG_MODE}" = true ] || [ "${GHR_DEBUG:-0}" = "1" ]; then
        printf "${COLOR_BOLD}[DEBUG]${COLOR_RESET} %s\n" "$*" >&2
    fi
}

mask_token() {
    local token="$1"
    local len="${#token}"
    if [ "$len" -le 6 ]; then
        echo "******"
    else
        echo "******${token: -4}"
    fi
}

have() {
    command -v "$1" >/dev/null 2>&1
}

# Operator hints must work for both invocation styles. Piped installations
# (`curl ... | sudo bash`) have no script file to re-run: $0 is "bash" and
# BASH_SOURCE is empty, so those hints point at the download form instead of
# printing a command that cannot be executed.
installer_command() {
    local script_path="${BASH_SOURCE[0]:-}"
    if [ -n "$script_path" ] && [ -f "$script_path" ]; then
        # Resolve to an absolute path: the hint is read from other directories.
        printf 'sudo bash %s' "$(cd "$(dirname "$script_path")" && pwd)/$(basename "$script_path")"
        return 0
    fi
    printf 'curl -fsSL %s | sudo bash -s --' "$RAW_INSTALL_URL"
}

# Privileged commands go through as_root: as_root podman/systemctl/install/rm.
as_root() {
    if [ "${#SUDO[@]}" -gt 0 ]; then
        "${SUDO[@]}" "$@"
    else
        "$@"
    fi
}

run_podman() {
    as_root podman "$@"
}

run_systemctl() {
    as_root systemctl "$@"
}

run_journalctl() {
    as_root journalctl "$@"
}

# install_privileged <src> <dest> <mode>: place a root-owned file at a system path.
install_privileged() {
    local src="$1" dest="$2" mode="${3:-0644}"
    as_root install -m "$mode" "$src" "$dest"
}

version_ge() {
    # version_ge <candidate> <minimum> -> true when candidate >= minimum
    local candidate="$1" minimum="$2"
    [ "$(printf '%s\n%s\n' "$minimum" "$candidate" | sort -V | head -n 1)" = "$minimum" ]
}

# ------------------------------------------------------------------------------
# Banner & Progress Display
# ------------------------------------------------------------------------------
print_banner() {
    if [ -t 1 ]; then
        printf "%b%b" "${COLOR_BLUE}" "${COLOR_BOLD}"
    fi
    cat <<'EOF'
  ____  _____ _     _____       _   _  ___  ____ _____ _____ ____
 / ___|| ____| |   |  ___|     | | | |/ _ \/ ___|_   _| ____|  _ \
 \___ \|  _| | |   | |_  _____ | |_| | | | \___ \ | | |  _| | | | |
  ___) | |___| |___|  _| |_____||  _  | |_| |___) || | | |___| |_| |
 |____/|_____|_____|_|          |_| |_|\___/|____/ |_| |_____|____/
 ____  _   _ _   _ _   _ _____ ____
|  _ \| | | | \ | | \ | | ____|  _ \
| |_) | | | |  \| |  \| |  _| | |_) |
|  _ <| |_| | |\  | |\  | |___|  _ <
|_| \_\\___/|_| \_|_| \_|_____|_| \_\
EOF
    if [ -t 1 ]; then
        printf "%b\n" "${COLOR_RESET}"
        printf "%b+----------------------------------------------------------------------------+%b\n" "${COLOR_BLUE}" "${COLOR_RESET}"
        printf "%b|%b %bProject%b : GitHub Actions Self-Hosted Runner Stack (Podman + systemd)     %b|%b\n" "${COLOR_BLUE}" "${COLOR_RESET}" "${COLOR_BOLD}" "${COLOR_RESET}" "${COLOR_BLUE}" "${COLOR_RESET}"
        printf "%b|%b %bRepo%b    : %-64s %b|%b\n" "${COLOR_BLUE}" "${COLOR_RESET}" "${COLOR_BOLD}" "${COLOR_RESET}" "${REPO_URL}" "${COLOR_BLUE}" "${COLOR_RESET}"
        printf "%b|%b %bVersion%b : v%-63s %b|%b\n" "${COLOR_BLUE}" "${COLOR_RESET}" "${COLOR_BOLD}" "${COLOR_RESET}" "${INSTALLER_VERSION}" "${COLOR_BLUE}" "${COLOR_RESET}"
        printf "%b|%b %bImage%b   : %-63s %b|%b\n" "${COLOR_BLUE}" "${COLOR_RESET}" "${COLOR_BOLD}" "${COLOR_RESET}" "${DEFAULT_IMAGE}" "${COLOR_BLUE}" "${COLOR_RESET}"
        printf "%b+----------------------------------------------------------------------------+%b\n" "${COLOR_BLUE}" "${COLOR_RESET}"
    else
        printf "\n+----------------------------------------------------------------------------+\n"
        printf "| Project : GitHub Actions Self-Hosted Runner Stack (Podman + systemd)        |\n"
        printf "| Repo    : %-65s |\n" "${REPO_URL}"
        printf "| Version : v%-64s |\n" "${INSTALLER_VERSION}"
        printf "| Image   : %-65s |\n" "${DEFAULT_IMAGE}"
        printf "+----------------------------------------------------------------------------+\n\n"
    fi
}

step_header() {
    local step="$1"
    local title="$2"
    if [ -t 1 ]; then
        printf "\n${COLOR_BOLD}${COLOR_BLUE}==>${COLOR_RESET} ${COLOR_BOLD}[%s] %s${COLOR_RESET}\n" "$step" "$title"
    else
        printf "\n==> [%s] %s\n" "$step" "$title"
    fi
}

CURRENT_SPINNER_PID=""

cleanup_spinner() {
    if [ -n "${CURRENT_SPINNER_PID:-}" ] && kill -0 "$CURRENT_SPINNER_PID" 2>/dev/null; then
        kill -9 "$CURRENT_SPINNER_PID" 2>/dev/null || true
        wait "$CURRENT_SPINNER_PID" 2>/dev/null || true
    fi
    if [ -t 1 ]; then
        printf "\033[?25h"
    fi
}

cleanup_all() {
    cleanup_spinner
    if [ -n "${CURRENT_LOCK_DIR:-}" ] && [ -d "$CURRENT_LOCK_DIR" ]; then
        rm -rf "$CURRENT_LOCK_DIR" 2>/dev/null || true
        CURRENT_LOCK_DIR=""
    fi
}

trap 'cleanup_all; exit 130' SIGINT SIGTERM
trap 'cleanup_all' EXIT

init_log_file() {
    if [ -z "$LOG_FILE" ]; then
        if [ -n "$INSTALL_DIR" ] && [ -d "$INSTALL_DIR" ]; then
            LOG_FILE="${INSTALL_DIR}/install.log"
        else
            LOG_FILE="$(mktemp /tmp/ghr-podman-install-XXXXXX.log 2>/dev/null || echo "/tmp/ghr-podman-install.log")"
        fi
        touch "$LOG_FILE"
    fi
}

run_with_spinner() {
    local label="$1"
    shift
    init_log_file

    local start_time=$SECONDS

    "$@" >> "$LOG_FILE" 2>&1 &
    local cmd_pid=$!
    CURRENT_SPINNER_PID="$cmd_pid"

    local is_interactive_tty=false
    if [ -t 1 ] && [ "$NON_INTERACTIVE" = false ]; then
        is_interactive_tty=true
    fi

    if [ "$is_interactive_tty" = true ]; then
        printf "\033[?25l"
        local spin_chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local spin_idx=0
        while kill -0 "$cmd_pid" 2>/dev/null; do
            local elapsed=$((SECONDS - start_time))
            printf "\r${COLOR_BLUE}%s${COLOR_RESET} %s (%ds) \033[K" "${spin_chars[spin_idx]}" "$label" "$elapsed"
            spin_idx=$(( (spin_idx + 1) % 4 ))
            sleep 0.2
        done
        printf "\033[?25h"
    else
        printf "  ... %s\n" "$label"
        local last_notice=0
        while kill -0 "$cmd_pid" 2>/dev/null; do
            sleep 1
            local elapsed=$((SECONDS - start_time))
            if [ $((elapsed - last_notice)) -ge 15 ] && kill -0 "$cmd_pid" 2>/dev/null; then
                printf "  ... still running (%ds)\n" "$elapsed"
                last_notice="$elapsed"
            fi
        done
    fi

    local ec=0
    wait "$cmd_pid" || ec=$?
    CURRENT_SPINNER_PID=""
    local total_elapsed=$((SECONDS - start_time))

    if [ "$ec" -eq 0 ]; then
        if [ "$is_interactive_tty" = true ]; then
            printf "\r${COLOR_GREEN}OK${COLOR_RESET} %s (%ds)\033[K\n" "$label" "$total_elapsed"
        else
            printf "  OK %s (%ds)\n" "$label" "$total_elapsed"
        fi
        return 0
    fi

    if [ "$is_interactive_tty" = true ]; then
        printf "\r${COLOR_RED}FAIL${COLOR_RESET} %s (failed after %ds)\033[K\n" "$label" "$total_elapsed"
    else
        printf "  FAIL %s (failed after %ds)\n" "$label" "$total_elapsed"
    fi
    log_error "Command failed with exit code ${ec}."
    log_error "Last 30 lines of log (${LOG_FILE}):"
    tail -n 30 "$LOG_FILE" >&2 || true
    return "$ec"
}

# ------------------------------------------------------------------------------
# Input & TTY Helpers
# ------------------------------------------------------------------------------
# A character device at /dev/tty is not enough: without a controlling terminal
# the open fails, and every prompt would then loop on empty input. GHR_PROMPT_STDIN=1
# forces prompts onto standard input, which is how the test suite scripts them.
tty_available() {
    [ -c /dev/tty ] || return 1
    { : < /dev/tty; } 2>/dev/null
}

prompts_read_from_tty() {
    if [ "${GHR_PROMPT_STDIN:-0}" = "1" ]; then
        return 1
    fi
    tty_available
}

prompt_input() {
    local prompt_msg="$1"
    local default_val="${2:-}"
    local result=""

    if [ -n "$default_val" ]; then
        printf "${COLOR_BOLD}%s [default: %s]: ${COLOR_RESET}" "$prompt_msg" "$default_val" >&2
    else
        printf "${COLOR_BOLD}%s: ${COLOR_RESET}" "$prompt_msg" >&2
    fi

    if prompts_read_from_tty; then
        read -r result </dev/tty || true
    else
        read -r result || true
    fi

    if [ -z "$result" ]; then
        result="$default_val"
    fi
    echo "$result"
}

prompt_secret() {
    local prompt_msg="$1"
    local result=""

    printf "${COLOR_BOLD}%s: ${COLOR_RESET}" "$prompt_msg" >&2

    if prompts_read_from_tty; then
        read -r -s result </dev/tty || true
    else
        read -r -s result || true
    fi
    printf "\n" >&2
    echo "$result"
}

prompt_confirm() {
    local prompt_msg="$1"
    local default_ans="${2:-Y}" # Y or N
    local ans=""

    if [ "$default_ans" = "Y" ]; then
        printf "${COLOR_BOLD}%s [Y/n]: ${COLOR_RESET}" "$prompt_msg" >&2
    else
        printf "${COLOR_BOLD}%s [y/N]: ${COLOR_RESET}" "$prompt_msg" >&2
    fi

    if prompts_read_from_tty; then
        read -r ans </dev/tty || true
    else
        read -r ans || true
    fi

    ans="${ans:-$default_ans}"
    case "$ans" in
        [Yy]*) return 0 ;;
        *) return 1 ;;
    esac
}

# ------------------------------------------------------------------------------
# Path, Port and Lock Helpers
# ------------------------------------------------------------------------------
compute_project_name() {
    local dir="$1"
    local bname
    bname="$(basename "$dir" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-' | sed 's/^-*//' | sed 's/-*$//')"
    [ -z "$bname" ] && bname="stack"
    local hash=""
    if have sha256sum; then
        hash="$(printf "%s" "$dir" | sha256sum | awk '{print $1}')"
    elif have shasum; then
        hash="$(printf "%s" "$dir" | shasum -a 256 | awk '{print $1}')"
    else
        hash="$(printf "%s" "$dir" | cksum | awk '{print $1}')"
    fi
    echo "ghr-${bname}-${hash:0:8}"
}

is_port_in_use() {
    local port="$1"
    if have lsof; then
        if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
            return 0
        fi
    fi
    if have ss; then
        if ss -ltnH "sport = :$port" 2>/dev/null | grep -q ":$port"; then
            return 0
        fi
    elif have netstat; then
        if netstat -ltn 2>/dev/null | grep -q ":$port "; then
            return 0
        fi
    fi
    if have nc; then
        if nc -z 127.0.0.1 "$port" 2>/dev/null; then
            return 0
        fi
    fi
    if have podman; then
        if run_podman ps --format '{{.Ports}}' 2>/dev/null | grep -qE "(:${port}->|:${port}/)"; then
            return 0
        fi
    fi
    return 1
}

find_free_port() {
    local p="${1:-$CACHE_CONTAINER_PORT}"
    while [ "$p" -le 65535 ]; do
        if ! is_port_in_use "$p"; then
            echo "$p"
            return 0
        fi
        p=$((p + 1))
    done
    echo "$CACHE_CONTAINER_PORT"
    return 1
}

sanitize_and_resolve_dir() {
    local raw="$1"
    raw="$(echo "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    if [ -z "$raw" ]; then
        log_error "Installation directory path cannot be empty."
        return 1
    fi

    # Expand leading ~ or ~/
    # shellcheck disable=SC2088
    if [ "$raw" = "~" ]; then
        raw="$HOME"
    elif [ "${raw:0:2}" = "~/" ]; then
        raw="${HOME}/${raw:2}"
    fi

    if [[ "$raw" =~ [[:space:]] ]]; then
        log_error "Installation directory path contains whitespace, which breaks container bind mounts: '$raw'"
        return 1
    fi

    if [[ "$raw" == *:* ]]; then
        log_error "Installation directory path contains colon ':', which breaks volume mounts: '$raw'"
        return 1
    fi

    # systemd unit files treat '%' as a specifier, so a path carrying one cannot
    # be represented in a Quadlet unit that we generate from it.
    if [[ "$raw" == *%* ]]; then
        log_error "Installation directory path contains '%', which systemd interprets as a specifier: '$raw'"
        return 1
    fi

    if [[ "$raw" != /* ]]; then
        raw="${PWD}/${raw}"
    fi

    local parent
    parent="$(dirname "$raw")"
    local base
    base="$(basename "$raw")"
    if [ -d "$parent" ]; then
        parent="$(cd "$parent" && pwd)"
        raw="${parent}/${base}"
    fi

    echo "$raw"
    return 0
}

acquire_lock() {
    if [ -z "$INSTALL_DIR" ]; then
        return 0
    fi
    mkdir -p "$INSTALL_DIR"
    local lock_path="${INSTALL_DIR}/.install.lock"
    if ! mkdir "$lock_path" 2>/dev/null; then
        local lock_info="unknown process"
        if [ -f "${lock_path}/info" ]; then
            lock_info="$(tr '\n' ' ' < "${lock_path}/info" 2>/dev/null || echo "unknown")"
        fi
        log_error "Concurrent run detected: another installer process is currently running in ${INSTALL_DIR}."
        log_error "Lock directory exists: ${lock_path} (${lock_info})"
        exit 1
    fi
    CURRENT_LOCK_DIR="$lock_path"
    printf "PID=%d TIMESTAMP=%s USER=%s\n" "$$" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "${USER:-unknown}" > "${lock_path}/info"
}

# ------------------------------------------------------------------------------
# System Detection
# ------------------------------------------------------------------------------
detect_system() {
    OS="$(uname -s)"
    ARCH="$(uname -m)"
    log_debug "Host platform: ${OS} ${ARCH}"

    if [ "${GHR_UNSAFE_SKIP_PLATFORM_CHECKS:-0}" = "1" ] || [ "${GHR_ALLOW_NON_ROOT:-0}" = "1" ]; then
        SKIP_PLATFORM_CHECKS=true
        log_warn "Platform checks are disabled (GHR_UNSAFE_SKIP_PLATFORM_CHECKS/GHR_ALLOW_NON_ROOT)."
        log_warn "This mode is for tests and file review only: no systemd or Podman capability is verified."
    fi

    if [ "$(id -u)" -eq 0 ]; then
        SUDO=()
    elif have sudo; then
        SUDO=(sudo)
    else
        SUDO=()
    fi

    if [ "$SKIP_PLATFORM_CHECKS" = true ]; then
        # Checks are skipped only for tests and file review; escalating then would
        # bypass the stubbed binaries through sudo's own PATH.
        SUDO=()
        return 0
    fi

    if [ "$OS" != "Linux" ]; then
        log_error "This installer requires a Linux host: detected ${OS}."
        log_error "On macOS/Windows, Podman runs inside a virtual machine ('podman machine') where"
        log_error "the host has no systemd to own the containers. Use install.sh (Docker path) instead."
        exit 1
    fi

    if [ "$(id -u)" -ne 0 ] && [ "${#SUDO[@]}" -eq 0 ]; then
        log_error "Root privileges are required: system-level Quadlet units are written to ${QUADLET_DIR}"
        log_error "and the stack runs as rootful Podman. Run this installer as root or install sudo."
        exit 1
    fi

    local pid1=""
    pid1="$(cat /proc/1/comm 2>/dev/null || true)"
    if [ "$pid1" != "systemd" ]; then
        log_error "systemd is not PID 1 on this host (found: '${pid1:-unknown}')."
        log_error "Containers generated as Quadlet units can only be managed by systemd."
        exit 1
    fi
}

detect_host_ip() {
    local detected_ip=""
    if have ip; then
        detected_ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' || true)"
    fi
    if [ -z "$detected_ip" ] && have hostname; then
        detected_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    fi
    if [ -z "$detected_ip" ] && have ipconfig; then
        detected_ip="$(ipconfig getifaddr en0 2>/dev/null || true)"
    fi
    echo "$detected_ip"
}

# ------------------------------------------------------------------------------
# Podman Environment
# ------------------------------------------------------------------------------
install_podman_package() {
    if have apt-get; then
        run_with_spinner "Installing Podman via apt" bash -c 'DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq podman'
    elif have dnf; then
        run_with_spinner "Installing Podman via dnf" as_root dnf install -y -q podman
    elif have yum; then
        run_with_spinner "Installing Podman via yum" as_root yum install -y -q podman
    elif have zypper; then
        run_with_spinner "Installing Podman via zypper" as_root zypper --non-interactive install podman
    elif have pacman; then
        run_with_spinner "Installing Podman via pacman" as_root pacman -Sy --noconfirm podman
    elif have apk; then
        run_with_spinner "Installing Podman via apk" as_root apk add --no-cache podman
    else
        log_error "No supported package manager found (apt-get/dnf/yum/zypper/pacman/apk)."
        log_error "Install Podman >= ${MIN_PODMAN_VERSION} manually and re-run with --skip-podman-install."
        exit 1
    fi
}

ensure_podman_installed() {
    if have podman; then
        return 0
    fi

    if [ "$SKIP_PODMAN_INSTALL" = true ]; then
        log_error "Podman is not installed and --skip-podman-install was specified."
        exit 1
    fi

    local do_install=false
    if [ "$SKIP_PLATFORM_CHECKS" = true ]; then
        log_error "Podman is not installed. Install it, or point the test suite at a stub podman binary."
        exit 1
    fi

    if [ "$NON_INTERACTIVE" = true ]; then
        if [ "${GHR_INSTALL_PODMAN:-yes}" = "yes" ]; then
            do_install=true
        else
            log_error "Podman is missing and GHR_INSTALL_PODMAN is set to '${GHR_INSTALL_PODMAN}'."
            exit 1
        fi
    else
        if prompt_confirm "Podman is not installed. Install it now with the system package manager?" "Y"; then
            do_install=true
        else
            log_error "Podman is required to deploy this stack."
            exit 1
        fi
    fi

    if [ "$do_install" = true ]; then
        install_podman_package
        if ! have podman; then
            log_error "Podman still not found after installation. Install it manually and re-run."
            exit 1
        fi
    fi
}

podman_generator_path() {
    local candidate
    for candidate in \
        /usr/lib/systemd/system-generators/podman-system-generator \
        /usr/libexec/systemd/system-generators/podman-system-generator \
        /usr/local/lib/systemd/system-generators/podman-system-generator; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

verify_podman_version() {
    local raw_version=""
    raw_version="$(podman --version 2>/dev/null | awk '{print $NF}' || true)"
    if [ -z "$raw_version" ]; then
        log_error "Unable to determine the Podman version ('podman --version' produced no usable output)."
        exit 1
    fi
    log_debug "Detected Podman version ${raw_version}"

    local too_old=false
    if ! version_ge "$raw_version" "$MIN_PODMAN_VERSION"; then
        too_old=true
    fi

    if [ "$SKIP_PLATFORM_CHECKS" = true ]; then
        if [ "$too_old" = true ]; then
            log_warn "Podman ${raw_version} is below the required ${MIN_PODMAN_VERSION}; not enforced in unchecked mode."
        fi
        log_debug "Podman version enforcement is disabled in unchecked mode."
        return 0
    fi

    if [ "$too_old" = true ]; then
        log_error "Podman ${raw_version} is too old: Quadlet requires Podman >= ${MIN_PODMAN_VERSION}."
        log_error "Upgrade options:"
        log_error "  * Debian 12: enable bookworm-backports and install podman from it."
        log_error "  * Ubuntu 22.04: upgrade the host release or install podman from a newer upstream repository."
        log_error "  * RHEL 8/9, CentOS Stream, Fedora, openSUSE: 'dnf update podman' / 'zypper update podman'."
        log_error "Then re-run this installer."
        exit 1
    fi

    if ! podman_generator_path >/dev/null; then
        log_error "podman-system-generator was not found, so this Podman build has no Quadlet support."
        log_error "Install the 'podman' package that ships Quadlet (Podman >= ${MIN_PODMAN_VERSION}) and re-run."
        exit 1
    fi
}

verify_podman_runtime() {
    if [ "$SKIP_PLATFORM_CHECKS" = true ]; then
        return 0
    fi
    if ! run_podman info >/dev/null 2>&1; then
        log_error "'podman info' failed. Rootful Podman cannot manage containers on this host."
        log_error "Run 'podman info --debug' as root to inspect the failure."
        exit 1
    fi
    local cgroups=""
    cgroups="$(run_podman info --format '{{.Host.CgroupsVersion}}' 2>/dev/null || true)"
    log_debug "Rootful Podman is responding (cgroups ${cgroups:-unknown})."
}

ensure_podman_socket() {
    if [ -z "$PODMAN_SOCKET" ]; then
        log_info "Podman API socket exposure is disabled (PODMAN_SOCKET is empty)."
        return 0
    fi

    if [ "$SKIP_PLATFORM_CHECKS" = true ]; then
        log_debug "Skipping podman.socket verification in unchecked mode."
        return 0
    fi

    if ! run_systemctl cat podman.socket >/dev/null 2>&1; then
        log_error "The 'podman.socket' unit is not available, so workflow containers cannot reach Podman."
        log_error "Install the podman package that provides podman.socket, or disable the mount with"
        log_error "GHR_PODMAN_SOCKET= (empty) to deploy runners without container-building capability."
        exit 1
    fi

    run_with_spinner "Enabling podman.socket (Podman API for workflow containers)" run_systemctl enable --now podman.socket

    local waited=0
    while [ "$waited" -lt 15 ]; do
        if [ -S "$PODMAN_SOCKET" ]; then
            log_info "Podman API socket is ready at ${PODMAN_SOCKET}."
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    log_error "podman.socket did not create ${PODMAN_SOCKET} within 15s."
    log_error "Inspect it with: systemctl status podman.socket"
    exit 1
}

verify_environment() {
    detect_system
    ensure_podman_installed
    verify_podman_version
    verify_podman_runtime
    ensure_podman_socket
}

# ------------------------------------------------------------------------------
# URL & Token Helpers
# ------------------------------------------------------------------------------
validate_runner_url() {
    local url="$1"
    # Canonical GitHub repo or org URL
    if [[ "$url" =~ ^https://github\.com/[^/[:space:]]+(/[^/[:space:]]+)?/?$ ]]; then
        return 0
    fi
    # GitHub Enterprise Server (any https host)
    if [[ "$url" =~ ^https://[^/[:space:]]+/[^/[:space:]]+(/[^/[:space:]]+)?/?$ ]]; then
        return 2
    fi
    return 1
}

derive_prefix_from_url() {
    local url="$1"
    url="${url%/}"
    local name
    name="$(basename "$url" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-' | sed 's/-*$//')"
    echo "${name}-"
}

derive_settings_url() {
    local url="${1%/}"
    while [[ "$url" == */ ]]; do
        url="${url%/}"
    done
    local proto="https"
    local rest="$url"
    if [[ "$url" == http://* ]]; then
        proto="http"
        rest="${url#http://}"
    elif [[ "$url" == https://* ]]; then
        proto="https"
        rest="${url#https://}"
    fi

    local host="${rest%%/*}"
    local path="${rest#*/}"

    if [[ "$path" == *"/"* ]]; then
        echo "${proto}://${host}/${path}/settings/actions/runners"
    else
        echo "${proto}://${host}/organizations/${path}/settings/actions/runners"
    fi
}

# ------------------------------------------------------------------------------
# Configuration Record (.env) Access
# ------------------------------------------------------------------------------
# read_env_value <key> <file> - prints the value, returns 1 when the key is absent.
# Values are read with grep instead of sourcing the file: the file holds secrets
# and must never be executed.
read_env_value() {
    local key="$1"
    local file="$2"
    local line=""
    [ -f "$file" ] || return 1
    line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n 1 || true)"
    [ -n "$line" ] || return 1
    printf '%s' "${line#*=}"
}

seed_passthrough_defaults() {
    local i=0
    local key=""
    for key in "${PASSTHROUGH_KEYS[@]}"; do
        if [ -z "${!key+set}" ] && [ -n "${PASSTHROUGH_DEFAULTS[i]}" ]; then
            printf -v "$key" '%s' "${PASSTHROUGH_DEFAULTS[i]}"
        fi
        i=$((i + 1))
    done
}

apply_passthrough_values() {
    local env_file="$1"
    local key=""
    local value=""
    for key in "${PASSTHROUGH_KEYS[@]}"; do
        if value="$(read_env_value "$key" "$env_file")"; then
            printf -v "$key" '%s' "$value"
        fi
    done
}

passthrough_value() {
    local key="$1"
    printf '%s' "${!key:-}"
}

apply_env_record() {
    local env_file="$1"
    local value=""

    if value="$(read_env_value PROJECT_NAME "$env_file")"; then
        PROJECT_NAME="$value"
    fi
    if [ -z "${GHR_QUADLET_DIR:-}" ]; then
        if value="$(read_env_value QUADLET_DIR "$env_file")"; then
            QUADLET_DIR="$value"
        fi
    fi
    if [ -z "${GHR_PODMAN_SOCKET+x}" ]; then
        if value="$(read_env_value PODMAN_SOCKET "$env_file")"; then
            PODMAN_SOCKET="$value"
        fi
    fi
    if value="$(read_env_value RUNNER_COUNT "$env_file")"; then
        RUNNER_COUNT="$value"
    fi
    if value="$(read_env_value RUNNER_IMAGE "$env_file")"; then
        RUNNER_IMAGE="$value"
    fi
    if value="$(read_env_value CACHE_IMAGE "$env_file")"; then
        CACHE_IMAGE="$value"
    fi
    if value="$(read_env_value CACHE_ENABLED "$env_file")"; then
        CACHE_ENABLED="$value"
    fi
    if value="$(read_env_value CACHE_MODE "$env_file")"; then
        CACHE_MODE="$value"
    fi
    if value="$(read_env_value CACHE_URL "$env_file")"; then
        CACHE_URL="$value"
    fi
    if value="$(read_env_value CACHE_PORT "$env_file")"; then
        CACHE_PORT="$value"
    fi
    if [ -z "${GHR_CACHE_CLEANUP_DAYS+x}" ]; then
        if value="$(read_env_value CACHE_CLEANUP_OLDER_THAN_DAYS "$env_file")"; then
            CACHE_CLEANUP_DAYS="$value"
        fi
    fi
    if [ -z "${GHR_CACHE_MAX_USAGE_PERCENT+x}" ]; then
        if value="$(read_env_value CACHE_FILESYSTEM_MAX_USAGE_PERCENT "$env_file")"; then
            CACHE_MAX_USAGE_PERCENT="$value"
        fi
    fi
    if [ -z "${GHR_SELINUX+x}" ]; then
        if value="$(read_env_value SELINUX_DISABLE "$env_file")"; then
            SELINUX_DISABLE="$value"
        fi
    fi
    if [ -z "${GHR_AUTO_UPDATE+x}" ]; then
        if value="$(read_env_value AUTO_UPDATE "$env_file")"; then
            if [ "$value" = "true" ] || [ "$value" = "1" ]; then
                AUTO_UPDATE=true
            else
                AUTO_UPDATE=false
            fi
        fi
    fi

    local i=1
    local url=""
    local token=""
    local prefix=""
    local labels=""
    local workdir=""
    while [ "$i" -le "$RUNNER_COUNT" ]; do
        url="$(read_env_value "RUNNER_${i}_URL" "$env_file" || true)"
        token="$(read_env_value "RUNNER_${i}_TOKEN" "$env_file" || true)"
        prefix="$(read_env_value "RUNNER_${i}_NAME_PREFIX" "$env_file" || true)"
        labels="$(read_env_value "RUNNER_${i}_LABELS" "$env_file" || true)"
        workdir="$(read_env_value "RUNNER_${i}_WORKDIR" "$env_file" || true)"
        RUNNER_URLS+=("$url")
        RUNNER_TOKENS+=("$token")
        RUNNER_PREFIXES+=("$prefix")
        RUNNER_LABELS+=("$labels")
        RUNNER_WORKDIR_LIST+=("$workdir")
        i=$((i + 1))
    done
}

print_existing_config() {
    local env_file="$1"
    local count=""
    count="$(read_env_value RUNNER_COUNT "$env_file" || echo 0)"
    if [ -z "$count" ] || [ "$count" -eq 0 ]; then
        return 1
    fi
    printf "Configured runners:\n"
    local i=1
    while [ "$i" -le "$count" ]; do
        local url=""
        local prefix=""
        url="$(read_env_value "RUNNER_${i}_URL" "$env_file" || true)"
        prefix="$(read_env_value "RUNNER_${i}_NAME_PREFIX" "$env_file" || true)"
        printf "  - Runner %d: %s (Prefix: %s)\n" "$i" "${url:-<unset>}" "${prefix:-<default>}"
        i=$((i + 1))
    done
    return 0
}

reset_runner_arrays() {
    RUNNER_COUNT=0
    RUNNER_URLS=()
    RUNNER_TOKENS=()
    RUNNER_PREFIXES=()
    RUNNER_LABELS=()
    RUNNER_WORKDIR_LIST=()
}

# ------------------------------------------------------------------------------
# Configuration Collection - Interactive
# ------------------------------------------------------------------------------
collect_interactive_config() {
    local default_dir
    if [ "$(id -u)" -eq 0 ]; then
        default_dir="/opt/github-runner"
    else
        default_dir="${HOME}/github-runner"
    fi

    if [ -z "$INSTALL_DIR" ]; then
        while true; do
            local raw_dir
            raw_dir="$(prompt_input "Enter installation directory" "$default_dir")"
            local resolved
            if resolved="$(sanitize_and_resolve_dir "$raw_dir")"; then
                INSTALL_DIR="$resolved"
                break
            fi
        done
    else
        INSTALL_DIR="$(sanitize_and_resolve_dir "$INSTALL_DIR")" || exit 1
    fi
    mkdir -p "$INSTALL_DIR"
    acquire_lock

    local env_file="${INSTALL_DIR}/.env"
    local mode="new"

    if [ -f "$env_file" ]; then
        print_existing_config "$env_file" || true
        apply_env_record "$env_file"
        apply_passthrough_values "$env_file"
        printf "\n"
        local action
        action="$(prompt_input "Choose action: [A]dd runners / [R]econfigure from scratch / [Q]uit" "A")"
        case "$action" in
            [Aa]*) mode="add" ;;
            [Rr]*) mode="reconfigure" ;;
            [Qq]*)
                log_info "Operation cancelled by user."
                exit 0
                ;;
            *)
                log_warn "Unknown choice '$action', defaulting to Add runners."
                mode="add"
                ;;
        esac
    fi

    if [ -z "$PROJECT_NAME" ]; then
        PROJECT_NAME="$(compute_project_name "$INSTALL_DIR")"
    fi

    if [ "$mode" = "reconfigure" ]; then
        reset_runner_arrays
        CACHE_PORT=""
    fi

    seed_passthrough_defaults

    # Runner collection loop
    local adding=true
    while [ "$adding" = true ]; do
        local runner_num=$((RUNNER_COUNT + 1))
        printf "\n--- Configuring Runner #%d ---\n" "$runner_num"

        local r_url=""
        while true; do
            r_url="$(prompt_input "GitHub Repository or Organization URL (e.g. https://github.com/org/repo)")"
            if [ -z "$r_url" ]; then
                log_error "URL cannot be empty."
                continue
            fi
            local v_res=0
            validate_runner_url "$r_url" || v_res=$?
            if [ "$v_res" -eq 0 ]; then
                break
            elif [ "$v_res" -eq 2 ]; then
                log_warn "This URL does not appear to be on github.com (GitHub Enterprise Server detected)."
                if prompt_confirm "Proceed with this GitHub Enterprise Server URL?" "Y"; then
                    break
                fi
            else
                log_error "Invalid URL. Expected format: https://github.com/<org> or https://github.com/<org>/<repo>"
            fi
        done

        local r_token=""
        while true; do
            r_token="$(prompt_secret "GitHub Runner Registration Token")"
            if [ -z "$r_token" ]; then
                log_error "Registration token cannot be empty."
                continue
            fi
            break
        done

        local default_prefix
        default_prefix="$(derive_prefix_from_url "$r_url")"
        local r_prefix
        r_prefix="$(prompt_input "Runner name prefix" "$default_prefix")"

        local r_labels
        r_labels="$(prompt_input "Runner labels (comma-separated)" "$DEFAULT_LABELS")"

        local default_inst="${GHR_RUNNER_INSTANCES:-${GHR_INSTANCES:-1}}"
        local r_instances
        while true; do
            r_instances="$(prompt_input "Number of runner instances for this target (to run jobs concurrently)" "$default_inst")"
            if [[ "$r_instances" =~ ^[1-9][0-9]*$ ]]; then
                break
            fi
            log_error "Please enter a valid positive number (e.g. 1, 2, 4)."
        done

        local inst=1
        while [ "$inst" -le "$r_instances" ]; do
            local next_num=$((RUNNER_COUNT + 1))
            local inst_prefix="$r_prefix"
            if [ "$r_instances" -gt 1 ]; then
                if [[ "$r_prefix" == *- ]]; then
                    inst_prefix="${r_prefix}${inst}-"
                else
                    inst_prefix="${r_prefix}-${inst}-"
                fi
            fi
            RUNNER_URLS+=("$r_url")
            RUNNER_TOKENS+=("$r_token")
            RUNNER_PREFIXES+=("$inst_prefix")
            RUNNER_LABELS+=("$r_labels")
            RUNNER_WORKDIR_LIST+=("${INSTALL_DIR}/work/runner-${next_num}")
            RUNNER_COUNT="$next_num"
            inst=$((inst + 1))
        done

        if ! prompt_confirm "Add another repository/org runner?" "N"; then
            adding=false
        fi
    done

    if [ "$mode" != "add" ]; then
        printf "\n--- Cache Server Configuration ---\n"
        if prompt_confirm "Deploy the shared GitHub Actions cache server?" "Y"; then
            CACHE_ENABLED=true
            local detected_ip
            detected_ip="$(detect_host_ip)"
            local mode_choice="1"
            if [ -n "$detected_ip" ]; then
                mode_choice="$(prompt_input "Cache mode: [1] Internal Podman network (http://${CACHE_ALIAS}:3000) or [2] Publish host port (needed for 'container:' jobs)" "1")"
            fi
            if [ "$mode_choice" = "2" ]; then
                CACHE_MODE="host"
                local free_port
                free_port="$(find_free_port "$CACHE_CONTAINER_PORT")"
                CACHE_PORT="$(prompt_input "Host port for the cache server" "$free_port")"
                if [ -n "$detected_ip" ]; then
                    CACHE_URL="http://${detected_ip}:${CACHE_PORT}"
                else
                    CACHE_URL="http://host.containers.internal:${CACHE_PORT}"
                fi
                log_warn "The cache port ${CACHE_PORT} is published on every host interface. Keep it on a trusted network."
            else
                CACHE_MODE="internal"
                CACHE_PORT=""
                CACHE_URL="http://${CACHE_ALIAS}:${CACHE_CONTAINER_PORT}"
            fi
        else
            CACHE_ENABLED=false
            CACHE_MODE="internal"
            CACHE_URL=""
            CACHE_PORT=""
        fi

        RUNNER_IMAGE="$(prompt_input "Runner container image" "$DEFAULT_IMAGE")"
        CACHE_IMAGE="$(prompt_input "Cache server container image" "$DEFAULT_CACHE_IMAGE")"
    fi

    print_config_summary

    if ! prompt_confirm "Write configuration and install the systemd units?" "Y"; then
        log_info "Aborted by user."
        exit 0
    fi
}

print_config_summary() {
    printf "\n================ Configuration Summary ================\n"
    printf "Install Directory : %s\n" "$INSTALL_DIR"
    printf "Project Name      : %s\n" "$PROJECT_NAME"
    printf "Quadlet Dir       : %s\n" "$QUADLET_DIR"
    printf "Runner Image      : %s\n" "$RUNNER_IMAGE"
    printf "Cache Server      : %s\n" "$([ "$CACHE_ENABLED" = true ] && echo "Enabled (${CACHE_MODE}: ${CACHE_URL})" || echo "Disabled")"
    printf "Podman API Socket : %s\n" "${PODMAN_SOCKET:-<disabled>}"
    printf "Workflow Impact   : containers created by workflows run as host root through the Podman API\n"
    printf "Configured Runners: %d\n" "$RUNNER_COUNT"
    local idx=0
    while [ "$idx" -lt "$RUNNER_COUNT" ]; do
        local n=$((idx + 1))
        printf "  [%d] URL   : %s\n" "$n" "${RUNNER_URLS[idx]}"
        printf "      Token : %s\n" "$(mask_token "${RUNNER_TOKENS[idx]}")"
        printf "      Prefix: %s\n" "${RUNNER_PREFIXES[idx]}"
        printf "      Labels: %s\n" "${RUNNER_LABELS[idx]}"
        printf "      Work  : %s\n" "${RUNNER_WORKDIR_LIST[idx]}"
        printf "      Unit  : %s.service\n" "$(unit_base_runner "$n")"
        idx=$((idx + 1))
    done
    if [ "$CACHE_ENABLED" = true ]; then
        printf "  Cache unit: %s.service\n" "$(unit_base_cache)"
    fi
    printf "========================================================\n"
}

# ------------------------------------------------------------------------------
# Configuration Collection - Non-Interactive
# ------------------------------------------------------------------------------
collect_non_interactive_config() {
    if [ -z "$INSTALL_DIR" ]; then
        if [ "$(id -u)" -eq 0 ]; then
            INSTALL_DIR="/opt/github-runner"
        else
            INSTALL_DIR="${HOME}/github-runner"
        fi
    fi
    INSTALL_DIR="$(sanitize_and_resolve_dir "$INSTALL_DIR")" || exit 1
    mkdir -p "$INSTALL_DIR"
    acquire_lock

    local env_file="${INSTALL_DIR}/.env"
    local mode="${GHR_MODE:-new}"

    # Modes:
    #   new         - existing .env is replaced, instances start from the GHR_* variables
    #   add         - existing .env is loaded and new instances are appended
    #   reconfigure - existing .env is loaded for defaults, the instance list restarts empty
    if [ -f "$env_file" ]; then
        if [ "$mode" = "add" ]; then
            apply_env_record "$env_file"
        elif [ -z "$PROJECT_NAME" ]; then
            PROJECT_NAME="$(read_env_value PROJECT_NAME "$env_file" || true)"
        fi
    fi
    if [ -z "$PROJECT_NAME" ]; then
        PROJECT_NAME="$(compute_project_name "$INSTALL_DIR")"
    fi

    seed_passthrough_defaults
    if [ -f "$env_file" ]; then
        apply_passthrough_values "$env_file"
    fi

    if [ "$mode" != "add" ]; then
        reset_runner_arrays
        CACHE_PORT=""
    fi

    # Scan GHR_RUNNER_<n>_URL variables. In add mode the scan starts after the
    # existing instances so that new targets append instead of overwriting.
    local scan_idx=1
    if [ "$mode" = "add" ]; then
        local next_idx=$((RUNNER_COUNT + 1))
        local next_var="GHR_RUNNER_${next_idx}_URL"
        if [ -n "${!next_var:-}" ]; then
            scan_idx="$next_idx"
        fi
    fi

    while true; do
        local var_url="GHR_RUNNER_${scan_idx}_URL"
        local var_token="GHR_RUNNER_${scan_idx}_TOKEN"
        local var_labels="GHR_RUNNER_${scan_idx}_LABELS"
        local var_prefix="GHR_RUNNER_${scan_idx}_NAME_PREFIX"
        local var_workdir="GHR_RUNNER_${scan_idx}_WORKDIR"

        local url="${!var_url:-}"
        local token="${!var_token:-}"

        if [ "$scan_idx" -eq 1 ] && [ -z "$url" ] && [ -n "${GHR_RUNNER_URL:-}" ]; then
            url="$GHR_RUNNER_URL"
            token="${GHR_RUNNER_TOKEN:-}"
        fi

        if [ -z "$url" ]; then
            break
        fi

        if ! validate_runner_url "$url"; then
            log_error "Validation failed for ${var_url}='${url}'. Expected a GitHub repository or organization URL."
            exit 1
        fi

        if [ -z "$token" ]; then
            log_error "Missing required token in ${var_token} for ${url}."
            exit 1
        fi

        local base_prefix="${!var_prefix:-$(derive_prefix_from_url "$url")}"
        local labels="${!var_labels:-$DEFAULT_LABELS}"
        local custom_workdir="${!var_workdir:-}"

        local var_instances="GHR_RUNNER_${scan_idx}_INSTANCES"
        local instances="${!var_instances:-${GHR_RUNNER_INSTANCES:-${GHR_INSTANCES:-1}}}"
        if ! [[ "$instances" =~ ^[1-9][0-9]*$ ]]; then
            log_warn "Invalid instances value '${instances}' for runner ${scan_idx}. Defaulting to 1."
            instances=1
        fi

        local inst=1
        while [ "$inst" -le "$instances" ]; do
            local next_num=$((RUNNER_COUNT + 1))
            local inst_prefix="$base_prefix"
            if [ "$instances" -gt 1 ]; then
                if [[ "$base_prefix" == *- ]]; then
                    inst_prefix="${base_prefix}${inst}-"
                else
                    inst_prefix="${base_prefix}-${inst}-"
                fi
            fi

            local workdir
            if [ -n "$custom_workdir" ] && [ "$instances" -eq 1 ]; then
                workdir="$custom_workdir"
            elif [ -n "$custom_workdir" ]; then
                workdir="${custom_workdir}-${inst}"
            else
                workdir="${INSTALL_DIR}/work/runner-${next_num}"
            fi

            RUNNER_URLS+=("$url")
            RUNNER_TOKENS+=("$token")
            RUNNER_PREFIXES+=("$inst_prefix")
            RUNNER_LABELS+=("$labels")
            RUNNER_WORKDIR_LIST+=("$workdir")
            RUNNER_COUNT="$next_num"
            inst=$((inst + 1))
        done
        scan_idx=$((scan_idx + 1))
    done

    if [ "$RUNNER_COUNT" -eq 0 ]; then
        log_error "No runners configured. Provide GHR_RUNNER_1_URL and GHR_RUNNER_1_TOKEN (or GHR_RUNNER_URL / GHR_RUNNER_TOKEN)."
        exit 1
    fi

    if [ "$mode" != "add" ]; then
        local cache_flag="${GHR_CACHE:-1}"
        if [ "$cache_flag" = "0" ] || [ "$cache_flag" = "false" ]; then
            CACHE_ENABLED=false
            CACHE_MODE="internal"
            CACHE_URL=""
            CACHE_PORT=""
        else
            CACHE_ENABLED=true
            local cache_mode="${GHR_CACHE_MODE:-}"
            if [ -z "$cache_mode" ]; then
                if [ -n "${GHR_CACHE_PORT:-}" ] || { [ -n "${GHR_CACHE_URL:-}" ] && [[ "${GHR_CACHE_URL}" != *"${CACHE_ALIAS}"* ]]; }; then
                    cache_mode="host"
                else
                    cache_mode="internal"
                fi
            fi
            CACHE_MODE="$cache_mode"

            if [ "$CACHE_MODE" = "host" ]; then
                if [ -n "${GHR_CACHE_PORT:-}" ]; then
                    CACHE_PORT="$GHR_CACHE_PORT"
                else
                    CACHE_PORT="$(find_free_port "$CACHE_CONTAINER_PORT")"
                fi
                if [ -n "${GHR_CACHE_URL:-}" ]; then
                    CACHE_URL="$GHR_CACHE_URL"
                else
                    local host_ip
                    host_ip="$(detect_host_ip)"
                    if [ -z "$host_ip" ]; then
                        host_ip="host.containers.internal"
                    fi
                    CACHE_URL="http://${host_ip}:${CACHE_PORT}"
                fi
            else
                CACHE_MODE="internal"
                CACHE_PORT=""
                CACHE_URL="${GHR_CACHE_URL:-http://${CACHE_ALIAS}:${CACHE_CONTAINER_PORT}}"
            fi
        fi

        RUNNER_IMAGE="${GHR_IMAGE:-${RUNNER_IMAGE:-$DEFAULT_IMAGE}}"
        CACHE_IMAGE="${GHR_CACHE_IMAGE:-${CACHE_IMAGE:-$DEFAULT_CACHE_IMAGE}}"
    fi

    log_info "Non-interactive configuration loaded (${RUNNER_COUNT} runner instance(s), cache: ${CACHE_ENABLED})."
}

# ------------------------------------------------------------------------------
# Naming Helpers
# ------------------------------------------------------------------------------
# A unit base name addresses both systemd (<base>.service) and podman (<base>), so
# status queries and log commands need a single identifier.
unit_base_runner() {
    printf '%s-runner-%s' "$PROJECT_NAME" "$1"
}

unit_base_cache() {
    printf '%s-cache' "$PROJECT_NAME"
}

unit_service_name() {
    printf '%s.service' "$1"
}

unit_container_filename() {
    printf '%s.container' "$1"
}

stack_network_name() {
    printf '%s-net' "$PROJECT_NAME"
}

runner_volume_name() {
    printf '%s-runner-%s-data' "$PROJECT_NAME" "$1"
}

cache_volume_name() {
    printf '%s-cache-data' "$PROJECT_NAME"
}

env_dir_path() {
    printf '%s/env' "$INSTALL_DIR"
}

# all_unit_bases - runner units in index order, then the cache unit.
all_unit_bases() {
    local i=1
    while [ "$i" -le "$RUNNER_COUNT" ]; do
        unit_base_runner "$i"
        printf '\n'
        i=$((i + 1))
    done
    if [ "$CACHE_ENABLED" = true ]; then
        unit_base_cache
        printf '\n'
    fi
}

# ------------------------------------------------------------------------------
# Configuration File Generation
# ------------------------------------------------------------------------------
write_env_record() {
    local env_file="${INSTALL_DIR}/.env"
    local tmp_file="${INSTALL_DIR}/.env.tmp"

    {
        echo "# Auto-generated GitHub Actions Runner Stack configuration (Podman + systemd/Quadlet)"
        echo "# Generated at: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
        echo "# Edit this file, then apply it with: $(installer_command) --dir ${INSTALL_DIR}"
        echo "RUNTIME=podman"
        echo "PROJECT_NAME=${PROJECT_NAME}"
        echo "QUADLET_DIR=${QUADLET_DIR}"
        echo "PODMAN_MIN_VERSION=${MIN_PODMAN_VERSION}"
        echo "RUNNER_COUNT=${RUNNER_COUNT}"
        echo "RUNNER_IMAGE=${RUNNER_IMAGE}"
        echo "CACHE_IMAGE=${CACHE_IMAGE}"
        echo "CACHE_ENABLED=${CACHE_ENABLED}"
        echo "CACHE_MODE=${CACHE_MODE}"
        echo "CACHE_URL=${CACHE_URL}"
        echo "CACHE_PORT=${CACHE_PORT}"
        echo "CACHE_CLEANUP_OLDER_THAN_DAYS=${CACHE_CLEANUP_DAYS}"
        echo "CACHE_FILESYSTEM_MAX_USAGE_PERCENT=${CACHE_MAX_USAGE_PERCENT}"
        echo "PODMAN_SOCKET=${PODMAN_SOCKET}"
        echo "SELINUX_DISABLE=${SELINUX_DISABLE}"
        echo "AUTO_UPDATE=${AUTO_UPDATE}"
        echo ""

        local i=1
        while [ "$i" -le "$RUNNER_COUNT" ]; do
            local idx=$((i - 1))
            echo "# Runner ${i}"
            echo "RUNNER_${i}_URL=${RUNNER_URLS[idx]}"
            echo "RUNNER_${i}_TOKEN=${RUNNER_TOKENS[idx]}"
            echo "RUNNER_${i}_NAME_PREFIX=${RUNNER_PREFIXES[idx]}"
            echo "RUNNER_${i}_LABELS=${RUNNER_LABELS[idx]}"
            echo "RUNNER_${i}_WORKDIR=${RUNNER_WORKDIR_LIST[idx]}"
            echo ""
            i=$((i + 1))
        done

        local key=""
        local value=""
        local wrote_header=false
        for key in "${PASSTHROUGH_KEYS[@]}"; do
            value="$(passthrough_value "$key")"
            if [ -n "$value" ]; then
                if [ "$wrote_header" = false ]; then
                    echo "# Forwarded to every runner container (empty values are omitted)"
                    wrote_header=true
                fi
                echo "${key}=${value}"
            fi
        done
    } > "$tmp_file"

    chmod 600 "$tmp_file"
    mv -f "$tmp_file" "$env_file"
    chmod 600 "$env_file"
}

write_runner_env_file() {
    local idx="$1"
    local pos=$((idx - 1))
    local base=""
    base="$(unit_base_runner "$idx")"
    local target=""
    target="$(env_dir_path)/${base}.env"

    {
        echo "RUNNER_URL=${RUNNER_URLS[pos]}"
        echo "RUNNER_TOKEN=${RUNNER_TOKENS[pos]}"
        echo "RUNNER_NAME_PREFIX=${RUNNER_PREFIXES[pos]}"
        echo "RUNNER_LABELS=${RUNNER_LABELS[pos]}"
        echo "RUNNER_WORKDIR=${RUNNER_WORKDIR_LIST[pos]}"
        if [ "$CACHE_ENABLED" = true ]; then
            echo "ACTIONS_RESULTS_URL=${CACHE_URL%/}/"
        fi

        local key=""
        local value=""
        for key in "${PASSTHROUGH_KEYS[@]}"; do
            value="$(passthrough_value "$key")"
            if [ -n "$value" ]; then
                echo "${key}=${value}"
            fi
        done
    } > "$target"

    chmod 600 "$target"
}

write_cache_env_file() {
    local base=""
    base="$(unit_base_cache)"
    local target=""
    target="$(env_dir_path)/${base}.env"

    {
        echo "API_BASE_URL=${CACHE_URL}"
        echo "STORAGE_DRIVER=filesystem"
        echo "STORAGE_FILESYSTEM_PATH=/data/cache"
        echo "DB_DRIVER=sqlite"
        echo "DB_SQLITE_PATH=/data/cache-server.db"
        echo "CACHE_CLEANUP_OLDER_THAN_DAYS=${CACHE_CLEANUP_DAYS}"
        echo "CACHE_FILESYSTEM_MAX_USAGE_PERCENT=${CACHE_MAX_USAGE_PERCENT}"
    } > "$target"

    chmod 600 "$target"
}

write_service_env_files() {
    local env_dir=""
    env_dir="$(env_dir_path)"
    mkdir -p "$env_dir"
    chmod 700 "$env_dir"

    local i=1
    while [ "$i" -le "$RUNNER_COUNT" ]; do
        write_runner_env_file "$i"
        i=$((i + 1))
    done

    if [ "$CACHE_ENABLED" = true ]; then
        write_cache_env_file
    fi
}

prepare_workdirs() {
    local i=1
    local pos=0
    local workdir=""
    while [ "$i" -le "$RUNNER_COUNT" ]; do
        pos=$((i - 1))
        workdir="${RUNNER_WORKDIR_LIST[pos]}"
        mkdir -p "$workdir"
        i=$((i + 1))
    done
}

# ------------------------------------------------------------------------------
# Quadlet Unit Generation
# ------------------------------------------------------------------------------
unit_header() {
    local description="$1"
    local kind="$2"
    {
        echo "# Generated by install-podman.sh v${INSTALLER_VERSION} at $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
        echo "# Authoritative configuration: ${INSTALL_DIR}/.env"
        echo "# Regenerate after editing .env: $(installer_command) --dir ${INSTALL_DIR}"
        echo "[Unit]"
        echo "Description=${description}"
        echo "Documentation=${REPO_URL}"
        if [ "$CACHE_ENABLED" = true ] && [ "$kind" != "cache" ]; then
            # Soft ordering: a cache outage must not keep runners from starting.
            echo "Wants=$(unit_service_name "$(unit_base_cache)")"
            echo "After=$(unit_service_name "$(unit_base_cache)")"
        fi
        if [ -n "$PODMAN_SOCKET" ]; then
            echo "Wants=podman.socket"
            echo "After=podman.socket"
        fi
        # Docker's `restart: always` never gives up; systemd instead stops a
        # unit that fails 5 times in 10s and parks it in 'failed' until an
        # operator runs `systemctl reset-failed`. A runner whose registration
        # cannot complete yet has exactly that shape, so disable the rate limit
        # and let RestartSec in the [Service] section pace the attempts.
        echo "StartLimitIntervalSec=0"
    }
}

runner_volume_lines() {
    local idx="$1"
    local pos=$((idx - 1))
    local workdir="${RUNNER_WORKDIR_LIST[pos]}"
    # SELinux hosts need the job workspace relabeled for the container. The
    # socket below cannot be relabeled, which is why labels are off by default.
    local relabel=""
    if [ "$SELINUX_DISABLE" = false ]; then
        relabel=":z"
    fi
    # Identical source and target path: container jobs mount host paths through
    # the Podman API, so both sides must agree on the absolute path.
    echo "Volume=${workdir}:${workdir}${relabel}"
    echo "Volume=$(runner_volume_name "$idx"):/runner"
    if [ -n "$PODMAN_SOCKET" ]; then
        echo "Volume=${PODMAN_SOCKET}:${CONTAINER_DOCKER_SOCKET}"
        echo "Volume=${PODMAN_SOCKET}:${CONTAINER_PODMAN_SOCKET}"
    fi
}

cache_volume_lines() {
    echo "Volume=$(cache_volume_name):/data"
    if [ "$CACHE_MODE" = "host" ] && [ -n "$CACHE_PORT" ]; then
        echo "PublishPort=${CACHE_PORT}:${CACHE_CONTAINER_PORT}"
    fi
    echo "HealthCmd=wget -q --spider http://127.0.0.1:${CACHE_CONTAINER_PORT}/"
    echo "HealthInterval=10s"
    echo "HealthTimeout=5s"
    echo "HealthRetries=5"
    echo "HealthStartPeriod=10s"
}

quadlet_container_section() {
    local base="$1"
    local image="$2"
    local kind="$3"
    local idx="${4:-}"
    {
        echo ""
        echo "[Container]"
        echo "ContainerName=${base}"
        echo "Image=${image}"
        echo "EnvironmentFile=$(env_dir_path)/${base}.env"
        if [ "$kind" = "cache" ] && [ "$CACHE_MODE" = "internal" ]; then
            # The NetworkAlias= key only exists since Podman 5.2, while the alias
            # option of --network works from 4.4 and keeps the version floor low.
            echo "Network=$(stack_network_name):alias=${CACHE_ALIAS}"
        else
            echo "Network=$(stack_network_name)"
        fi
        echo "LogDriver=journald"
        if [ "$SELINUX_DISABLE" = true ]; then
            echo "SecurityLabelDisable=true"
        fi
        if [ "$AUTO_UPDATE" = true ]; then
            echo "AutoUpdate=registry"
        fi
        if [ "$kind" = "cache" ]; then
            cache_volume_lines
        else
            runner_volume_lines "$idx"
        fi
    }
}

quadlet_service_section() {
    {
        echo ""
        echo "[Service]"
        echo "Restart=always"
        # Pace retries so a failing unit does not hot-loop against the GitHub
        # API; paired with StartLimitIntervalSec=0 in the [Unit] section.
        echo "RestartSec=10"
        echo "TimeoutStartSec=900"
        # Self-heal when the network was pruned; the '-' prefix ignores the
        # already-exists failure and the create/start race between units.
        echo "ExecStartPre=-podman network create $(stack_network_name)"
        local key=""
        local value=""
        for key in "${PROXY_KEYS[@]}"; do
            value="$(passthrough_value "$key")"
            if [ -n "$value" ]; then
                # Podman itself (image pulls, network setup) needs the proxy too.
                echo "Environment=${key}=${value}"
            fi
        done
        echo ""
        echo "[Install]"
        # Generated units cannot be enabled with systemctl; the generator applies
        # this section instead (see podman-systemd.unit(5)).
        echo "WantedBy=multi-user.target default.target"
    }
}

write_runner_unit() {
    local idx="$1"
    local pos=$((idx - 1))
    local base=""
    base="$(unit_base_runner "$idx")"
    local tmp_file="${INSTALL_DIR}/.unit-${base}.tmp"

    {
        unit_header "GitHub Actions self-hosted runner #${idx} (${RUNNER_URLS[pos]})" "runner"
        quadlet_container_section "$base" "$RUNNER_IMAGE" "runner" "$idx"
        quadlet_service_section
    } > "$tmp_file"

    install_privileged "$tmp_file" "${QUADLET_DIR}/$(unit_container_filename "$base")" "0644"
    rm -f "$tmp_file"
}

write_cache_unit() {
    local base=""
    base="$(unit_base_cache)"
    local tmp_file="${INSTALL_DIR}/.unit-${base}.tmp"

    {
        unit_header "GitHub Actions cache server (${PROJECT_NAME})" "cache"
        quadlet_container_section "$base" "$CACHE_IMAGE" "cache"
        quadlet_service_section
    } > "$tmp_file"

    install_privileged "$tmp_file" "${QUADLET_DIR}/$(unit_container_filename "$base")" "0644"
    rm -f "$tmp_file"
}

remove_stale_units() {
    # Units for instances that no longer exist (for example after a reconfigure)
    # would otherwise stay wired into boot and keep calling the GitHub API.
    local existing=""
    existing="$(as_root ls -1 "${QUADLET_DIR}" 2>/dev/null | grep -E "^${PROJECT_NAME}-(runner-[0-9]+|cache)\.container$" || true)"
    [ -n "$existing" ] || return 0

    local name=""
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        local base="${name%.container}"
        local keep=false
        local i=1
        while [ "$i" -le "$RUNNER_COUNT" ]; do
            if [ "$base" = "$(unit_base_runner "$i")" ]; then
                keep=true
                break
            fi
            i=$((i + 1))
        done
        if [ "$CACHE_ENABLED" = true ] && [ "$base" = "$(unit_base_cache)" ]; then
            keep=true
        fi
        if [ "$keep" = false ]; then
            log_info "Removing unit of a no longer configured instance: ${name}"
            run_systemctl stop "$(unit_service_name "$base")" >/dev/null 2>&1 || true
            as_root rm -f "${QUADLET_DIR}/${name}"
            rm -f "$(env_dir_path)/${base}.env"
        fi
    done <<< "$existing"
}

write_quadlet_units() {
    as_root mkdir -p "$QUADLET_DIR"

    local i=1
    while [ "$i" -le "$RUNNER_COUNT" ]; do
        write_runner_unit "$i"
        i=$((i + 1))
    done

    if [ "$CACHE_ENABLED" = true ]; then
        write_cache_unit
    fi

    remove_stale_units
}

write_readme_txt() {
    local readme_file="${INSTALL_DIR}/README.txt"
    local first_unit=""
    first_unit="$(unit_service_name "$(unit_base_runner 1)")"

    cat <<EOF > "$readme_file"
================================================================================
GitHub Actions Self-Hosted Runner Stack (Podman + systemd / Quadlet)
================================================================================
Location      : ${INSTALL_DIR}
Project       : ${PROJECT_NAME}
Quadlet units : ${QUADLET_DIR}/${PROJECT_NAME}-*.container
Runners       : ${RUNNER_COUNT}
Cache         : $([ "$CACHE_ENABLED" = true ] && echo "${CACHE_MODE} (${CACHE_URL})" || echo "disabled")

systemd owns the stack. Quadlet unit files are turned into systemd services named
<unit>.service and start on boot through [Install] WantedBy=. They are NOT enabled
with 'systemctl enable' (systemd refuses to enable generated units).

Status and logs:
  systemctl list-units '${PROJECT_NAME}-*' --all
  systemctl status ${first_unit}
  journalctl -u ${first_unit} -f
  podman logs -f $(unit_base_runner 1)

Start, stop and restart one unit:
  sudo systemctl start   ${first_unit}
  sudo systemctl stop    ${first_unit}
  sudo systemctl restart ${first_unit}

Act on the whole stack:
  $(installer_command) --dir ${INSTALL_DIR} --status
  $(installer_command) --dir ${INSTALL_DIR} --start
  $(installer_command) --dir ${INSTALL_DIR} --stop
  $(installer_command) --dir ${INSTALL_DIR} --restart
  $(installer_command) --dir ${INSTALL_DIR} --upgrade

Uninstall (keeps volumes and .env unless confirmed):
  $(installer_command) --dir ${INSTALL_DIR} --uninstall

Configuration:
  ${INSTALL_DIR}/.env          authoritative record (0600)
  ${INSTALL_DIR}/env/*.env     per-service environment files (0600)
  Edit .env, then re-run: $(installer_command) --dir ${INSTALL_DIR}
EOF
}

write_files() {
    log_info "Writing configuration to ${INSTALL_DIR}..."

    init_log_file

    local env_file="${INSTALL_DIR}/.env"
    if [ -f "$env_file" ]; then
        local ts
        ts="$(date +%Y%m%d%H%M%S)"
        log_info "Backing up existing .env to .env.bak.${ts}"
        cp -f "$env_file" "${env_file}.bak.${ts}"
        chmod 600 "${env_file}.bak.${ts}" 2>/dev/null || true
    fi

    write_env_record
    write_service_env_files
    prepare_workdirs
    write_quadlet_units
    write_readme_txt

    log_info "Files generated successfully."
}

# ------------------------------------------------------------------------------
# Stack Loading (for lifecycle subcommands)
# ------------------------------------------------------------------------------
default_install_dir() {
    if [ "$(id -u)" -eq 0 ]; then
        echo "/opt/github-runner"
    else
        echo "${HOME}/github-runner"
    fi
}

load_stack_config() {
    if [ -z "$INSTALL_DIR" ]; then
        INSTALL_DIR="$(default_install_dir)"
    fi
    INSTALL_DIR="$(sanitize_and_resolve_dir "$INSTALL_DIR")" || exit 1

    local env_file="${INSTALL_DIR}/.env"
    if [ ! -f "$env_file" ]; then
        log_error "No configuration found in ${INSTALL_DIR} (.env is missing)."
        log_error "Run the installer first: $(installer_command) --dir ${INSTALL_DIR}"
        exit 1
    fi

    reset_runner_arrays
    apply_env_record "$env_file"
    apply_passthrough_values "$env_file"

    if [ "$RUNNER_COUNT" -eq 0 ]; then
        log_error "Configuration in ${env_file} does not declare any runner (RUNNER_COUNT=0)."
        exit 1
    fi

    log_debug "Loaded stack ${PROJECT_NAME} (${RUNNER_COUNT} runner instance(s), cache: ${CACHE_ENABLED})."
}

# ------------------------------------------------------------------------------
# systemd & Container Introspection
# ------------------------------------------------------------------------------
unit_active_state() {
    local base="$1"
    local state=""
    state="$(run_systemctl is-active "$(unit_service_name "$base")" 2>/dev/null || true)"
    if [ -z "$state" ]; then
        state="unknown"
    fi
    printf '%s' "$state"
}

unit_enabled_state() {
    local base="$1"
    local state=""
    state="$(run_systemctl is-enabled "$(unit_service_name "$base")" 2>/dev/null || true)"
    printf '%s' "${state:-generated}"
}

container_state() {
    local container="$1"
    local state=""
    state="$(run_podman ps -a --filter "name=^${container}$" --format '{{.Status}}' 2>/dev/null | head -n 1 || true)"
    if [ -z "$state" ]; then
        state="not created"
    fi
    printf '%s' "$state"
}

svc_logs() {
    local base="$1"
    local lines="${2:-40}"
    local out=""

    if have journalctl; then
        out="$(run_journalctl -u "$(unit_service_name "$base")" --no-pager -n "$lines" 2>/dev/null || true)"
    fi
    if [ -z "$out" ]; then
        out="$(run_podman logs --tail "$lines" "$base" 2>&1 || true)"
    fi
    printf '%s' "$out"
}

# Registration state is derived from the unit log. The scan keeps the last
# meaningful line, because a stale success from an earlier container must not
# outvote a fresh failure from the current one. Start-limit messages are held
# back as a fallback so a specific failure is never masked by the generic
# "systemd gave up" symptom that follows it.
classify_registration_logs() {
    local base="$1"
    local logs=""
    logs="$(svc_logs "$base" 120)"

    local state="PENDING"
    local start_limit_seen=false
    local line=""
    while IFS= read -r line; do
        case "$line" in
            *"Listening for Jobs"*) state="OK_LISTENING" ;;
            # Anchored on the registration endpoint: other endpoints can answer
            # 404 during normal operation and must not read as a failed install.
            *"Http response code: NotFound"*"runner-registration"*|*"Http response code: 404"*"runner-registration"*)
                state="FAIL_404"
                ;;
            *"Http response code: Unauthorized"*"runner-registration"*|*"Http response code: 401"*"runner-registration"*)
                state="FAIL_401"
                ;;
            *"Failed to create a session"*) state="FAIL_SESSION" ;;
            *"HttpClient.Timeout"*|*"Temporary failure in name resolution"*|*"Name or service not known"*) state="FAIL_EGRESS" ;;
            *"Start request repeated too quickly"*) start_limit_seen=true ;;
            # Only the positive sentence counts. The entrypoint also logs
            # "No existing runner configuration detected (.runner missing)" on
            # first boot, and a substring match reads that as a reused
            # configuration, which reports success for a failing runner.
            *"Existing runner configuration detected (.runner present)"*) state="REUSED_PENDING" ;;
            *"No existing runner configuration detected"*) state="PENDING" ;;
        esac
    done <<< "$logs"

    if [ "$state" = "PENDING" ] && [ "$start_limit_seen" = true ]; then
        state="FAIL_START_LIMIT"
    fi

    printf '%s' "$state"
}

registration_state_text() {
    local state="$1"
    case "$state" in
        OK_LISTENING) echo "OK: Listening for Jobs" ;;
        FAIL_404) echo "FAIL: Registration failed (404 Not Found - token invalid, expired, or issued for a different scope than the URL)" ;;
        FAIL_401) echo "FAIL: Registration failed (401 Unauthorized)" ;;
        FAIL_SESSION) echo "FAIL: Failed to create the runner session" ;;
        FAIL_EGRESS) echo "FAIL: The container cannot reach the GitHub API (host forwarding, firewall or DNS)" ;;
        FAIL_START_LIMIT) echo "FAIL: systemd stopped retrying (fix the cause, then: systemctl reset-failed <unit> && systemctl start <unit>)" ;;
        REUSED_PENDING) echo "WARN: Credentials are in place, but the runner did not report 'Listening for Jobs' within ${REGISTRATION_WAIT_SECONDS}s" ;;
        *) echo "WARN: No registration result within ${REGISTRATION_WAIT_SECONDS}s" ;;
    esac
}

runner_status_contains() {
    local needle="$1"
    local st=""
    for st in ${RUNNER_STATUS_ARRAY[@]+"${RUNNER_STATUS_ARRAY[@]}"}; do
        if [ "$st" = "$needle" ]; then
            return 0
        fi
    done
    return 1
}

# ------------------------------------------------------------------------------
# Start and Verification
# ------------------------------------------------------------------------------
ensure_network() {
    if [ "$SKIP_PLATFORM_CHECKS" = true ]; then
        return 0
    fi
    warn_about_network_backend
    local net=""
    net="$(stack_network_name)"
    if run_podman network inspect "$net" >/dev/null 2>&1; then
        log_debug "Podman network ${net} already exists."
        return 0
    fi
    run_with_spinner "Creating Podman network ${net} (DNS enabled for ${CACHE_ALIAS})" run_podman network create "$net"
}

# The internal cache mode resolves the cache by its network alias, which needs
# netavark (or the dnsname plugin on the legacy CNI backend).
warn_about_network_backend() {
    if [ "$CACHE_ENABLED" != true ] || [ "$CACHE_MODE" != "internal" ]; then
        return 0
    fi

    local backend=""
    backend="$(run_podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null || true)"
    case "$backend" in
        "" | netavark)
            return 0
            ;;
    esac

    log_warn "Podman uses the '${backend}' network backend: the alias ${CACHE_ALIAS} only resolves with netavark or the dnsname plugin."
    log_warn "If jobs cannot reach http://${CACHE_ALIAS}:${CACHE_CONTAINER_PORT}, reinstall with GHR_CACHE_MODE=host."
}

pull_images() {
    run_with_spinner "Pulling runner image ${RUNNER_IMAGE}" run_podman pull "$RUNNER_IMAGE"
    if [ "$CACHE_ENABLED" = true ]; then
        run_with_spinner "Pulling cache image ${CACHE_IMAGE}" run_podman pull "$CACHE_IMAGE"
    fi
}

daemon_reload() {
    run_with_spinner "Reloading systemd and generating Quadlet units" run_systemctl daemon-reload
}

verify_generated_units() {
    if [ "$SKIP_PLATFORM_CHECKS" = true ]; then
        log_debug "Skipping Quadlet generation verification in unchecked mode."
        return 0
    fi

    local generator=""
    generator="$(podman_generator_path 2>/dev/null || echo "podman-system-generator")"

    local missing=0
    local base=""
    while IFS= read -r base; do
        [ -n "$base" ] || continue
        if ! run_systemctl cat "$(unit_service_name "$base")" >/dev/null 2>&1; then
            log_error "systemd does not know $(unit_service_name "$base"): Quadlet did not generate it."
            log_error "Diagnose with:"
            log_error "  QUADLET_UNIT_DIRS=${QUADLET_DIR} ${generator} --dryrun"
            log_error "  systemd-analyze --generators=true verify $(unit_service_name "$base")"
            missing=$((missing + 1))
        fi
    done < <(all_unit_bases)

    if [ "$missing" -gt 0 ]; then
        exit 1
    fi
}

wait_for_unit_active() {
    local base="$1"
    local timeout="${2:-120}"
    local waited=0
    local state=""
    while [ "$waited" -lt "$timeout" ]; do
        state="$(unit_active_state "$base")"
        if [ "$state" = "active" ]; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

start_all_units() {
    if [ "$CACHE_ENABLED" = true ]; then
        run_with_spinner "Starting $(unit_service_name "$(unit_base_cache)")" run_systemctl start "$(unit_service_name "$(unit_base_cache)")"
        verify_unit_active "$(unit_base_cache)"
    fi

    local i=1
    local base=""
    while [ "$i" -le "$RUNNER_COUNT" ]; do
        base="$(unit_base_runner "$i")"
        run_with_spinner "Starting $(unit_service_name "$base")" run_systemctl start "$(unit_service_name "$base")"
        verify_unit_active "$base"
        i=$((i + 1))
    done
}

# systemctl start is synchronous, so a unit that is not active right after it
# returned means the container exits immediately (bad image, missing volume).
verify_unit_active() {
    local base="$1"
    if wait_for_unit_active "$base" 5; then
        log_debug "$(unit_service_name "$base") is active."
        return 0
    fi
    log_warn "$(unit_service_name "$base") did not stay active: check 'systemctl status $(unit_service_name "$base")'."
    return 1
}

stop_all_units() {
    # Runners first: stopping them before the cache avoids failed cache lookups
    # in jobs that are still finishing.
    local i=1
    local base=""
    while [ "$i" -le "$RUNNER_COUNT" ]; do
        base="$(unit_base_runner "$i")"
        run_with_spinner "Stopping $(unit_service_name "$base")" run_systemctl stop "$(unit_service_name "$base")"
        i=$((i + 1))
    done

    if [ "$CACHE_ENABLED" = true ]; then
        run_with_spinner "Stopping $(unit_service_name "$(unit_base_cache)")" run_systemctl stop "$(unit_service_name "$(unit_base_cache)")"
    fi
}

restart_all_units() {
    if [ "$CACHE_ENABLED" = true ]; then
        run_with_spinner "Restarting $(unit_service_name "$(unit_base_cache)")" run_systemctl restart "$(unit_service_name "$(unit_base_cache)")"
    fi

    local i=1
    local base=""
    while [ "$i" -le "$RUNNER_COUNT" ]; do
        base="$(unit_base_runner "$i")"
        run_with_spinner "Restarting $(unit_service_name "$base")" run_systemctl restart "$(unit_service_name "$base")"
        i=$((i + 1))
    done
}

wait_for_registrations() {
    declare -a statuses=()
    local i=1
    while [ "$i" -le "$RUNNER_COUNT" ]; do
        statuses+=("PENDING")
        i=$((i + 1))
    done

    local is_interactive_tty=false
    if [ -t 1 ] && [ "$NON_INTERACTIVE" = false ]; then
        is_interactive_tty=true
    fi

    local elapsed=0
    local last_notice=0
    local all_done=false
    local spin_chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local spin_idx=0

    if [ "$is_interactive_tty" = true ]; then
        printf "\033[?25l"
    fi

    while [ "$elapsed" -lt "$REGISTRATION_WAIT_SECONDS" ]; do
        all_done=true
        local k=1
        while [ "$k" -le "$RUNNER_COUNT" ]; do
            local pos=$((k - 1))
            # Terminal states are final: success stays success, and a reported
            # failure must not be overwritten by later log noise.
            case "${statuses[pos]}" in
                OK_LISTENING|FAIL_404|FAIL_401|FAIL_SESSION|FAIL_EGRESS|FAIL_START_LIMIT)
                    k=$((k + 1))
                    continue
                    ;;
            esac
            local state=""
            state="$(classify_registration_logs "$(unit_base_runner "$k")")"
            case "$state" in
                OK_LISTENING)
                    statuses[pos]="$state"
                    if [ "$is_interactive_tty" = true ]; then
                        printf "\r${COLOR_GREEN}OK${COLOR_RESET} Runner #%d registered (%s) \033[K\n" "$k" "$state"
                    else
                        printf "  OK Runner #%d registered (%s)\n" "$k" "$state"
                    fi
                    ;;
                FAIL_404|FAIL_401|FAIL_SESSION|FAIL_EGRESS|FAIL_START_LIMIT)
                    statuses[pos]="$state"
                    if [ "$is_interactive_tty" = true ]; then
                        printf "\r${COLOR_RED}FAIL${COLOR_RESET} Runner #%d: %s \033[K\n" "$k" "$(registration_state_text "$state")"
                    else
                        printf "  FAIL Runner #%d: %s\n" "$k" "$(registration_state_text "$state")"
                    fi
                    ;;
                REUSED_PENDING)
                    # Credentials are in place, so registration is skipped, but
                    # the runner still has to report itself online: keep polling
                    # and report this state if it never does.
                    statuses[pos]="REUSED_PENDING"
                    all_done=false
                    ;;
                *)
                    all_done=false
                    ;;
            esac
            k=$((k + 1))
        done

        if [ "$all_done" = true ]; then
            break
        fi

        if [ "$is_interactive_tty" = true ]; then
            printf "\r${COLOR_BLUE}%s${COLOR_RESET} Waiting for runner registration (%ds/%ds)... \033[K" "${spin_chars[spin_idx]}" "$elapsed" "$REGISTRATION_WAIT_SECONDS"
            spin_idx=$(( (spin_idx + 1) % 4 ))
            sleep 0.5
            elapsed=$((elapsed + 1))
        else
            sleep 2
            elapsed=$((elapsed + 2))
            if [ $((elapsed - last_notice)) -ge 15 ]; then
                printf "  ... still waiting for runner registration (%ds)\n" "$elapsed"
                last_notice="$elapsed"
            fi
        fi
    done

    if [ "$is_interactive_tty" = true ]; then
        printf "\033[?25h\r\033[K"
    fi

    # Runner units that failed to register are stopped: a restart loop would keep
    # hammering the GitHub API with a token that cannot work.
    local failed_count=0
    local n=1
    while [ "$n" -le "$RUNNER_COUNT" ]; do
        local npos=$((n - 1))
        local st="${statuses[npos]}"
        case "$st" in
            FAIL_*)
                run_systemctl stop "$(unit_service_name "$(unit_base_runner "$n")")" >/dev/null 2>&1 || true
                failed_count=$((failed_count + 1))
                ;;
        esac
        n=$((n + 1))
    done
    FAILED_RUNNERS_COUNT="$failed_count"

    RUNNER_STATUS_ARRAY=()
    local m=1
    while [ "$m" -le "$RUNNER_COUNT" ]; do
        RUNNER_STATUS_ARRAY+=("${statuses[$((m - 1))]}")
        m=$((m + 1))
    done
}

# A runner must reach the GitHub API before it can register, and containers
# reach the internet only when the host forwards their traffic. A host firewall
# that drops forwarding (ufw's DEFAULT_FORWARD_POLICY=DROP, or Docker and
# netavark rules competing inside nftables) turns that into a restart loop whose
# logs look like a token problem, so this runs before anything is started.
verify_container_egress() {
    if [ "${GHR_SKIP_EGRESS_CHECK:-no}" = "yes" ]; then
        log_warn "Skipping the container egress check (GHR_SKIP_EGRESS_CHECK=yes)."
        return 0
    fi

    local net=""
    net="$(stack_network_name)"
    local iface=""
    iface="$(run_podman network inspect "$net" --format '{{.NetworkInterface}}' 2>/dev/null || true)"

    local -a proxy_env=()
    local key="" value=""
    for key in "${PROXY_KEYS[@]}"; do
        value="$(passthrough_value "$key")"
        if [ -n "$value" ]; then
            proxy_env+=("--env" "${key}=${value}")
        fi
    done

    # The entrypoint must be overridden, otherwise the probe container would try
    # to register a real runner.
    local probe='getent hosts api.github.com >/dev/null 2>&1 || { echo PROBE_DNS_FAILED; exit 0; }; curl -fsS -m 20 -o /dev/null https://api.github.com/ && echo PROBE_OK || echo PROBE_EGRESS_FAILED'
    local out=""
    out="$(run_podman run --rm --network "$net" ${proxy_env[@]+"${proxy_env[@]}"} \
        --entrypoint /bin/sh "$RUNNER_IMAGE" -c "$probe" 2>&1 || true)"

    case "$out" in
        *PROBE_OK*)
            log_info "Containers on ${net} can reach the GitHub API."
            return 0
            ;;
        *PROBE_DNS_FAILED*)
            log_error "Containers on ${net} cannot resolve api.github.com."
            log_error "DNS is served by the network backend in use:"
            log_error "  podman info --format '{{.Host.NetworkBackend}}'"
            log_error "Re-run with GHR_SKIP_EGRESS_CHECK=yes to install anyway."
            exit 1
            ;;
        *PROBE_EGRESS_FAILED*)
            log_error "Containers on ${net} cannot reach the GitHub API even though DNS resolves."
            log_error "The host is dropping forwarded traffic from the container network."
            if [ -n "$iface" ]; then
                log_error "With ufw (DEFAULT_FORWARD_POLICY=DROP) allow that bridge, then re-run:"
                log_error "  sudo ufw route allow in on ${iface}"
                log_error "  sudo ufw route allow out on ${iface}"
            else
                log_error "Allow forwarding from the container bridge of ${net}, then re-run."
            fi
            log_error "Re-run with GHR_SKIP_EGRESS_CHECK=yes to install anyway."
            exit 1
            ;;
    esac

    log_warn "Could not run the egress probe container; skipping the check."
}

verify_cache_reachability() {
    if [ "$CACHE_ENABLED" != true ] || [ "$SKIP_PLATFORM_CHECKS" = true ]; then
        return 0
    fi
    if [ "$CACHE_MODE" != "internal" ]; then
        return 0
    fi

    local probe_url="${CACHE_URL%/}/"
    local runner_container=""
    runner_container="$(unit_base_runner 1)"

    local attempt=1
    local out=""
    local probe_ran=false
    local dns_failed=false
    while [ "$attempt" -le 3 ]; do
        # Resolving the alias and answering on it are separate failures with
        # separate fixes, and a container that is still restarting fails the
        # exec without saying anything about DNS.
        # shellcheck disable=SC2016  # $1 and $2 are expanded inside the container
        out="$(run_podman exec "$runner_container" sh -c \
            'getent hosts "$1" >/dev/null 2>&1 || { echo PROBE_DNS_FAILED; exit 0; }; wget -q --spider "$2" && echo PROBE_OK || echo PROBE_NO_ANSWER' \
            _ "$CACHE_ALIAS" "$probe_url" 2>/dev/null || true)"
        case "$out" in
            *PROBE_OK*)
                log_info "Cache server is reachable from the runner container (${probe_url})."
                return 0
                ;;
            *PROBE_NO_ANSWER*) probe_ran=true ;;
            *PROBE_DNS_FAILED*) probe_ran=true; dns_failed=true ;;
        esac
        sleep 2
        attempt=$((attempt + 1))
    done

    if [ "$probe_ran" = false ]; then
        log_warn "Could not run the cache probe inside ${runner_container}; the container may still be restarting."
        log_warn "Re-check later with: podman exec ${runner_container} wget -q --spider ${probe_url}"
        return 0
    fi

    if [ "$dns_failed" = true ]; then
        log_warn "The runner container cannot resolve ${CACHE_ALIAS}."
        log_warn "Alias resolution needs the netavark backend (or the dnsname plugin on the CNI backend):"
        log_warn "  podman info --format '{{.Host.NetworkBackend}}'"
        log_warn "  podman network inspect $(stack_network_name)"
    else
        log_warn "The runner container resolves ${CACHE_ALIAS} but the cache did not answer at ${probe_url}."
        log_warn "Check the cache unit: systemctl status $(unit_service_name "$(unit_base_cache)")"
    fi
    log_warn "Workflows that use 'container:' cannot use the internal cache URL at all; if this stack"
    log_warn "needs them, reinstall with GHR_CACHE_MODE=host so the cache is published on the host."
}

# ------------------------------------------------------------------------------
# Status Reporting
# ------------------------------------------------------------------------------
print_stack_status() {
    printf "\n================ Stack Status ================\n"
    printf "Install Directory : %s\n" "$INSTALL_DIR"
    printf "Project           : %s\n" "$PROJECT_NAME"
    printf "Quadlet Units     : %s/%s-{cache,runner-*}.container\n" "$QUADLET_DIR" "$PROJECT_NAME"

    printf "\nsystemd units:\n"
    local base=""
    while IFS= read -r base; do
        [ -n "$base" ] || continue
        printf "  %-46s %-12s %s\n" "$(unit_service_name "$base")" "$(unit_active_state "$base")" "$(unit_enabled_state "$base")"
    done < <(all_unit_bases)

    printf "\ncontainers:\n"
    while IFS= read -r base; do
        [ -n "$base" ] || continue
        printf "  %-46s %s\n" "$base" "$(container_state "$base")"
    done < <(all_unit_bases)

    printf "\nrunners:\n"
    local i=1
    while [ "$i" -le "$RUNNER_COUNT" ]; do
        local pos=$((i - 1))
        local state=""
        if [ "${#RUNNER_STATUS_ARRAY[@]}" -gt 0 ] && [ -n "${RUNNER_STATUS_ARRAY[pos]:-}" ]; then
            state="${RUNNER_STATUS_ARRAY[pos]}"
        else
            state="$(classify_registration_logs "$(unit_base_runner "$i")")"
        fi
        local text=""
        text="$(registration_state_text "$state")"
        case "$state" in
            OK_*) printf "  Runner #%d: ${COLOR_GREEN}%s${COLOR_RESET} (%s)\n" "$i" "$text" "${RUNNER_URLS[pos]}" ;;
            FAIL_*) printf "  Runner #%d: ${COLOR_RED}%s${COLOR_RESET} (%s)\n" "$i" "$text" "${RUNNER_URLS[pos]}" ;;
            *) printf "  Runner #%d: ${COLOR_YELLOW}%s${COLOR_RESET} (%s)\n" "$i" "$text" "${RUNNER_URLS[pos]}" ;;
        esac
        printf "    Unit    : %s\n" "$(unit_service_name "$(unit_base_runner "$i")")"
        printf "    Logs    : journalctl -u %s -f\n" "$(unit_service_name "$(unit_base_runner "$i")")"
        printf "    Settings: %s\n" "$(derive_settings_url "${RUNNER_URLS[pos]}")"
        i=$((i + 1))
    done

    printf "\nmanage this stack with systemd:\n"
    printf "  systemctl list-units '%s-*' --all\n" "$PROJECT_NAME"
    printf "  %s --dir %s --status|--start|--stop|--restart|--upgrade\n" "$(installer_command)" "$INSTALL_DIR"
    printf "==============================================\n"
}

# ------------------------------------------------------------------------------
# Lifecycle Actions
# ------------------------------------------------------------------------------
action_status() {
    load_stack_config
    print_stack_status
}

action_start() {
    load_stack_config
    ensure_network
    verify_generated_units
    start_all_units
    print_stack_status
}

action_stop() {
    load_stack_config
    stop_all_units
    print_stack_status
}

action_restart() {
    load_stack_config
    ensure_network
    verify_generated_units
    restart_all_units
    wait_for_registrations
    print_stack_status
}

action_upgrade() {
    load_stack_config
    pull_images
    verify_generated_units
    restart_all_units
    wait_for_registrations
    print_stack_status
}

# ------------------------------------------------------------------------------
# Uninstall
# ------------------------------------------------------------------------------
stack_unit_filenames() {
    as_root ls -1 "$QUADLET_DIR" 2>/dev/null | grep -E "^${PROJECT_NAME}-(runner-[0-9]+|cache)\.container$" || true
}

remove_stack_units() {
    local existing=""
    existing="$(stack_unit_filenames)"

    if [ -z "$existing" ]; then
        log_info "No Quadlet unit file for ${PROJECT_NAME} found in ${QUADLET_DIR}."
        return 0
    fi

    local name=""
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        log_info "Removing Quadlet unit ${QUADLET_DIR}/${name}"
        as_root rm -f "${QUADLET_DIR}/${name}"
        rm -f "$(env_dir_path)/${name%.container}.env"
    done <<< "$existing"
}

remove_stack_containers() {
    # Quadlet keeps containers in a stopped state; the objects are removed here so
    # a later reinstall starts from a clean Podman state.
    local base=""
    while IFS= read -r base; do
        [ -n "$base" ] || continue
        if run_podman rm -f "$base" >/dev/null 2>&1; then
            log_info "Removed container ${base}."
        fi
    done < <(all_unit_bases)

    local net=""
    net="$(stack_network_name)"
    if run_podman network rm "$net" >/dev/null 2>&1; then
        log_info "Removed Podman network ${net}."
    fi
}

# confirm_destructive <env_value> <prompt> - destructive steps stay opt-in: they
# require GHR_UNINSTALL_*=yes or an explicit interactive confirmation.
confirm_destructive() {
    local env_value="$1"
    local prompt_msg="$2"

    if [ "$env_value" = "yes" ]; then
        return 0
    fi
    if [ "$NON_INTERACTIVE" = true ]; then
        return 1
    fi
    prompt_confirm "$prompt_msg" "N"
}

remove_stack_volumes() {
    local i=1
    local volume=""
    while [ "$i" -le "$RUNNER_COUNT" ]; do
        volume="$(runner_volume_name "$i")"
        if run_podman volume rm "$volume" >/dev/null 2>&1; then
            log_info "Removed volume ${volume}."
        fi
        i=$((i + 1))
    done

    if [ "$CACHE_ENABLED" = true ]; then
        volume="$(cache_volume_name)"
        if run_podman volume rm "$volume" >/dev/null 2>&1; then
            log_info "Removed volume ${volume}."
        fi
    fi
}

remove_stack_workdirs() {
    local i=1
    local pos=0
    local workdir=""
    while [ "$i" -le "$RUNNER_COUNT" ]; do
        pos=$((i - 1))
        workdir="${RUNNER_WORKDIR_LIST[pos]}"
        # An empty or root path in a hand-edited .env must never reach rm -rf.
        if [ -n "$workdir" ] && [ "$workdir" != "/" ]; then
            log_info "Removing workspace ${workdir}"
            as_root rm -rf "$workdir"
        fi
        i=$((i + 1))
    done
}

action_uninstall() {
    load_stack_config

    printf "\n================ Uninstall ================\n"
    printf "Project     : %s\n" "$PROJECT_NAME"
    printf "Quadlet Unit: %s/%s-*.container\n" "$QUADLET_DIR" "$PROJECT_NAME"
    printf "Configuration %s/.env is kept.\n" "$INSTALL_DIR"
    printf "===========================================\n"

    if [ "$NON_INTERACTIVE" = false ]; then
        if ! prompt_confirm "Stop and remove the stack ${PROJECT_NAME}?" "N"; then
            log_info "Uninstall aborted by user."
            exit 0
        fi
    fi

    stop_all_units
    remove_stack_units
    daemon_reload
    remove_stack_containers

    if confirm_destructive "${GHR_UNINSTALL_VOLUMES:-no}" "Delete the runner and cache data volumes?"; then
        remove_stack_volumes
    else
        log_info "Data volumes kept (runner credentials and cache data survive a reinstall)."
    fi

    if confirm_destructive "${GHR_UNINSTALL_WORKDIR:-no}" "Delete the job workspace directories?"; then
        remove_stack_workdirs
    else
        log_info "Job workspaces kept under ${INSTALL_DIR}/work."
    fi

    log_info "Uninstall complete. Units and containers are gone; configuration remains in ${INSTALL_DIR}/.env."
    log_info "Recreate the stack with: $(installer_command) --dir ${INSTALL_DIR}"
}

# ------------------------------------------------------------------------------
# Usage / Help
# ------------------------------------------------------------------------------
show_help() {
    cat <<EOF
GitHub Actions Runner & Cache Server Installer (Podman + systemd) v${INSTALLER_VERSION}

Deploys the runner stack as Quadlet units in ${DEFAULT_QUADLET_DIR}/, so systemd
starts the containers on boot and owns their lifecycle (no Compose project).

Usage:
  install-podman.sh [OPTIONS]
  curl -fsSL https://raw.githubusercontent.com/${REPO_SLUG}/main/install-podman.sh | sudo bash -s -- [OPTIONS]

Requirements:
  Linux host with systemd as PID 1, Podman >= ${MIN_PODMAN_VERSION} (Quadlet support)
  and root privileges (rootful Podman, system-level units).

Options:
  --dir <path>             Installation directory (default: /opt/github-runner for root, \$HOME/github-runner otherwise)
  --instances <count>      Number of runner instances per target (default: 1)
  --non-interactive        Run without interactive prompts (reads GHR_* environment variables)
  --no-start               Generate configuration and units only (skip pull & start)
  --skip-podman-install    Do not attempt to install Podman automatically
  --uninstall              Stop the stack, remove its units and containers (keeps .env by default)
  --status                 Print systemd, container and registration status of the stack
  --start                  Start the whole stack
  --stop                   Stop the whole stack
  --restart                Restart the whole stack and re-check runner registration
  --upgrade                Pull the configured images and restart the stack on the new images
  --debug                  Enable verbose debug output (or set GHR_DEBUG=1)
  -h, --help               Show this help message and exit

Non-Interactive Environment Variables:
  GHR_RUNNER_1_URL         GitHub repository or organization URL for runner 1
  GHR_RUNNER_1_TOKEN       GitHub registration token for runner 1
  GHR_RUNNER_1_LABELS      Optional comma-separated labels (default: ${DEFAULT_LABELS})
  GHR_RUNNER_1_NAME_PREFIX Optional runner name prefix (default derived from URL)
  GHR_RUNNER_1_INSTANCES   Number of concurrent runner instances for runner 1 (default: 1)
  GHR_RUNNER_1_WORKDIR     Optional job workspace path (default: <dir>/work/runner-<n>)
  GHR_RUNNER_2_URL         (Optional) Additional runner URL
  GHR_RUNNER_2_TOKEN       (Optional) Additional runner token
  GHR_RUNNER_INSTANCES     Default number of concurrent instances for each runner target (default: 1)
  GHR_INSTANCES            Global shorthand for runner instances per target (default: 1)
  GHR_CACHE                Enable cache server: 1 (default) or 0
  GHR_CACHE_MODE           Cache mode: internal (default, Podman network DNS) or host (published host port)
  GHR_CACHE_URL            Base cache server URL (default: http://${CACHE_ALIAS}:${CACHE_CONTAINER_PORT})
  GHR_CACHE_PORT           Published host port for the cache server in host mode
  GHR_CACHE_CLEANUP_DAYS   Cache entries older than this many days are cleaned up (default: 90)
  GHR_CACHE_MAX_USAGE_PERCENT  Filesystem usage percentage that triggers a cache cleanup (default: 90)
  GHR_IMAGE                Custom runner container image
  GHR_CACHE_IMAGE          Custom cache server container image (default: ${DEFAULT_CACHE_IMAGE})
  GHR_INSTALL_PODMAN       Allow automatic Podman install: yes (default) or no
  GHR_MODE                 Install mode: new (default), add, or reconfigure
  GHR_QUADLET_DIR          Override the Quadlet unit directory (default: ${DEFAULT_QUADLET_DIR})
  GHR_PODMAN_SOCKET        Socket mounted into the runner container (default: ${DEFAULT_PODMAN_SOCKET}, empty disables the mount)
  GHR_SELINUX              Set to 1 to keep SELinux labels on the mounted socket
  GHR_SKIP_EGRESS_CHECK    Set to yes to skip the pre-start container egress check
  GHR_UNINSTALL_VOLUMES    With --uninstall: set to 'yes' to delete volumes without prompt
  GHR_UNINSTALL_WORKDIR    With --uninstall: set to 'yes' to delete job workspaces without prompt

Exit Codes:
  0   Success
  1   General error (including runners that failed to register)
  2   Usage / argument error
EOF
}

# ------------------------------------------------------------------------------
# Argument Parsing
# ------------------------------------------------------------------------------
set_action() {
    local requested="$1"
    if [ "$ACTION" != "install" ] && [ "$ACTION" != "$requested" ]; then
        log_error "Only one action can be requested at a time (already set: --${ACTION})."
        exit 2
    fi
    ACTION="$requested"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dir)
                if [ -n "${2:-}" ]; then
                    INSTALL_DIR="$(sanitize_and_resolve_dir "$2")" || exit 1
                    shift 2
                else
                    log_error "--dir requires a path argument."
                    exit 2
                fi
                ;;
            --instances|--concurrency)
                if [ -n "${2:-}" ] && [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
                    GHR_INSTANCES="$2"
                    shift 2
                else
                    log_error "--instances requires a positive integer argument."
                    exit 2
                fi
                ;;
            --non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            --no-start)
                NO_START=true
                shift
                ;;
            --skip-podman-install)
                SKIP_PODMAN_INSTALL=true
                shift
                ;;
            --uninstall)
                set_action "uninstall"
                shift
                ;;
            --status)
                set_action "status"
                shift
                ;;
            --start)
                set_action "start"
                shift
                ;;
            --stop)
                set_action "stop"
                shift
                ;;
            --restart)
                set_action "restart"
                shift
                ;;
            --upgrade)
                set_action "upgrade"
                shift
                ;;
            --debug)
                DEBUG_MODE=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 2
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Main Flow
# ------------------------------------------------------------------------------
require_podman_for_action() {
    if have podman; then
        return 0
    fi
    log_error "Podman is not installed, so '--${ACTION}' cannot be executed."
    log_error "Install Podman >= ${MIN_PODMAN_VERSION}, then re-run this command."
    exit 1
}

print_no_start_next_steps() {
    log_info "Configuration and Quadlet units are ready (--no-start: nothing was started)."

    printf "\nstart the stack:\n"
    local i=1
    while [ "$i" -le "$RUNNER_COUNT" ]; do
        printf "  sudo systemctl start %s\n" "$(unit_service_name "$(unit_base_runner "$i")")"
        i=$((i + 1))
    done
    if [ "$CACHE_ENABLED" = true ]; then
        printf "  sudo systemctl start %s\n" "$(unit_service_name "$(unit_base_cache)")"
    fi
    printf "\ninspect the stack:\n"
    printf "  %s --dir %s --status\n" "$(installer_command)" "$INSTALL_DIR"
    printf "  journalctl -u %s -f\n" "$(unit_service_name "$(unit_base_runner 1)")"
}

run_install() {
    # Interactive mode needs a terminal to ask questions on; the test suite opts
    # out with GHR_PROMPT_STDIN=1 and scripts the conversation through a pipe.
    if [ "$NON_INTERACTIVE" = false ] && [ "${GHR_PROMPT_STDIN:-0}" != "1" ] \
        && [ ! -t 0 ] && ! tty_available; then
        log_error "Standard input is not a terminal and /dev/tty is unusable. Use --non-interactive mode."
        exit 1
    fi

    step_header "1/5" "Checking the environment"
    verify_environment

    step_header "2/5" "Collecting configuration"
    if [ "$NON_INTERACTIVE" = true ]; then
        collect_non_interactive_config
        print_config_summary
    else
        collect_interactive_config
    fi

    step_header "3/5" "Writing configuration and Quadlet units"
    write_files

    if [ "$NO_START" = true ]; then
        step_header "4/5" "Registering units with systemd"
        daemon_reload
        verify_generated_units

        step_header "5/5" "Starting the stack (skipped: --no-start)"
        print_no_start_next_steps
        log_info "Installer completed successfully."
        return 0
    fi

    step_header "4/5" "Preparing images and network"
    ensure_network
    pull_images
    verify_container_egress

    step_header "5/5" "Starting and verifying the stack"
    daemon_reload
    verify_generated_units
    start_all_units
    wait_for_registrations
    verify_cache_reachability
    print_stack_status

    if [ "${FAILED_RUNNERS_COUNT:-0}" -gt 0 ]; then
        log_warn "Installer completed with ${FAILED_RUNNERS_COUNT} failed runner(s)."
        if runner_status_contains FAIL_EGRESS; then
            log_warn "At least one runner cannot reach the GitHub API: fix host forwarding or DNS"
            log_warn "(see the egress diagnostics above) and re-run the same command:"
        else
            log_warn "Fix the token or URL in this order and re-run the same command:"
            log_warn "  sed -n '1,99p' ${INSTALL_DIR}/.env"
        fi
        log_warn "  $(installer_command) --dir ${INSTALL_DIR}"
        exit 1
    fi

    log_info "Installer completed successfully."
}

run_lifecycle() {
    step_header "1/2" "Checking the environment"
    detect_system
    if [ "$ACTION" != "status" ]; then
        require_podman_for_action
    fi

    step_header "2/2" "Running --${ACTION}"
    case "$ACTION" in
        status) action_status ;;
        start) action_start ;;
        stop) action_stop ;;
        restart) action_restart ;;
        upgrade) action_upgrade ;;
        uninstall) action_uninstall ;;
    esac
}

main() {
    parse_args "$@"

    print_banner

    case "$ACTION" in
        install) run_install ;;
        uninstall|status|start|stop|restart|upgrade) run_lifecycle ;;
        *)
            log_error "Unsupported action: ${ACTION}"
            exit 2
            ;;
    esac
}

main "$@"
