FROM ubuntu:22.04

ARG TARGETARCH
ARG RUNNER_VERSION=2.337.0
ARG RUNNER_SHA256_AMD64="70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613"
ARG RUNNER_SHA256_ARM64="9b1dc70626422526e3c94767cf024896beb15da5342a3f4819bf2feac13e0393"

ENV DEBIAN_FRONTEND=noninteractive
ENV RUNNER_VERSION=${RUNNER_VERSION}

# Install base dependencies and utilities (runtime only, no dev packages)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    gnupg \
    jq \
    libicu70 \
    lsb-release \
    sudo \
    tar \
    zstd \
    && rm -rf /var/lib/apt/lists/*

# Install Docker CLI tools
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=${TARGETARCH:-amd64} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu jammy stable" > /etc/apt/sources.list.d/docker.list && \
    apt-get update && apt-get install -y --no-install-recommends \
    docker-ce-cli \
    docker-buildx-plugin \
    docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# Create unprivileged runner user
RUN useradd -m -s /bin/bash -u 1001 runner && \
    echo "runner ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Download runner package for matching architecture, verify SHA256, install dependencies, and apply/verify GHA Cache Server patch
RUN case "${TARGETARCH:-amd64}" in \
        amd64) \
            RUNNER_ARCH="x64"; \
            EXPECTED_SHA256="${RUNNER_SHA256_AMD64}" ;; \
        arm64) \
            RUNNER_ARCH="arm64"; \
            EXPECTED_SHA256="${RUNNER_SHA256_ARM64}" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}"; exit 1 ;; \
    esac && \
    mkdir -p /opt/runner-dist /runner && \
    curl -fL -o /tmp/runner.tar.gz "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz" && \
    if [ -n "${EXPECTED_SHA256}" ]; then \
        echo "${EXPECTED_SHA256}  /tmp/runner.tar.gz" | sha256sum -c - || { echo "Checksum verification failed!" >&2; exit 1; }; \
    fi && \
    tar xzf /tmp/runner.tar.gz -C /opt/runner-dist && \
    rm /tmp/runner.tar.gz && \
    /opt/runner-dist/bin/installdependencies.sh && \
    rm -rf /var/lib/apt/lists/* && \
    echo "${RUNNER_VERSION}" > /opt/runner-dist/.image-runner-version && \
    if [ ! -f /opt/runner-dist/bin/Runner.Worker.dll ]; then \
        echo "Error: /opt/runner-dist/bin/Runner.Worker.dll not found!" >&2; exit 1; \
    fi && \
    sed -i 's/\x41\x00\x43\x00\x54\x00\x49\x00\x4F\x00\x4E\x00\x53\x00\x5F\x00\x52\x00\x45\x00\x53\x00\x55\x00\x4C\x00\x54\x00\x53\x00\x5F\x00\x55\x00\x52\x00\x4C\x00/\x41\x00\x43\x00\x54\x00\x49\x00\x4F\x00\x4E\x00\x53\x00\x5F\x00\x52\x00\x45\x00\x53\x00\x55\x00\x4C\x00\x54\x00\x53\x00\x5F\x00\x4F\x00\x52\x00\x4C\x00/g' /opt/runner-dist/bin/Runner.Worker.dll && \
    grep -aP '\x41\x00\x43\x00\x54\x00\x49\x00\x4F\x00\x4E\x00\x53\x00\x5F\x00\x52\x00\x45\x00\x53\x00\x55\x00\x4C\x00\x54\x00\x53\x00\x5F\x00\x4F\x00\x52\x00\x4C\x00' /opt/runner-dist/bin/Runner.Worker.dll >/dev/null || { echo "Binary patch check failed: ACTIONS_RESULTS_ORL not found in DLL!" >&2; exit 1; } && \
    ! grep -aP '\x41\x00\x43\x00\x54\x00\x49\x00\x4F\x00\x4E\x00\x53\x00\x5F\x00\x52\x00\x45\x00\x53\x00\x55\x00\x4C\x00\x54\x00\x53\x00\x5F\x00\x55\x00\x52\x00\x4C\x00' /opt/runner-dist/bin/Runner.Worker.dll >/dev/null || { echo "Binary patch check failed: original ACTIONS_RESULTS_URL still present in DLL!" >&2; exit 1; } && \
    chown -R runner:runner /opt/runner-dist /runner

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /runner

ENTRYPOINT ["/entrypoint.sh"]
