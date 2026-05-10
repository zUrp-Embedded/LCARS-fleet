#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: Dockerfile
#     |  |________|  | AUTHOR: LORDZURP
#     |   ________   | SYSTEM: LCARS-FLEET v2.0
#     |  |  v2.0  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: DOCKER          | SUBSYSTEM: SANDBOX              |
#     | LICENSE: AGPL-3         | STARDATE: 2026.069              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Self-contained sandbox for testing LCARS-fleet.          |
#     |  No root required on host. Fully disposable.             |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#   Build:  docker build -t lcars-fleet docker/
#   Run:    docker run -it -e ANTHROPIC_API_KEY=sk-ant-... lcars-fleet
#

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# ─── System packages ─────────────────────────────────────────────────────────
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
        bash \
        btop \
        curl \
        git \
        jq \
        openssh-client \
        python3 \
        python3-pip \
        python3-venv \
        python3-yaml \
        sudo \
        tmux \
    && rm -rf /var/lib/apt/lists/*

# ─── Claude Code — system-wide ───────────────────────────────────────────────
RUN curl -fsSL https://claude.ai/install.sh | bash \
    && cp /root/.claude/bin/claude /usr/local/bin/claude 2>/dev/null \
    || cp /root/.local/bin/claude /usr/local/bin/claude 2>/dev/null \
    || true
RUN chmod 755 /usr/local/bin/claude 2>/dev/null || true

# ─── Fleet group ─────────────────────────────────────────────────────────────
RUN groupadd fleet

# ─── Fleet users ─────────────────────────────────────────────────────────────
# Primary user (architect equivalent)
RUN useradd -m -s /bin/bash -G fleet lordzurp

# Agent users
RUN for agent in dev qualifier builder starfleet engineer steward; do \
        useradd -m -s /bin/bash -G fleet "$agent"; \
    done

# ─── Sudoers — fleet owner can sudo -u to all fleet agents ───────────────────
RUN echo 'lordzurp ALL=(steward,dev,qualifier,engineer,builder,starfleet) NOPASSWD: ALL' \
    > /etc/sudoers.d/fleet-lordzurp \
    && chmod 440 /etc/sudoers.d/fleet-lordzurp

# ─── SSH known_hosts — pre-bake GitHub host key for all users ────────────────
RUN mkdir -p /etc/skel/.ssh \
    && ssh-keyscan -t ed25519 github.com > /etc/skel/.ssh/known_hosts 2>/dev/null \
    && for user in lordzurp dev qualifier builder starfleet engineer steward; do \
        home=$(getent passwd "$user" | cut -d: -f6); \
        mkdir -p "$home/.ssh"; \
        cp /etc/skel/.ssh/known_hosts "$home/.ssh/known_hosts"; \
        chown -R "$user:$user" "$home/.ssh"; \
        chmod 700 "$home/.ssh"; \
        chmod 644 "$home/.ssh/known_hosts"; \
    done

# ─── /home/commons — shared fleet directory ──────────────────────────────────
RUN mkdir -p \
        /home/commons/logs \
        /home/commons/fleet-state \
        /home/commons/archives \
        /home/ready-room/inbox \
        /home/ready-room/outbox \
    && chown -R lordzurp:fleet /home/commons /home/ready-room \
    && chmod 775 /home/commons /home/ready-room \
    && chmod g+ws /home/commons

# IPC files — pre-created with structure
RUN for ipc in to-dev.md to-qualifier.md to-starfleet.md to-engineer.md; do \
        printf '## ACTIONS\n\n## DONE\n' > "/home/commons/$ipc"; \
    done \
    && for ipc in starfleet-notes.md bug-queue.md test-queue.md; do \
        touch "/home/commons/$ipc"; \
    done \
    && find /home/commons -maxdepth 1 -type f -exec chown lordzurp:fleet {} \; -exec chmod g+rw {} \;

# ─── /home/projects + /home/tmp — shared workspaces ─────────────────────────
RUN mkdir -p /home/projects /home/tmp \
    && chown lordzurp:fleet /home/projects /home/tmp \
    && chmod 2775 /home/projects /home/tmp

# ─── /home/private — fleet shared secrets ────────────────────────────────────
RUN mkdir -p /home/private \
    && chown lordzurp:fleet /home/private \
    && chmod 770 /home/private

# ─── LCARS repo ──────────────────────────────────────────────────────────────
COPY . /local/LCARS
RUN chown -R lordzurp:lordzurp /local/LCARS

# Symlink for each user
RUN for agent in lordzurp dev qualifier builder starfleet engineer steward; do \
        ln -sfn /local/LCARS "/home/$agent/.lcars" \
        && chown -h "$agent:$agent" "/home/$agent/.lcars"; \
    done

# ─── Git identity — default for all users (overridable at runtime) ──────────
RUN for user in lordzurp dev qualifier builder starfleet engineer steward; do \
        home=$(getent passwd "$user" | cut -d: -f6); \
        case "$user" in \
            lordzurp) name="LCARS-architect" ;; \
            *)        name="LCARS-$user" ;; \
        esac; \
        su - "$user" -c "git config --global user.name '$name'"; \
        su - "$user" -c "git config --global user.email '${user}@lcars-fleet.local'"; \
        su - "$user" -c "git config --global safe.directory /local/LCARS"; \
    done

# ─── Provision each user ────────────────────────────────────────────────────
# provision-system.sh handles: CLAUDE.md, skills, hooks, commands, memory,
# fleet utils, .bashrc patches, instance-name
RUN for user in lordzurp dev qualifier builder starfleet engineer steward; do \
        echo "=== Provisioning $user ===" \
        && bash /local/LCARS/fleet/provisioning/linux/provision-system.sh "$user"; \
    done

# ─── Claude Code per-user setup (skip API auth + SSH) ────────────────────────
# Copy claude binary to each user's .local/bin
RUN for user in lordzurp dev qualifier builder starfleet engineer steward; do \
        home=$(getent passwd "$user" | cut -d: -f6) \
        && mkdir -p "$home/.local/bin" \
        && cp /usr/local/bin/claude "$home/.local/bin/claude" 2>/dev/null || true \
        && chmod +x "$home/.local/bin/claude" 2>/dev/null || true \
        && chown -R "$user:$user" "$home/.local"; \
    done

# ─── Claude settings — pre-configure for each user ──────────────────────────
RUN for user in dev qualifier builder starfleet engineer steward; do \
        home=$(getent passwd "$user" | cut -d: -f6) \
        && mkdir -p "$home/.claude" \
        && cat > "$home/.claude/settings.local.json" <<'SETTINGS' \
{ \
  "permissions": { \
    "defaultMode": "bypassPermissions", \
    "additionalDirectories": [ \
      "/home/commons" \
    ] \
  }, \
  "hooks": { \
    "UserPromptSubmit": [ \
      { \
        "hooks": [ \
          { \
            "type": "command", \
            "command": "bash $HOME/.claude/hooks/session-startup.sh" \
          } \
        ] \
      }, \
      { \
        "hooks": [ \
          { \
            "type": "command", \
            "command": "bash $HOME/.claude/hooks/on-prompt.sh" \
          } \
        ] \
      } \
    ], \
    "PostToolUse": [ \
      { \
        "matcher": "Edit|Write", \
        "hooks": [ \
          { \
            "type": "command", \
            "command": "bash $HOME/.claude/hooks/post-directional-handoff-reminder.sh" \
          }, \
          { \
            "type": "command", \
            "command": "bash $HOME/.claude/hooks/check-secrets.sh" \
          } \
        ] \
      } \
    ] \
  } \
} \
SETTINGS
        cat > "$home/.claude/settings.json" <<GLOBAL \
{ \
  "projects": { \
    "$home": { \
      "hasTrustDialogAccepted": true \
    }, \
    "~": { \
      "hasTrustDialogAccepted": true \
    }, \
    "/home/commons": { \
      "hasTrustDialogAccepted": true \
    } \
  } \
} \
GLOBAL
        chown -R "$user:$user" "$home/.claude"; \
    done

# ─── Deploy assets ───────────────────────────────────────────────────────────
RUN bash /local/LCARS/fleet/provisioning/deploy.sh || true

# ─── Handoff files for each agent ────────────────────────────────────────────
RUN for agent in lordzurp dev qualifier builder starfleet engineer steward; do \
        case "$agent" in \
            lordzurp) name="architect" ;; \
            *) name="$agent" ;; \
        esac; \
        handoff="/home/commons/${name}-handoff.md"; \
        if [ ! -f "$handoff" ]; then \
            printf '# %s handoff\n`%s-handoff.md`\n\n## STATE\ndate: %s\nref: \naction: idle\nstatus: pending\nblocker: none\nwaiting: none\nnotify: none\n\n## ACTIONS\n\n## DONE\n### %s — Instance created (Docker sandbox)\n' \
                "$name" "$name" "$(date '+%Y-%m-%d %H:%M')" "$(date '+%Y-%m-%d %H:%M')" \
                > "$handoff"; \
            chown lordzurp:fleet "$handoff"; \
            chmod g+rw "$handoff"; \
        fi; \
    done

# ─── Provision done marker ───────────────────────────────────────────────────
RUN touch /home/commons/.provision-done

# ─── Entrypoint ──────────────────────────────────────────────────────────────
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER lordzurp
WORKDIR /home/lordzurp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
