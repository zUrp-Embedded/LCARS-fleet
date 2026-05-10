# LCARS Fleet — Docker image
# User-facing CLI: ./docker.sh at repo root
# This Dockerfile is an implementation detail.
#
# BUILD-TIME: packages, yq, Claude Code, GitHub CLI, repo copy
# RUN-TIME:   entrypoint.sh handles user, credentials, deploy

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV LCARS_DOCKER=1

# ─── Base packages ────────────────────────────────────────────────────────────
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
        bash curl git jq sudo openssh-client tmux inotify-tools \
        python3 python3-pip python3-venv python3-yaml expect \
    && rm -rf /var/lib/apt/lists/*

# ─── yq (pinned version + SHA256 verification) ──────────────────────────────
# IEC 61508: pin version with checksum to prevent supply-chain substitution
ARG YQ_VERSION=v4.44.6
ARG YQ_SHA256_AMD64=9e8a01408442a56a13fa2b12e4a71a98145e2b86b9fca3e8774d8e3ac9cd9cbb
ARG YQ_SHA256_ARM64=b27e31731e79a710f02ee6aec0e8cde5a0e03e00a2ac9b5d1fa4e2d8dbc01360
RUN ARCH="$(dpkg --print-architecture)" \
    && curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}" \
        -o /usr/local/bin/yq \
    && if [ "$ARCH" = "amd64" ]; then echo "${YQ_SHA256_AMD64}  /usr/local/bin/yq" | sha256sum -c -; \
       elif [ "$ARCH" = "arm64" ]; then echo "${YQ_SHA256_ARM64}  /usr/local/bin/yq" | sha256sum -c -; fi \
    && chmod 755 /usr/local/bin/yq

# ─── Claude Code — system-wide ────────────────────────────────────────────────
# IEC 61508: download to file first, then execute (no direct pipe to shell)
# Note: claude install.sh has no stable version/hash — Anthropic controls the content.
# Accepted risk: supply chain trust on Anthropic's install endpoint.
RUN curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh \
    && bash /tmp/claude-install.sh \
    && rm -f /tmp/claude-install.sh \
    && CLAUDE_BIN="$(readlink -f /root/.local/bin/claude 2>/dev/null || echo /root/.local/bin/claude)" \
    && cp "$CLAUDE_BIN" /usr/local/bin/claude \
    && chmod 755 /usr/local/bin/claude \
    && /usr/local/bin/claude --version

# ─── GitHub CLI ───────────────────────────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update -qq && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# ─── LCARS source (see .dockerignore — .git excluded) ───────────────────────
COPY . /tmp/lcars-install

# ─── Entrypoint ──────────────────────────────────────────────────────────────
COPY fleet/provisioning/docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh

HEALTHCHECK --interval=60s --timeout=5s --retries=3 \
    CMD pgrep -x tmux > /dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
