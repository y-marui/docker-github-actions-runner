# self-hosted GitHub Actions runner (Linux) for private repositories.
# Provides the tools the CI jobs use that a bare Ubuntu image lacks.
# Published as ghcr.io/y-marui/actions-runner (linux/amd64, linux/arm64) by
# .github/workflows/publish.yml. Local build: bash setup.sh build
ARG SWIFTLINT_VERSION=0.65.1
FROM ghcr.io/realm/swiftlint:${SWIFTLINT_VERSION} AS swiftlint

FROM ubuntu:26.04

ARG TARGETARCH
ARG RUNNER_VERSION=2.337.0
ARG GITLEAKS_VERSION=8.30.1

ENV DEBIAN_FRONTEND=noninteractive \
    RUNNER_TOOL_CACHE=/runner/.cache/toolcache \
    AGENT_TOOLSDIRECTORY=/runner/.cache/toolcache \
    PIP_BREAK_SYSTEM_PACKAGES=1 \
    PATH=/runner/.local/bin:${PATH}

# PIP_BREAK_SYSTEM_PACKAGES: Ubuntu 24.04 marks system python as externally managed (PEP 668),
# which makes `pip install` (e.g. pre-commit/action) fail for the non-root runner user.
# PATH: `pip install` as that user puts executables (pre-commit) in ~/.local/bin.
# Tools used by the CI jobs: git/gh/curl/jq/zip, python (pre-commit hooks), node,
# shellcheck, and the shared libraries Qt/PySide6 tests load (GitHub-hosted images preinstall them).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg jq unzip zip perl build-essential \
      python3 python3-pip python3-venv python-is-python3 nodejs npm shellcheck libegl1 libxkbcommon0 \
      libglib2.0-0t64 libgl1 libopengl0 libfontconfig1 libfreetype6 libdbus-1-3 \
      libxkbcommon-x11-0 libx11-6 libxcb1 libxcb-cursor0 libxcb-icccm4 libxcb-image0 libxcb-keysyms1 \
      libxcb-randr0 libxcb-render-util0 libxcb-shape0 libxcb-xinerama0 libxcb-xkb1 libxrender1 libxi6 libsm6 libice6 \
      libicu74 libssl3t64 \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=${TARGETARCH} signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# uv, gitleaks
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh \
 && case "${TARGETARCH}" in amd64) GL=x64;; arm64) GL=arm64;; *) echo "unsupported arch ${TARGETARCH}" >&2; exit 1;; esac \
 && curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_${GL}.tar.gz" \
      | tar -xz -C /usr/local/bin gitleaks

# SwiftLint needs the Swift runtime libraries (e.g. libsourcekitdInProc.so); take the binary and
# the libraries from the official image (same Ubuntu base), so the lint job does not need docker.
COPY --from=swiftlint /usr/bin/swiftlint /usr/local/bin/swiftlint
COPY --from=swiftlint /usr/lib/*.so /usr/local/lib/swiftlint/
RUN echo /usr/local/lib/swiftlint > /etc/ld.so.conf.d/swiftlint.conf && ldconfig
ENV LINUX_SOURCEKIT_LIB_PATH=/usr/local/lib/swiftlint

# Runner binaries live in the image (/opt/runner); the entrypoint copies them into the
# volume-backed runner directory so registration state survives container re-creation.
RUN case "${TARGETARCH}" in amd64) RA=x64;; arm64) RA=arm64;; esac \
 && mkdir -p /opt/runner \
 && curl -fsSL "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RA}-${RUNNER_VERSION}.tar.gz" \
      | tar -xz -C /opt/runner \
 && echo "${RUNNER_VERSION}" > /opt/runner/.image-version

# Non-root user without sudo.
RUN useradd -m -d /runner -s /bin/bash runner \
 && mkdir -p /runner/actions-runner /runner/.cache \
 && chown -R runner:runner /runner

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

USER runner
WORKDIR /runner/actions-runner
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
