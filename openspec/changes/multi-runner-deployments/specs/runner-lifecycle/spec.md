# Spec Delta

## MODIFIED Requirements

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
