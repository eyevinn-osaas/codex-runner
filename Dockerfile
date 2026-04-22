FROM node:20-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    git \
    curl \
    jq \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Install OpenAI Codex CLI globally
RUN npm install -g @openai/codex

# Install nvm for the node user so agents can install/switch Node versions.
# BASH_ENV makes nvm available in non-interactive `bash -c` commands (what
# the Codex shell tool uses). The init script guards `set -eu` so it is safe
# to source from the entrypoint, which runs with `set -euo pipefail`.
ENV NVM_DIR=/home/node/.nvm
ENV NVM_VERSION=v0.40.1
ENV BASH_ENV=/home/node/.nvm_init.sh
RUN mkdir -p "$NVM_DIR" \
    && curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" \
       | NVM_DIR="$NVM_DIR" PROFILE=/dev/null bash \
    && printf '%s\n' \
       'export NVM_DIR="/home/node/.nvm"' \
       'if [ -s "$NVM_DIR/nvm.sh" ]; then' \
       '  __nvm_prev=$(set +o)' \
       '  set +eu' \
       '  . "$NVM_DIR/nvm.sh"' \
       '  eval "$__nvm_prev"' \
       '  unset __nvm_prev' \
       'fi' \
       > "$BASH_ENV" \
    && echo '[ -f "$BASH_ENV" ] && . "$BASH_ENV"' >> /home/node/.bashrc \
    && chown -R node:node "$NVM_DIR" "$BASH_ENV" /home/node/.bashrc

# Prepare home directory for node user
RUN mkdir -p /home/node/.codex \
    && chown -R node:node /home/node/.codex

VOLUME /usercontent

WORKDIR /runner
COPY ./scripts ./

RUN chmod +x /runner/*.sh

# Starts as root; entrypoint fixes volume ownership then drops to node
ENTRYPOINT ["/runner/entrypoint.sh"]
