# Runner Lifecycle Specification

## Purpose

Handles automated GitHub runner registration, persistent configuration management across container restarts, cache server environment setup, and runtime process execution.

## Requirements

### Requirement: Automated Initial Registration
The entrypoint script SHALL automatically register the runner with GitHub using either a repository-level URL or an organization-level URL when valid `RUNNER_URL` and `RUNNER_TOKEN` environment variables are provided and no prior runner configuration is detected.

#### Scenario: Repository-level registration
- **WHEN** the container starts for the first time with `RUNNER_URL` set to a repository (e.g. `https://github.com/owner/repo`) and a valid repository registration token
- **THEN** the entrypoint invokes `./config.sh` with the repository URL and registers the runner under that repository

#### Scenario: Organization-level registration
- **WHEN** the container starts for the first time with `RUNNER_URL` set to an organization (e.g. `https://github.com/org`) and an organization registration token
- **THEN** the entrypoint invokes `./config.sh` with the organization URL and registers the runner under that organization

#### Scenario: Missing required registration parameters
- **WHEN** the container starts without existing configuration and is missing either `RUNNER_URL` or `RUNNER_TOKEN`
- **THEN** the container writes an error message to stderr and exits with a non-zero status

### Requirement: Configuration Persistence Across Restarts
The entrypoint SHALL reuse persisted runner configuration files (`.runner` and `.credentials`) from a mounted volume directory, bypassing re-registration when restarting the container.

#### Scenario: Reusing existing configuration on container restart
- **WHEN** a container starts with an existing `.runner` configuration in its persistent directory
- **THEN** the entrypoint skips `./config.sh` and immediately executes `./run.sh`

#### Scenario: Restart after registration token expiration
- **WHEN** the container restarts after the initial registration token has expired
- **THEN** the runner connects to GitHub using the persisted credentials without failing authentication

### Requirement: Runner Customization Options
The runner entrypoint SHALL accept optional configuration environment variables for runner name, runner name prefix, runner group, and runner labels during registration.

#### Scenario: Applying custom runner labels
- **WHEN** `RUNNER_LABELS` is provided in the environment during registration
- **THEN** `./config.sh` registers the runner with the specified labels included

#### Scenario: Applying custom runner name
- **WHEN** `RUNNER_NAME` is provided in the environment
- **THEN** the runner registers using the specified name rather than the default container hostname

#### Scenario: Applying runner name prefix
- **WHEN** `RUNNER_NAME_PREFIX` is provided without an explicit `RUNNER_NAME`
- **THEN** the runner registers with a name composed of the prefix and the container hostname or unique identifier

### Requirement: Docker Socket Permission Adaptation
The entrypoint script SHALL detect if `/var/run/docker.sock` is mounted into the container and automatically configure group permissions so the unprivileged runner user can execute Docker commands without sudo.

#### Scenario: Accessing mounted host Docker socket
- **WHEN** `/var/run/docker.sock` is mounted into the runner container from the host
- **THEN** the entrypoint detects the socket's group ID, ensures the runner user belongs to that group, and allows `docker ps` execution by the runner user

### Requirement: Cache Server Environment Configuration
The entrypoint script SHALL validate and configure `ACTIONS_RESULTS_URL` for custom cache servers and disable runner auto-updates during registration to preserve binary modifications.

#### Scenario: Trailing slash normalization for cache URL
- **WHEN** `ACTIONS_RESULTS_URL` is set without a trailing slash (e.g. `http://cache-server:3000`)
- **THEN** the entrypoint appends a trailing slash before passing the variable to the runner environment

#### Scenario: Disabling runner auto-update for cache compatibility
- **WHEN** a custom `ACTIONS_RESULTS_URL` is configured or `DISABLE_AUTO_UPDATE=true` is set
- **THEN** `./config.sh` receives the `--disableupdate` flag during registration to prevent GitHub from overwriting the patched runner worker DLL

### Requirement: Graceful Signal Handling
The container process SHALL handle standard termination signals (`SIGINT`, `SIGTERM`) and gracefully stop the runner process without abrupt termination.

#### Scenario: Handling container stop
- **WHEN** Docker sends `SIGTERM` to the container during `docker stop`
- **THEN** the entrypoint forwards the termination signal to the running runner process and waits for it to exit cleanly
