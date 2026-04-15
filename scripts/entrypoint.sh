#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# codex-runner — Run a headless OpenAI Codex CLI session
# against a git repository.
# ============================================================

# ------------------------------------------------------------------
# 0. Fix volume ownership (runs as root, then drops to node)
# ------------------------------------------------------------------

if [ "$(id -u)" = "0" ]; then
  chown -R node:node /usercontent
  exec runuser -u node -- "$0" "$@"
fi

echo "=== codex-runner ==="
echo "Starting at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ------------------------------------------------------------------
# 1. Validate required environment variables
# ------------------------------------------------------------------

# Auth: CODEX_API_KEY (or OPENAI_API_KEY) must be set
if [ -z "${CODEX_API_KEY:-}" ] && [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "ERROR: Either CODEX_API_KEY or OPENAI_API_KEY must be set" >&2
  exit 1
fi

# Normalize: Codex CLI uses CODEX_API_KEY but also accepts OPENAI_API_KEY
if [ -z "${CODEX_API_KEY:-}" ] && [ -n "${OPENAI_API_KEY:-}" ]; then
  export CODEX_API_KEY="${OPENAI_API_KEY}"
fi

# Source repository URL (required)
SOURCE_URL="${SOURCE_URL:-${GITHUB_URL:-}}"
if [ -z "${SOURCE_URL}" ]; then
  echo "ERROR: SOURCE_URL (or GITHUB_URL) is required — the git repository to clone" >&2
  exit 1
fi

# Prompt / task (required)
PROMPT="${PROMPT:?PROMPT env var is required — the task for Codex to perform}"

# Optional settings
MODEL="${MODEL:-}"
MAX_TURNS="${MAX_TURNS:-}"
ALLOWEDTOOLS="${ALLOWEDTOOLS:-}"
DISALLOWEDTOOLS="${DISALLOWEDTOOLS:-}"
SUB_PATH="${SUB_PATH:-}"
SANDBOX="${SANDBOX:-workspace-write}"

echo "Source:      ${SOURCE_URL}"
echo "Model:       ${MODEL:-<default>}"
echo "Max turns:   ${MAX_TURNS:-<unlimited>}"
echo "Sub path:    ${SUB_PATH:-<root>}"
echo "Sandbox:     ${SANDBOX:-<default>}"
echo "===================="

# ------------------------------------------------------------------
# 2. Clone the repository
# ------------------------------------------------------------------

WORK_DIR="/usercontent"

# Parse the source URL — extract host and path for token injection
# Strip any branch ref (fragment after #)
BRANCH=""
if [[ "${SOURCE_URL}" == *"#"* ]]; then
  BRANCH="${SOURCE_URL##*#}"
  SOURCE_URL="${SOURCE_URL%%#*}"
fi

# Determine the git token to use
GIT_TOKEN="${GIT_TOKEN:-${GITHUB_TOKEN:-}}"

# Build the authenticated clone URL
CLONE_URL="${SOURCE_URL}"
if [ -n "${GIT_TOKEN}" ]; then
  # Strip protocol prefix to rebuild with token
  URL_WITHOUT_PROTO="${SOURCE_URL#https://}"
  URL_WITHOUT_PROTO="${URL_WITHOUT_PROTO#http://}"
  CLONE_URL="https://${GIT_TOKEN}@${URL_WITHOUT_PROTO}"
  echo "Cloning private repository (token injected)..."
else
  echo "Cloning public repository..."
fi

CLONE_ARGS=("--depth" "1")
if [ -n "${BRANCH}" ]; then
  CLONE_ARGS+=("--branch" "${BRANCH}")
  echo "Branch: ${BRANCH}"
fi

git clone "${CLONE_ARGS[@]}" "${CLONE_URL}" "${WORK_DIR}" 2>&1
echo "Repository cloned successfully."

# Navigate to work directory (optionally into sub-path)
if [ -n "${SUB_PATH}" ]; then
  WORK_DIR="${WORK_DIR}/${SUB_PATH}"
  if [ ! -d "${WORK_DIR}" ]; then
    echo "ERROR: SUB_PATH '${SUB_PATH}' does not exist in the repository" >&2
    exit 1
  fi
  echo "Using sub-path: ${SUB_PATH}"
fi

cd "${WORK_DIR}"
echo "Working directory: $(pwd)"

# Show repo info
if [ -f "AGENTS.md" ]; then
  echo "Found AGENTS.md in repository."
fi
if [ -f "CLAUDE.md" ]; then
  echo "Found CLAUDE.md in repository."
fi
if [ -d ".codex" ]; then
  echo "Found .codex/ directory in repository."
fi

# ------------------------------------------------------------------
# 3. Load environment variables from config service (if available)
# ------------------------------------------------------------------

if [ -n "${OSC_ACCESS_TOKEN:-}" ] && [ -n "${CONFIG_SVC:-}" ]; then
  # Refresh the access token via the runner token service
  REFRESH_RESULT=$(curl -sf -X POST \
    "https://token.svc.${OSC_ENV:-prod}.osaas.io/runner-token/refresh" \
    -H "Content-Type: application/json" \
    -d "{\"token\":\"${OSC_ACCESS_TOKEN}\"}" 2>/dev/null) || true
  if [ -n "${REFRESH_RESULT:-}" ]; then
    FRESH_PAT=$(echo "${REFRESH_RESULT}" | jq -r '.token // empty')
    if [ -n "${FRESH_PAT}" ]; then
      export OSC_ACCESS_TOKEN="${FRESH_PAT}"
      echo "[CONFIG] Refreshed access token via runner refresh token"
    fi
  fi

  echo "[CONFIG] Loading environment variables from config service '${CONFIG_SVC}'"
  config_env_output=$(npx -y @osaas/cli@latest web config-to-env "${CONFIG_SVC}" 2>&1) || true
  config_exit=$?
  if [ ${config_exit} -eq 0 ]; then
    # Only eval lines that are valid shell export statements
    valid_exports=$(echo "${config_env_output}" | grep "^export [A-Za-z_][A-Za-z0-9_]*=" || true)
    if [ -n "${valid_exports}" ]; then
      eval "${valid_exports}"
      var_count=$(echo "${valid_exports}" | wc -l | tr -d ' ')
      echo "[CONFIG] Loaded ${var_count} environment variable(s)"
    else
      echo "[CONFIG] WARNING: Config service returned success but no valid export statements."
      echo "[CONFIG] Raw output: ${config_env_output}"
    fi
  else
    echo "[CONFIG] ERROR: Failed to load config from '${CONFIG_SVC}' (exit code ${config_exit})."
    echo "[CONFIG] Raw output: ${config_env_output}"
    if echo "${config_env_output}" | grep -qi "expired\|unauthorized\|401"; then
      echo "[CONFIG] Your OSC_ACCESS_TOKEN may have expired. Refresh it and retry."
    fi
  fi
fi

# ------------------------------------------------------------------
# 4. Configure GitHub CLI (if token available)
# ------------------------------------------------------------------

if [ -n "${GIT_TOKEN}" ]; then
  # Configure git to use the token for any subsequent operations
  git config --global url."https://${GIT_TOKEN}@github.com/".insteadOf "https://github.com/"
fi

if [ -n "${GITHUB_TOKEN:-}" ]; then
  echo "${GITHUB_TOKEN}" | gh auth login --with-token 2>/dev/null && \
    echo "GitHub CLI authenticated." || \
    echo "GitHub CLI authentication skipped (token may not be a GitHub PAT)."
fi

# ------------------------------------------------------------------
# 5. Configure OSC MCP server (if token available)
# ------------------------------------------------------------------

if [ -n "${OSC_ACCESS_TOKEN:-}" ]; then
  echo "Configuring OSC MCP server for Codex..."
  mkdir -p "${HOME}/.codex"
  cat > "${HOME}/.codex/config.json" <<MCPEOF
{
  "mcpServers": {
    "OSC": {
      "type": "http",
      "url": "https://mcp.osaas.io/mcp",
      "headers": {
        "Authorization": "Bearer ${OSC_ACCESS_TOKEN}"
      }
    }
  }
}
MCPEOF
  echo "OSC MCP server configured (https://mcp.osaas.io/mcp)"
fi

# ------------------------------------------------------------------
# 6. Build the Codex command
# ------------------------------------------------------------------

CODEX_ARGS=("exec")

# Full-auto mode for headless operation (no approval prompts)
CODEX_ARGS+=("--full-auto")

if [ -n "${MODEL}" ]; then
  CODEX_ARGS+=("--model" "${MODEL}")
fi

if [ -n "${SANDBOX}" ]; then
  CODEX_ARGS+=("--sandbox" "${SANDBOX}")
fi

# ------------------------------------------------------------------
# 7. Run the Codex session
# ------------------------------------------------------------------

echo ""
echo "=== Codex session starting ==="
echo "Prompt: ${PROMPT}"
echo "================================"
echo ""

# Export auth token so Codex CLI can pick it up
export CODEX_API_KEY="${CODEX_API_KEY:-}"

# Disable telemetry in CI/container context
export CODEX_DISABLE_TELEMETRY=1

# Run codex exec with the prompt — all output goes to stdout/stderr
codex "${CODEX_ARGS[@]}" "${PROMPT}"

EXIT_CODE=$?

echo ""
echo "=== Codex session ended ==="
echo "Exit code: ${EXIT_CODE}"
echo "Finished at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

exit ${EXIT_CODE}
