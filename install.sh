#!/usr/bin/env bash
# ==============================================================================
# GitHub Actions Runner & Cache Server One-Line Installer
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install.sh | bash
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Global Defaults and State
# ------------------------------------------------------------------------------
INSTALLER_VERSION="1.0.0"
DEFAULT_IMAGE="ghcr.io/bestony/self-hosted-action-runner:latest"
DEFAULT_CACHE_IMAGE="ghcr.io/falcondev-oss/github-actions-cache-server:9.8.0"

INSTALL_DIR=""
NON_INTERACTIVE=false
NO_START=false
SKIP_DOCKER_INSTALL=false
DO_UNINSTALL=false
DEBUG_MODE=false

DOCKER="docker"
SUDO=""

docker_exec() {
    if [ "$DOCKER" = "sudo docker" ]; then
        sudo docker "$@"
    else
        docker "$@"
    fi
}

# Configuration values
RUNNER_COUNT=0
declare -a RUNNER_URLS=()
declare -a RUNNER_TOKENS=()
declare -a RUNNER_LABELS=()
declare -a RUNNER_PREFIXES=()
declare -a RUNNER_WORKDIR_LIST=()

CACHE_ENABLED=true
CACHE_URL="http://cache-server:3000"
CACHE_PORT=3000
RUNNER_IMAGE="${DEFAULT_IMAGE}"

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
# Logging Functions
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
        local tail="${token: -4}"
        echo "******${tail}"
    fi
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
        printf "%b┌────────────────────────────────────────────────────────────────────────────┐%b\n" "${COLOR_BLUE}" "${COLOR_RESET}"
        printf "%b│%b %bProject%b : GitHub Actions Self-Hosted Runner Stack                          %b│%b\n" "${COLOR_BLUE}" "${COLOR_RESET}" "${COLOR_BOLD}" "${COLOR_RESET}" "${COLOR_BLUE}" "${COLOR_RESET}"
        printf "%b│%b %bRepo%b    : https://github.com/bestony/self-hosted-action-runner             %b│%b\n" "${COLOR_BLUE}" "${COLOR_RESET}" "${COLOR_BOLD}" "${COLOR_RESET}" "${COLOR_BLUE}" "${COLOR_RESET}"
        printf "%b│%b %bVersion%b : v%-64s %b│%b\n" "${COLOR_BLUE}" "${COLOR_RESET}" "${COLOR_BOLD}" "${COLOR_RESET}" "${INSTALLER_VERSION}" "${COLOR_BLUE}" "${COLOR_RESET}"
        printf "%b│%b %bImage%b   : %-66s %b│%b\n" "${COLOR_BLUE}" "${COLOR_RESET}" "${COLOR_BOLD}" "${COLOR_RESET}" "${DEFAULT_IMAGE}" "${COLOR_BLUE}" "${COLOR_RESET}"
        printf "%b│%b %bDocs%b    : https://github.com/bestony/self-hosted-action-runner#readme      %b│%b\n" "${COLOR_BLUE}" "${COLOR_RESET}" "${COLOR_BOLD}" "${COLOR_RESET}" "${COLOR_BLUE}" "${COLOR_RESET}"
        printf "%b└────────────────────────────────────────────────────────────────────────────┘%b\n" "${COLOR_BLUE}" "${COLOR_RESET}"
    else
        printf "\n+----------------------------------------------------------------------------+\n"
        printf "| Project : GitHub Actions Self-Hosted Runner Stack                          |\n"
        printf "| Repo    : https://github.com/bestony/self-hosted-action-runner             |\n"
        printf "| Version : v%-64s |\n" "${INSTALLER_VERSION}"
        printf "| Image   : %-66s |\n" "${DEFAULT_IMAGE}"
        printf "| Docs    : https://github.com/bestony/self-hosted-action-runner#readme      |\n"
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

LOG_FILE=""
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

trap 'cleanup_spinner; exit 130' SIGINT SIGTERM

init_log_file() {
    if [ -z "$LOG_FILE" ]; then
        if [ -n "$INSTALL_DIR" ] && [ -d "$INSTALL_DIR" ]; then
            LOG_FILE="${INSTALL_DIR}/install.log"
        else
            LOG_FILE="$(mktemp /tmp/ghr-install-XXXXXX.log 2>/dev/null || echo "/tmp/ghr-install.log")"
        fi
        touch "$LOG_FILE"
    fi
}

run_with_spinner() {
    local label="$1"
    shift
    init_log_file

    local start_time=$SECONDS

    # Execute command in background, appending output to log file
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
            spin_idx=$(( (spin_idx + 1) % 10 ))
            sleep 0.1
        done
        printf "\033[?25h"
    else
        printf "  ... %s\n" "$label"
        local last_notice=0
        while kill -0 "$cmd_pid" 2>/dev/null; do
            sleep 1
            local elapsed=$((SECONDS - start_time))
            if [ $((elapsed - last_notice)) -ge 10 ] && kill -0 "$cmd_pid" 2>/dev/null; then
                printf "  ... still running (%ds)\n" "$elapsed"
                last_notice="$elapsed"
            fi
        done
    fi

    wait "$cmd_pid"
    local ec=$?
    CURRENT_SPINNER_PID=""
    local total_elapsed=$((SECONDS - start_time))

    if [ "$ec" -eq 0 ]; then
        if [ "$is_interactive_tty" = true ]; then
            printf "\r${COLOR_GREEN}✓${COLOR_RESET} %s (%ds)\033[K\n" "$label" "$total_elapsed"
        else
            printf "  ✓ %s (%ds)\n" "$label" "$total_elapsed"
        fi
        return 0
    else
        if [ "$is_interactive_tty" = true ]; then
            printf "\r${COLOR_RED}✗${COLOR_RESET} %s (failed after %ds)\033[K\n" "$label" "$total_elapsed"
        else
            printf "  ✗ %s (failed after %ds)\n" "$label" "$total_elapsed"
        fi
        log_error "Command failed with exit code ${ec}."
        log_error "Last 30 lines of log (${LOG_FILE}):"
        tail -n 30 "$LOG_FILE" >&2 || true
        return "$ec"
    fi
}

# ------------------------------------------------------------------------------
# Input & TTY Helpers
# ------------------------------------------------------------------------------
prompt_input() {
    local prompt_msg="$1"
    local default_val="${2:-}"
    local result=""

    if [ -n "$default_val" ]; then
        printf "${COLOR_BOLD}%s [default: %s]: ${COLOR_RESET}" "$prompt_msg" "$default_val" >&2
    else
        printf "${COLOR_BOLD}%s: ${COLOR_RESET}" "$prompt_msg" >&2
    fi

    if [ -c /dev/tty ]; then
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

    if [ -c /dev/tty ]; then
        read -r -s result </dev/tty || true
        printf "\n" >&2
    else
        read -r -s result || true
        printf "\n" >&2
    fi

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

    if [ -c /dev/tty ]; then
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
# System Detection & Preflight Checks
# ------------------------------------------------------------------------------
detect_system() {
    OS="$(uname -s)"
    ARCH="$(uname -m)"
    export IS_WSL=false

    case "$OS" in
        Linux)
            if [ -f /proc/version ] && grep -qiE "microsoft|wsl" /proc/version 2>/dev/null; then
                IS_WSL=true
                log_debug "Detected WSL environment."
                log_info "WSL environment detected. For best performance, Docker Desktop with WSL 2 integration is recommended."
            fi
            ;;
        Darwin)
            log_debug "Detected macOS environment."
            ;;
        *)
            log_error "Unsupported operating system: $OS. Linux and macOS are supported."
            exit 1
            ;;
    esac

    # Determine sudo requirements
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        else
            log_warn "Running as non-root and sudo is not installed. Some operations may require root privileges."
            SUDO=""
        fi
    else
        SUDO=""
    fi
}

detect_host_ip() {
    local detected_ip=""
    if [ "$OS" = "Darwin" ]; then
        detected_ip="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
        if [ -z "$detected_ip" ]; then
            detected_ip="$(ifconfig 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | head -n 1 || true)"
        fi
    else
        detected_ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' || true)"
        if [ -z "$detected_ip" ]; then
            detected_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
        fi
    fi
    echo "$detected_ip"
}

ensure_dependencies() {
    log_info "Performing preflight dependency checks..."

    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl is required but not installed. Please install curl and re-run."
        exit 1
    fi

    # 1. Check Docker CLI
    if ! command -v docker >/dev/null 2>&1; then
        if [ "$SKIP_DOCKER_INSTALL" = true ]; then
            log_error "Docker is not installed and --skip-docker-install was specified."
            exit 1
        fi

        log_warn "Docker is not installed."
        if [ "$OS" = "Linux" ]; then
            local do_install=false
            if [ "$NON_INTERACTIVE" = true ]; then
                if [ "${GHR_INSTALL_DOCKER:-yes}" = "yes" ]; then
                    do_install=true
                else
                    log_error "Docker is missing and GHR_INSTALL_DOCKER is set to '${GHR_INSTALL_DOCKER:-no}'."
                    exit 1
                fi
            else
                if prompt_confirm "Install Docker now via official script (get.docker.com)?" "Y"; then
                    do_install=true
                else
                    log_error "Docker is required to run the GitHub Actions runner stack."
                    exit 1
                fi
            fi

            if [ "$do_install" = true ]; then
                log_info "Installing Docker via https://get.docker.com..."
                run_with_spinner "Installing Docker Engine and Compose plugin" bash -c 'unset VERSION 2>/dev/null || true; curl -fsSL https://get.docker.com | env -u VERSION '"$SUDO"' sh'

                # Start docker service if possible
                if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
                    $SUDO systemctl enable --now docker || true
                elif command -v service >/dev/null 2>&1; then
                    $SUDO service docker start || true
                fi

                # Offer adding user to docker group if non-root
                if [ "$(id -u)" -ne 0 ] && [ -n "${USER:-}" ]; then
                    log_info "Adding ${USER} to docker group..."
                    $SUDO usermod -aG docker "$USER" 2>/dev/null || true
                    log_info "Note: Re-login is required for docker group membership. Using sudo for Docker in current session."
                fi
            fi
        elif [ "$OS" = "Darwin" ]; then
            if command -v brew >/dev/null 2>&1; then
                if [ "$NON_INTERACTIVE" = true ]; then
                    log_error "Docker is not installed on macOS. Install Docker Desktop manually or run interactively."
                    exit 1
                fi
                if prompt_confirm "Docker is not installed. Install Docker Desktop using Homebrew?" "Y"; then
                    brew install --cask docker
                    log_info "Docker Desktop installed. Launching Docker Desktop..."
                    open -a Docker || true
                    log_info "Waiting for Docker daemon to become responsive (up to 3 minutes)..."
                    local waited=0
                    while [ "$waited" -lt 180 ]; do
                        if docker info >/dev/null 2>&1; then
                            log_info "Docker daemon is ready."
                            break
                        fi
                        sleep 3
                        waited=$((waited + 3))
                    done
                else
                    log_error "Docker is required. Please download Docker Desktop from https://www.docker.com/products/docker-desktop/"
                    exit 1
                fi
            else
                log_error "Docker is not installed. Please download Docker Desktop from https://www.docker.com/products/docker-desktop/"
                exit 1
            fi
        fi
    fi

    # 2. Check Docker Compose v2 plugin
    if ! docker compose version >/dev/null 2>&1 && ! ($SUDO docker compose version >/dev/null 2>&1); then
        log_warn "Docker Compose v2 plugin ('docker compose') is missing."
        if [ "$OS" = "Linux" ]; then
            log_info "Attempting to install docker-compose-plugin..."
            local installed_compose=false

            if command -v apt-get >/dev/null 2>&1; then
                run_with_spinner "Installing docker-compose-plugin via apt" bash -c "$SUDO apt-get update -qq && $SUDO apt-get install -y -qq docker-compose-plugin" && installed_compose=true || true
            elif command -v dnf >/dev/null 2>&1; then
                run_with_spinner "Installing docker-compose-plugin via dnf" bash -c "$SUDO dnf install -y -q docker-compose-plugin" && installed_compose=true || true
            elif command -v yum >/dev/null 2>&1; then
                run_with_spinner "Installing docker-compose-plugin via yum" bash -c "$SUDO yum install -y -q docker-compose-plugin" && installed_compose=true || true
            fi

            if [ "$installed_compose" = false ]; then
                log_info "Downloading standalone docker-compose CLI plugin binary from GitHub releases..."
                local c_arch="$ARCH"
                case "$ARCH" in
                    x86_64) c_arch="x86_64" ;;
                    aarch64|arm64) c_arch="aarch64" ;;
                    *) c_arch="$ARCH" ;;
                esac
                local plugin_dir="/usr/local/lib/docker/cli-plugins"
                $SUDO mkdir -p "$plugin_dir"
                run_with_spinner "Downloading standalone docker-compose binary" bash -c "$SUDO curl -fsSL 'https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${c_arch}' -o '${plugin_dir}/docker-compose' && $SUDO chmod +x '${plugin_dir}/docker-compose'"
            fi
        fi
    fi

    # 3. Determine how to invoke Docker (docker vs sudo docker)
    if docker info >/dev/null 2>&1; then
        DOCKER="docker"
    elif [ -n "$SUDO" ] && $SUDO docker info >/dev/null 2>&1; then
        DOCKER="$SUDO docker"
    else
        # Daemon is not responding
        log_warn "Docker daemon is not responding to 'docker info'."
        if [ "$OS" = "Linux" ]; then
            log_info "Attempting to start Docker daemon..."
            if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
                run_with_spinner "Starting Docker daemon service" $SUDO systemctl start docker || true
            elif command -v service >/dev/null 2>&1; then
                run_with_spinner "Starting Docker daemon service" $SUDO service docker start || true
            fi
        elif [ "$OS" = "Darwin" ]; then
            log_info "Attempting to launch Docker Desktop..."
            open -a Docker 2>/dev/null || true
            log_info "Waiting for Docker daemon (up to 3 minutes)..."
            local waited=0
            while [ "$waited" -lt 180 ]; do
                if docker info >/dev/null 2>&1; then
                    break
                fi
                sleep 3
                waited=$((waited + 3))
            done
        fi

        # Check again
        if docker info >/dev/null 2>&1; then
            DOCKER="docker"
        elif [ -n "$SUDO" ] && $SUDO docker info >/dev/null 2>&1; then
            DOCKER="$SUDO docker"
        else
            if [ "$NO_START" = true ]; then
                log_warn "Docker daemon is not running. Proceeding because --no-start is specified (file generation only)."
                DOCKER="docker"
            else
                log_error "Docker daemon is not running and cannot be reached. Please start Docker and re-run."
                exit 1
            fi
        fi
    fi

    log_info "Docker environment verified ($DOCKER)."
}

# ------------------------------------------------------------------------------
# URL & Token Validation Helpers
# ------------------------------------------------------------------------------
validate_runner_url() {
    local url="$1"
    # Canonical GitHub repo or org URL
    if [[ "$url" =~ ^https://github\.com/[^/[:space:]]+(/[^/[:space:]]+)?/?$ ]]; then
        return 0
    fi
    # Also support GitHub Enterprise Server (any https host)
    if [[ "$url" =~ ^https://[^/[:space:]]+/[^/[:space:]]+(/[^/[:space:]]+)?/?$ ]]; then
        return 2
    fi
    return 1
}

derive_prefix_from_url() {
    local url="$1"
    # Remove trailing slash
    url="${url%/}"
    local name
    name="$(basename "$url" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-' | sed 's/-*$//')"
    echo "${name}-"
}

# ------------------------------------------------------------------------------
# Configuration Collection (Interactive & Non-Interactive)
# ------------------------------------------------------------------------------
load_existing_env() {
    local env_file="$1"
    if [ ! -f "$env_file" ]; then
        return 1
    fi

    log_info "Existing configuration found in ${env_file}."
    local count
    count="$(grep -E '^RUNNER_COUNT=' "$env_file" 2>/dev/null | cut -d= -f2 || echo 0)"

    if [ -n "$count" ] && [ "$count" -gt 0 ]; then
        printf "Configured runners:\n"
        local i=1
        while [ "$i" -le "$count" ]; do
            local r_url r_prefix
            r_url="$(grep -E "^RUNNER_${i}_URL=" "$env_file" 2>/dev/null | cut -d= -f2- || true)"
            r_prefix="$(grep -E "^RUNNER_${i}_NAME_PREFIX=" "$env_file" 2>/dev/null | cut -d= -f2- || true)"
            printf "  - Runner %d: %s (Prefix: %s)\n" "$i" "${r_url:-<unset>}" "${r_prefix:-<default>}"
            i=$((i + 1))
        done
        return 0
    fi
    return 1
}

collect_interactive_config() {
    # 1. Installation directory
    local default_dir
    if [ "$(id -u)" -eq 0 ]; then
        default_dir="/opt/github-runner"
    else
        default_dir="${HOME}/github-runner"
    fi

    if [ -z "$INSTALL_DIR" ]; then
        INSTALL_DIR="$(prompt_input "Enter installation directory" "$default_dir")"
    fi
    # Expand ~ or relative paths
    INSTALL_DIR="$(cd "$(dirname "$INSTALL_DIR")" 2>/dev/null && pwd)/$(basename "$INSTALL_DIR")" || INSTALL_DIR="$default_dir"
    mkdir -p "$INSTALL_DIR"

    local env_file="${INSTALL_DIR}/.env"
    local mode="new"

    if [ -f "$env_file" ]; then
        load_existing_env "$env_file" || true
        printf "\n"
        local action
        action="$(prompt_input "Choose action: [A]dd runners / [R]econfigure from scratch / [Q]uit" "A")"
        case "$action" in
            [Aa]*)
                mode="add"
                ;;
            [Rr]*)
                mode="reconfigure"
                ;;
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

    if [ "$mode" = "add" ] && [ -f "$env_file" ]; then
        # Read existing runners
        local existing_count
        existing_count="$(grep -E '^RUNNER_COUNT=' "$env_file" 2>/dev/null | cut -d= -f2 || echo 0)"
        RUNNER_COUNT="$existing_count"

        local i=1
        while [ "$i" -le "$existing_count" ]; do
            RUNNER_URLS+=("$(grep -E "^RUNNER_${i}_URL=" "$env_file" | cut -d= -f2-)")
            RUNNER_TOKENS+=("$(grep -E "^RUNNER_${i}_TOKEN=" "$env_file" | cut -d= -f2-)")
            RUNNER_PREFIXES+=("$(grep -E "^RUNNER_${i}_NAME_PREFIX=" "$env_file" | cut -d= -f2-)")
            RUNNER_LABELS+=("$(grep -E "^RUNNER_${i}_LABELS=" "$env_file" | cut -d= -f2-)")
            RUNNER_WORKDIR_LIST+=("$(grep -E "^RUNNER_${i}_WORKDIR=" "$env_file" | cut -d= -f2-)")
            i=$((i + 1))
        done

        local c_enabled
        c_enabled="$(grep -E '^CACHE_ENABLED=' "$env_file" 2>/dev/null | cut -d= -f2 || echo true)"
        if [ "$c_enabled" = "false" ]; then
            CACHE_ENABLED=false
        else
            CACHE_ENABLED=true
        fi
        CACHE_URL="$(grep -E '^CACHE_URL=' "$env_file" 2>/dev/null | cut -d= -f2- || echo 'http://cache-server:3000')"
        CACHE_PORT="$(grep -E '^CACHE_PORT=' "$env_file" 2>/dev/null | cut -d= -f2 || echo 3000)"
        RUNNER_IMAGE="$(grep -E '^RUNNER_IMAGE=' "$env_file" 2>/dev/null | cut -d= -f2- || echo "$DEFAULT_IMAGE")"
    else
        RUNNER_COUNT=0
        RUNNER_URLS=()
        RUNNER_TOKENS=()
        RUNNER_PREFIXES=()
        RUNNER_LABELS=()
        RUNNER_WORKDIR_LIST=()
    fi

    # Runner collection loop
    local adding=true
    while [ "$adding" = true ]; do
        local runner_num=$((RUNNER_COUNT + 1))
        printf "\n--- Configuring Runner #%d ---\n" "$runner_num"

        # URL
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

        # Token
        local r_token=""
        while true; do
            r_token="$(prompt_secret "GitHub Runner Registration Token")"
            if [ -z "$r_token" ]; then
                log_error "Registration token cannot be empty."
                continue
            fi
            break
        done

        # Name prefix
        local default_prefix
        default_prefix="$(derive_prefix_from_url "$r_url")"
        local r_prefix
        r_prefix="$(prompt_input "Runner name prefix" "$default_prefix")"

        # Labels
        local r_labels
        r_labels="$(prompt_input "Runner labels (comma-separated)" "self-hosted,linux,docker")"

        # Workdir
        local r_workdir="${INSTALL_DIR}/work/runner-${runner_num}"

        RUNNER_URLS+=("$r_url")
        RUNNER_TOKENS+=("$r_token")
        RUNNER_PREFIXES+=("$r_prefix")
        RUNNER_LABELS+=("$r_labels")
        RUNNER_WORKDIR_LIST+=("$r_workdir")
        RUNNER_COUNT="$runner_num"

        if ! prompt_confirm "Add another repository/org runner?" "N"; then
            adding=false
        fi
    done

    # Cache server configuration
    if [ "$mode" != "add" ]; then
        printf "\n--- Cache Server Configuration ---\n"
        if prompt_confirm "Enable shared GitHub Actions cache server?" "Y"; then
            CACHE_ENABLED=true
            printf "Note: Normal runner steps reach cache via internal Docker DNS (http://cache-server:3000).\n"
            printf "Jobs using 'container:' or service containers run on host network and cannot resolve internal DNS.\n"
            local detected_ip
            detected_ip="$(detect_host_ip)"
            local url_mode
            if [ -n "$detected_ip" ]; then
                url_mode="$(prompt_input "Select cache URL mode: [1] Internal (http://cache-server:3000) or [2] Host IP (http://${detected_ip}:3000)" "1")"
            else
                url_mode="$(prompt_input "Select cache URL mode: [1] Internal (http://cache-server:3000)" "1")"
            fi

            if [ "$url_mode" = "2" ] && [ -n "$detected_ip" ]; then
                CACHE_URL="http://${detected_ip}:3000"
            else
                CACHE_URL="http://cache-server:3000"
            fi
            CACHE_PORT=3000
        else
            CACHE_ENABLED=false
        fi

        # Runner image
        RUNNER_IMAGE="$(prompt_input "Runner container image" "$DEFAULT_IMAGE")"
    fi

    # Summary
    printf "\n================ Configuration Summary ================\n"
    printf "Install Directory : %s\n" "$INSTALL_DIR"
    printf "Runner Image      : %s\n" "$RUNNER_IMAGE"
    printf "Cache Server      : %s\n" "$([ "$CACHE_ENABLED" = true ] && echo "Enabled ($CACHE_URL)" || echo "Disabled")"
    printf "Configured Runners: %d\n" "$RUNNER_COUNT"
    local idx=0
    while [ "$idx" -lt "$RUNNER_COUNT" ]; do
        local n=$((idx + 1))
        printf "  [%d] URL   : %s\n" "$n" "${RUNNER_URLS[$idx]}"
        printf "      Token : %s\n" "$(mask_token "${RUNNER_TOKENS[$idx]}")"
        printf "      Prefix: %s\n" "${RUNNER_PREFIXES[$idx]}"
        printf "      Labels: %s\n" "${RUNNER_LABELS[$idx]}"
        printf "      Work  : %s\n" "${RUNNER_WORKDIR_LIST[$idx]}"
        idx=$((idx + 1))
    done
    printf "========================================================\n"

    if ! prompt_confirm "Write configuration and continue?" "Y"; then
        log_info "Aborted by user."
        exit 0
    fi
}

collect_non_interactive_config() {
    # Install directory
    if [ -z "$INSTALL_DIR" ]; then
        if [ "$(id -u)" -eq 0 ]; then
            INSTALL_DIR="/opt/github-runner"
        else
            INSTALL_DIR="${HOME}/github-runner"
        fi
    fi
    mkdir -p "$INSTALL_DIR"
    INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"

    local env_file="${INSTALL_DIR}/.env"
    local mode="${GHR_MODE:-new}"

    if [ "$mode" = "add" ] && [ -f "$env_file" ]; then
        log_info "Non-interactive mode 'add' specified. Reading existing configuration..."
        local existing_count
        existing_count="$(grep -E '^RUNNER_COUNT=' "$env_file" 2>/dev/null | cut -d= -f2 || echo 0)"
        RUNNER_COUNT="$existing_count"

        local i=1
        while [ "$i" -le "$existing_count" ]; do
            RUNNER_URLS+=("$(grep -E "^RUNNER_${i}_URL=" "$env_file" | cut -d= -f2-)")
            RUNNER_TOKENS+=("$(grep -E "^RUNNER_${i}_TOKEN=" "$env_file" | cut -d= -f2-)")
            RUNNER_PREFIXES+=("$(grep -E "^RUNNER_${i}_NAME_PREFIX=" "$env_file" | cut -d= -f2-)")
            RUNNER_LABELS+=("$(grep -E "^RUNNER_${i}_LABELS=" "$env_file" | cut -d= -f2-)")
            RUNNER_WORKDIR_LIST+=("$(grep -E "^RUNNER_${i}_WORKDIR=" "$env_file" | cut -d= -f2-)")
            i=$((i + 1))
        done

        local c_enabled
        c_enabled="$(grep -E '^CACHE_ENABLED=' "$env_file" 2>/dev/null | cut -d= -f2 || echo true)"
        if [ "$c_enabled" = "false" ]; then
            CACHE_ENABLED=false
        else
            CACHE_ENABLED=true
        fi
        CACHE_URL="$(grep -E '^CACHE_URL=' "$env_file" 2>/dev/null | cut -d= -f2- || echo 'http://cache-server:3000')"
        CACHE_PORT="$(grep -E '^CACHE_PORT=' "$env_file" 2>/dev/null | cut -d= -f2 || echo 3000)"
        RUNNER_IMAGE="$(grep -E '^RUNNER_IMAGE=' "$env_file" 2>/dev/null | cut -d= -f2- || echo "$DEFAULT_IMAGE")"
    fi

    # Read runner configurations from environment variables
    # Check if user specified GHR_RUNNER_1_URL or GHR_RUNNER_<next>_URL
    local scan_idx=1
    # If in add mode, check whether GHR_RUNNER_<next>_URL is set or if GHR_RUNNER_1_URL is set
    if [ "$mode" = "add" ]; then
        local next_idx=$((RUNNER_COUNT + 1))
        local next_var="GHR_RUNNER_${next_idx}_URL"
        if [ -n "${!next_var:-}" ]; then
            scan_idx="$next_idx"
        else
            scan_idx=1
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

        # If scan_idx is 1 and empty, but GHR_RUNNER_URL is set, use that
        if [ "$scan_idx" -eq 1 ] && [ -z "$url" ] && [ -n "${GHR_RUNNER_URL:-}" ]; then
            url="$GHR_RUNNER_URL"
            token="${GHR_RUNNER_TOKEN:-}"
        fi

        if [ -z "$url" ]; then
            break
        fi

        # Validate URL
        if ! validate_runner_url "$url"; then
            log_error "Validation failed for ${var_url}='${url}'. Expected valid GitHub repository or organization URL."
            exit 1
        fi

        if [ -z "$token" ]; then
            log_error "Missing required token in ${var_token} for ${url}."
            exit 1
        fi

        local prefix="${!var_prefix:-$(derive_prefix_from_url "$url")}"
        local labels="${!var_labels:-self-hosted,linux,docker}"
        local next_num=$((RUNNER_COUNT + 1))
        local workdir="${!var_workdir:-${INSTALL_DIR}/work/runner-${next_num}}"

        RUNNER_URLS+=("$url")
        RUNNER_TOKENS+=("$token")
        RUNNER_PREFIXES+=("$prefix")
        RUNNER_LABELS+=("$labels")
        RUNNER_WORKDIR_LIST+=("$workdir")
        RUNNER_COUNT="$next_num"
        scan_idx=$((scan_idx + 1))
    done

    if [ "$RUNNER_COUNT" -eq 0 ]; then
        log_error "No runners configured. Provide GHR_RUNNER_1_URL and GHR_RUNNER_1_TOKEN (or GHR_RUNNER_URL / GHR_RUNNER_TOKEN)."
        exit 1
    fi

    # Cache config
    local ghr_cache="${GHR_CACHE:-1}"
    if [ "$ghr_cache" = "0" ] || [ "$ghr_cache" = "false" ]; then
        CACHE_ENABLED=false
    else
        CACHE_ENABLED=true
    fi
    CACHE_URL="${GHR_CACHE_URL:-$CACHE_URL}"
    CACHE_PORT="${GHR_CACHE_PORT:-$CACHE_PORT}"
    RUNNER_IMAGE="${GHR_IMAGE:-${RUNNER_IMAGE:-$DEFAULT_IMAGE}}"

    log_info "Non-interactive configuration loaded (${RUNNER_COUNT} runners, Cache: ${CACHE_ENABLED})."
}

# ------------------------------------------------------------------------------
# Generation (write_files)
# ------------------------------------------------------------------------------
write_files() {
    log_info "Writing configuration to ${INSTALL_DIR}..."

    # Migrate temporary log to <dir>/install.log
    if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ] && [ "$LOG_FILE" != "${INSTALL_DIR}/install.log" ]; then
        cp -f "$LOG_FILE" "${INSTALL_DIR}/install.log" 2>/dev/null || true
        LOG_FILE="${INSTALL_DIR}/install.log"
    fi

    local env_file="${INSTALL_DIR}/.env"
    local compose_file="${INSTALL_DIR}/docker-compose.yml"
    local readme_file="${INSTALL_DIR}/README.txt"

    # Backup existing docker-compose.yml if present
    if [ -f "$compose_file" ]; then
        local ts
        ts="$(date +%Y%m%d%H%M%S)"
        log_info "Backing up existing docker-compose.yml to docker-compose.yml.bak.${ts}"
        cp -f "$compose_file" "${compose_file}.bak.${ts}"
    fi

    # 1. Write .env (permissions 600)
    touch "$env_file"
    chmod 600 "$env_file"

    {
        echo "# Auto-generated GitHub Actions Runner Stack configuration"
        echo "# Generated at: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
        echo "RUNNER_COUNT=${RUNNER_COUNT}"
        echo "RUNNER_IMAGE=${RUNNER_IMAGE}"
        echo "CACHE_ENABLED=${CACHE_ENABLED}"
        echo "CACHE_URL=${CACHE_URL}"
        echo "CACHE_PORT=${CACHE_PORT}"
        echo ""

        local i=1
        while [ "$i" -le "$RUNNER_COUNT" ]; do
            local idx=$((i - 1))
            echo "# Runner ${i}"
            echo "RUNNER_${i}_URL=${RUNNER_URLS[$idx]}"
            echo "RUNNER_${i}_TOKEN=${RUNNER_TOKENS[$idx]}"
            echo "RUNNER_${i}_NAME_PREFIX=${RUNNER_PREFIXES[$idx]}"
            echo "RUNNER_${i}_LABELS=${RUNNER_LABELS[$idx]}"
            echo "RUNNER_${i}_WORKDIR=${RUNNER_WORKDIR_LIST[$idx]}"
            echo ""
            i=$((i + 1))
        done
    } > "$env_file"
    chmod 600 "$env_file"

    # 2. Write docker-compose.yml deterministically
    {
        echo "services:"

        if [ "$CACHE_ENABLED" = true ]; then
            cat <<EOF
  cache-server:
    image: ${DEFAULT_CACHE_IMAGE}
    restart: unless-stopped
    ports:
      - "\${CACHE_PORT:-3000}:3000"
    environment:
      API_BASE_URL: \${CACHE_URL:-http://cache-server:3000}
      STORAGE_DRIVER: filesystem
      STORAGE_FILESYSTEM_PATH: /data/cache
      DB_DRIVER: sqlite
      DB_SQLITE_PATH: /data/cache-server.db
      CACHE_CLEANUP_OLDER_THAN_DAYS: 90
      CACHE_FILESYSTEM_MAX_USAGE_PERCENT: 90
    volumes:
      - cache_data:/data
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1:3000/"]
      interval: 5s
      timeout: 5s
      retries: 5
      start_period: 5s

EOF
        fi

        local j=1
        while [ "$j" -le "$RUNNER_COUNT" ]; do
            local idx=$((j - 1))
            local workdir="${RUNNER_WORKDIR_LIST[$idx]}"
            mkdir -p "$workdir"

            cat <<EOF
  runner-${j}:
    image: \${RUNNER_IMAGE}
    restart: unless-stopped
    environment:
      - RUNNER_URL=\${RUNNER_${j}_URL}
      - RUNNER_TOKEN=\${RUNNER_${j}_TOKEN}
      - RUNNER_NAME_PREFIX=\${RUNNER_${j}_NAME_PREFIX}
      - RUNNER_LABELS=\${RUNNER_${j}_LABELS}
      - RUNNER_WORKDIR=\${RUNNER_${j}_WORKDIR}
EOF
            if [ "$CACHE_ENABLED" = true ]; then
                echo "      - ACTIONS_RESULTS_URL=\${CACHE_URL:-http://cache-server:3000}/"
            fi
            cat <<EOF
      - LOG_LEVEL=\${LOG_LEVEL:-info}
    volumes:
      - runner_${j}_data:/runner
      - /var/run/docker.sock:/var/run/docker.sock
      - ${workdir}:${workdir}
EOF
            if [ "$CACHE_ENABLED" = true ]; then
                cat <<EOF
    depends_on:
      cache-server:
        condition: service_healthy
EOF
            fi
            cat <<EOF
    deploy:
      resources:
        limits:
          cpus: '2.0'
          memory: 4096M

EOF
            j=$((j + 1))
        done

        echo "volumes:"
        if [ "$CACHE_ENABLED" = true ]; then
            echo "  cache_data:"
        fi
        local k=1
        while [ "$k" -le "$RUNNER_COUNT" ]; do
            echo "  runner_${k}_data:"
            k=$((k + 1))
        done

    } > "$compose_file"

    # 3. Write README.txt
    cat <<EOF > "$readme_file"
================================================================================
GitHub Actions Self-Hosted Runner Stack
================================================================================
Location: ${INSTALL_DIR}
Runners : ${RUNNER_COUNT}
Cache   : ${CACHE_ENABLED} (${CACHE_URL})

Common Management Commands:
---------------------------
View running containers:
  cd ${INSTALL_DIR} && docker compose ps

View runner logs:
  cd ${INSTALL_DIR} && docker compose logs -f

Restart services:
  cd ${INSTALL_DIR} && docker compose restart

Update and pull latest images:
  cd ${INSTALL_DIR} && docker compose pull && docker compose up -d

Stop stack:
  cd ${INSTALL_DIR} && docker compose down

Uninstall stack:
  bash <(curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install.sh) --dir ${INSTALL_DIR} --uninstall
EOF

    log_info "Files generated successfully in ${INSTALL_DIR}."
}

# ------------------------------------------------------------------------------
# Start & Health Monitoring (start_stack)
# ------------------------------------------------------------------------------
start_stack() {
    local compose_file="${INSTALL_DIR}/docker-compose.yml"
    run_with_spinner "Validating Docker Compose configuration" docker_exec compose -f "$compose_file" config -q

    run_with_spinner "Starting container stack" docker_exec compose -f "$compose_file" up -d

    log_info "Current container status:"
    docker_exec compose -f "$compose_file" ps

    log_info "Monitoring runner registration logs (up to 30s)..."
    local elapsed=0
    local max_wait=30
    local all_done=false

    declare -a runner_status=()
    local i=1
    while [ "$i" -le "$RUNNER_COUNT" ]; do
        runner_status+=("STARTING")
        i=$((i + 1))
    done

    local is_interactive_tty=false
    if [ -t 1 ] && [ "$NON_INTERACTIVE" = false ]; then
        is_interactive_tty=true
    fi

    local spin_chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local spin_idx=0
    local last_notice=0

    if [ "$is_interactive_tty" = true ]; then
        printf "\033[?25l"
    fi

    while [ "$elapsed" -lt "$max_wait" ]; do
        all_done=true
        local k=1
        while [ "$k" -le "$RUNNER_COUNT" ]; do
            local idx=$((k - 1))
            if [ "${runner_status[idx]}" = "STARTING" ]; then
                local logs
                logs="$(docker_exec compose -f "$compose_file" logs --tail 30 "runner-${k}" 2>&1 || true)"
                if echo "$logs" | grep -qi "Listening for Jobs"; then
                    runner_status[idx]="OK: Listening for Jobs"
                    if [ "$is_interactive_tty" = true ]; then
                        printf "\r${COLOR_GREEN}✓${COLOR_RESET} Runner #%d registered and listening for jobs! \033[K\n" "$k"
                    else
                        printf "  ✓ Runner #%d registered and listening for jobs!\n" "$k"
                    fi
                elif echo "$logs" | grep -qiE "Http response code: (NotFound|404)"; then
                    runner_status[idx]="FAIL: Registration failed (404 Not Found - invalid token)"
                    if [ "$is_interactive_tty" = true ]; then
                        printf "\r${COLOR_RED}✗${COLOR_RESET} Runner #%d registration failed (404 Not Found) \033[K\n" "$k"
                    else
                        printf "  ✗ Runner #%d registration failed (404 Not Found)\n" "$k"
                    fi
                elif echo "$logs" | grep -qiE "Http response code: (Unauthorized|401)"; then
                    runner_status[idx]="FAIL: Registration failed (401 Unauthorized)"
                    if [ "$is_interactive_tty" = true ]; then
                        printf "\r${COLOR_RED}✗${COLOR_RESET} Runner #%d registration failed (401 Unauthorized) \033[K\n" "$k"
                    else
                        printf "  ✗ Runner #%d registration failed (401 Unauthorized)\n" "$k"
                    fi
                elif echo "$logs" | grep -qi "Failed to create a session"; then
                    runner_status[idx]="FAIL: Failed to create runner session"
                    if [ "$is_interactive_tty" = true ]; then
                        printf "\r${COLOR_RED}✗${COLOR_RESET} Runner #%d failed to create session \033[K\n" "$k"
                    else
                        printf "  ✗ Runner #%d failed to create session\n" "$k"
                    fi
                elif echo "$logs" | grep -qi "Existing runner configuration detected"; then
                    runner_status[idx]="OK: Registered (credentials loaded from volume)"
                    if [ "$is_interactive_tty" = true ]; then
                        printf "\r${COLOR_GREEN}✓${COLOR_RESET} Runner #%d loaded from volume! \033[K\n" "$k"
                    else
                        printf "  ✓ Runner #%d loaded from volume!\n" "$k"
                    fi
                else
                    all_done=false
                fi
            fi
            k=$((k + 1))
        done

        if [ "$all_done" = true ]; then
            break
        fi

        if [ "$is_interactive_tty" = true ]; then
            printf "\r${COLOR_BLUE}%s${COLOR_RESET} Waiting for runner registration (%ds/%ds)... \033[K" "${spin_chars[spin_idx]}" "$elapsed" "$max_wait"
            spin_idx=$(( (spin_idx + 1) % 10 ))
            sleep 0.5
            elapsed=$((elapsed + 1))
        else
            sleep 2
            elapsed=$((elapsed + 2))
            if [ $((elapsed - last_notice)) -ge 10 ]; then
                printf "  ... still waiting for runner registration (%ds)\n" "$elapsed"
                last_notice="$elapsed"
            fi
        fi
    done

    if [ "$is_interactive_tty" = true ]; then
        printf "\033[?25h\r\033[K"
    fi

    local n=1
    while [ "$n" -le "$RUNNER_COUNT" ]; do
        local n_idx=$((n - 1))
        if [ "${runner_status[n_idx]}" = "STARTING" ]; then
            runner_status[n_idx]="WARN: Timed out waiting for registration after 30s"
        fi
        n=$((n + 1))
    done

    printf "\n================ Final Deployment Status ================\n"
    printf "Stack Directory : %s\n" "$INSTALL_DIR"
    local m=1
    while [ "$m" -le "$RUNNER_COUNT" ]; do
        local m_idx=$((m - 1))
        local st="${runner_status[m_idx]}"
        local r_url="${RUNNER_URLS[m_idx]}"
        if [[ "$st" == OK:* ]]; then
            printf "  Runner #%d: ${COLOR_GREEN}✓ %s${COLOR_RESET} (%s)\n" "$m" "$st" "$r_url"
        elif [[ "$st" == FAIL:* ]]; then
            printf "  Runner #%d: ${COLOR_RED}✗ %s${COLOR_RESET} (%s)\n" "$m" "$st" "$r_url"
        else
            printf "  Runner #%d: ${COLOR_YELLOW}! %s${COLOR_RESET} (%s)\n" "$m" "$st" "$r_url"
        fi
        printf "    Settings page: %s/settings/actions/runners\n" "${r_url%/}"
        m=$((m + 1))
    done
    printf "=========================================================\n"
    printf "Manage commands:\n"
    printf "  cd %s && docker compose ps\n" "$INSTALL_DIR"
    printf "  cd %s && docker compose logs -f\n" "$INSTALL_DIR"
    printf "  cd %s && docker compose down\n" "$INSTALL_DIR"
}

# ------------------------------------------------------------------------------
# Uninstall
# ------------------------------------------------------------------------------
do_uninstall() {
    if [ -z "$INSTALL_DIR" ]; then
        if [ "$(id -u)" -eq 0 ]; then
            INSTALL_DIR="/opt/github-runner"
        else
            INSTALL_DIR="${HOME}/github-runner"
        fi
    fi

    local compose_file="${INSTALL_DIR}/docker-compose.yml"
    if [ ! -f "$compose_file" ]; then
        log_error "No docker-compose.yml found in ${INSTALL_DIR}. Nothing to uninstall."
        exit 1
    fi

    log_info "Stopping containers in ${INSTALL_DIR}..."
    docker_exec compose -f "$compose_file" down || true

    local remove_volumes=false
    if [ "$NON_INTERACTIVE" = true ]; then
        if [ "${GHR_UNINSTALL_VOLUMES:-no}" = "yes" ]; then
            remove_volumes=true
        fi
    else
        if prompt_confirm "Do you want to delete persistent volumes (runner credentials and cache data will be permanently lost)?" "N"; then
            remove_volumes=true
        fi
    fi

    if [ "$remove_volumes" = true ]; then
        log_info "Removing persistent Docker volumes..."
        docker_exec compose -f "$compose_file" down -v --remove-orphans || true
    fi

    log_info "Uninstall complete. Configuration and files remain in ${INSTALL_DIR}."
}

# ------------------------------------------------------------------------------
# Usage / Help
# ------------------------------------------------------------------------------
show_help() {
    cat <<EOF
GitHub Actions Runner & Cache Server One-Line Installer v${INSTALLER_VERSION}

Usage:
  install.sh [OPTIONS]
  curl -fsSL https://raw.githubusercontent.com/bestony/self-hosted-action-runner/main/install.sh | bash -s -- [OPTIONS]

Options:
  --dir <path>             Installation directory (default: /opt/github-runner for root, \$HOME/github-runner for non-root)
  --non-interactive        Run without interactive prompts (reads GHR_* environment variables)
  --no-start               Generate files and docker-compose.yml only (skip docker compose pull & up)
  --skip-docker-install    Skip automatic Docker Engine & Compose plugin installation attempts
  --uninstall              Stop stack and optionally remove volumes
  --debug                  Enable verbose debug output (or set GHR_DEBUG=1)
  -h, --help               Show this help message and exit

Non-Interactive Environment Variables:
  GHR_RUNNER_1_URL         GitHub repository or organization URL for runner 1
  GHR_RUNNER_1_TOKEN       GitHub registration token for runner 1
  GHR_RUNNER_1_LABELS      Optional comma-separated labels (default: self-hosted,linux,docker)
  GHR_RUNNER_1_NAME_PREFIX Optional runner name prefix (default derived from URL)
  GHR_RUNNER_2_URL         (Optional) Additional runner URL
  GHR_RUNNER_2_TOKEN       (Optional) Additional runner token
  GHR_CACHE                Enable cache server: 1 (default) or 0
  GHR_CACHE_URL            Base cache server URL (default: http://cache-server:3000)
  GHR_IMAGE                Custom runner container image
  GHR_INSTALL_DOCKER       Allow automatic Docker install: yes (default) or no
  GHR_MODE                 Install mode: new (default), add, or reconfigure
  GHR_UNINSTALL_VOLUMES    With --uninstall: set to 'yes' to delete volumes without prompt

Exit Codes:
  0   Success
  1   General error
  2   Usage / argument error
EOF
}

# ------------------------------------------------------------------------------
# Argument Parsing
# ------------------------------------------------------------------------------
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dir)
                if [ -n "${2:-}" ]; then
                    INSTALL_DIR="$2"
                    shift 2
                else
                    log_error "--dir requires a path argument."
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
            --skip-docker-install)
                SKIP_DOCKER_INSTALL=true
                shift
                ;;
            --uninstall)
                DO_UNINSTALL=true
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
main() {
    parse_args "$@"

    print_banner

    # Handle uninstall flow
    if [ "$DO_UNINSTALL" = true ]; then
        step_header "1/2" "Checking system"
        detect_system
        ensure_dependencies
        step_header "2/2" "Uninstalling stack"
        do_uninstall
        exit 0
    fi

    # If interactive mode is requested, ensure we have a TTY available
    if [ "$NON_INTERACTIVE" = false ] && [ ! -t 0 ] && [ ! -c /dev/tty ]; then
        log_error "Standard input is not a terminal and /dev/tty is unavailable. Use --non-interactive mode."
        exit 1
    fi

    step_header "1/6" "Checking system"
    detect_system

    step_header "2/6" "Verifying Docker environment"
    ensure_dependencies

    step_header "3/6" "Collecting configuration"
    if [ "$NON_INTERACTIVE" = true ]; then
        collect_non_interactive_config
    else
        collect_interactive_config
    fi

    step_header "4/6" "Writing files"
    write_files

    if [ "$NO_START" = false ]; then
        step_header "5/6" "Pulling images"
        log_info "Running 'docker compose pull' (showing native Docker progress)..."
        docker_exec compose -f "${INSTALL_DIR}/docker-compose.yml" pull

        step_header "6/6" "Starting runners"
        start_stack
    else
        step_header "5/6" "Pulling images (skipped: --no-start)"
        step_header "6/6" "Starting runners (skipped: --no-start)"
        log_info "Files are ready in ${INSTALL_DIR}."
    fi

    log_info "Installer completed successfully."
}

main "$@"
