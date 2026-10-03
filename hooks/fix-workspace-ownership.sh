#!/usr/bin/env bash
# Runner job hook (ACTIONS_RUNNER_HOOK_JOB_STARTED / ACTIONS_RUNNER_HOOK_JOB_COMPLETED).
#
# Jobs that use the host Docker socket often start containers as root that
# write into the bind-mounted workspace. The runner process runs as the
# unprivileged "runner" user and then cannot clean or check out the workspace
# ("EACCES: permission denied"). Steps that use sudo can do the same to the
# tool cache. This hook gives those files back to the runner user before and
# after each job.
#
# The hook never fails the job: every problem is logged as a warning.

set -uo pipefail

RUNNER_USER="$(id -un)"
RUNNER_GROUP="$(id -gn)"

log() {
    printf '[workspace-ownership] %s\n' "$*"
}

fix_dir() {
    local dir="$1"
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        return 0
    fi
    # Resolve symbolic links: find and chown do not follow a link operand
    # (the tool cache can be a link into the runner volume).
    dir="$(realpath -e -- "$dir" 2>/dev/null)" || return 0
    # Fast path: skip the recursive chown when every entry is already ours.
    if [ -z "$(find "$dir" ! -user "$RUNNER_USER" -print -quit 2>/dev/null)" ]; then
        return 0
    fi
    log "Found files not owned by ${RUNNER_USER} in ${dir}; restoring ownership."
    if sudo -n chown -R "${RUNNER_USER}:${RUNNER_GROUP}" "$dir"; then
        log "Ownership restored for ${dir}."
    else
        log "WARNING: could not restore ownership for ${dir} (sudo unavailable?)."
    fi
}

# RUNNER_WORKSPACE is the per-repository directory that contains GITHUB_WORKSPACE.
fix_dir "${RUNNER_WORKSPACE:-${GITHUB_WORKSPACE:-}}"
fix_dir "${RUNNER_TEMP:-}"
fix_dir "${RUNNER_TOOL_CACHE:-}"

exit 0
