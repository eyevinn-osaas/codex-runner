# codex-runner

Run headless [OpenAI Codex CLI](https://github.com/openai/codex) sessions in a container. You provide a git repository and a prompt, the runner clones the repo and executes the task using `codex exec`.

Built for [Eyevinn Open Source Cloud](https://www.osaas.io).

## Environment Variables

### Required

| Variable | Description |
| --- | --- |
| `SOURCE_URL` | Git repository URL to clone. Append `#branch` for a specific branch. Alias: `GITHUB_URL` |
| `PROMPT` | The task / prompt for Codex to execute |

### Authentication (one required)

| Variable | Description |
| --- | --- |
| `CODEX_API_KEY` | OpenAI API key for Codex |
| `OPENAI_API_KEY` | OpenAI API key (alias, normalized to `CODEX_API_KEY`) |

### Optional

| Variable | Description |
| --- | --- |
| `GIT_TOKEN` | Token for cloning private repositories. Alias: `GITHUB_TOKEN`. Works with GitHub PATs and Gitea-style tokens |
| `MODEL` | Model to use (e.g. `o3-mini`, `gpt-4.1`) |
| `SANDBOX` | Sandbox mode: `read-only`, `workspace-write`, or `danger-full-access` (default: `danger-full-access`). The `read-only` and `workspace-write` modes use bubblewrap which requires `SYS_ADMIN` capability that most containers lack. The container itself provides isolation |
| `SUB_PATH` | Subdirectory within the repo to use as working directory |
| `CONFIG_SVC` | Name of an OSC Application Config Service instance. When set together with `OSC_ACCESS_TOKEN`, environment variables are loaded from the config service before the Codex session starts |
| `OSC_ACCESS_TOKEN` | Open Source Cloud access token. Enables the OSC MCP server and config service integration |
| `CONFIG_API_KEY` | API key for encrypted parameter store. When set alongside `OSC_ACCESS_TOKEN` and `CONFIG_SVC`, secret parameters are decrypted before being injected as environment variables. |

## Usage

### Docker

```bash
docker build -t codex-runner .

docker run --rm \
  -e OPENAI_API_KEY="sk-..." \
  -e SOURCE_URL="https://github.com/myorg/my-repo" \
  -e PROMPT="Run the daily report task" \
  codex-runner
```

### Private Repository (GitHub)

```bash
docker run --rm \
  -e OPENAI_API_KEY="sk-..." \
  -e SOURCE_URL="https://github.com/myorg/private-repo" \
  -e GIT_TOKEN="ghp_xxxxxxxxxxxx" \
  -e PROMPT="Analyze the codebase and create a summary" \
  codex-runner
```

### Private Repository (Gitea / self-hosted)

```bash
docker run --rm \
  -e OPENAI_API_KEY="sk-..." \
  -e SOURCE_URL="https://gitea.example.com/org/repo" \
  -e GIT_TOKEN="your-gitea-token" \
  -e PROMPT="Run the agent task" \
  codex-runner
```

### Specific Branch

```bash
docker run --rm \
  -e OPENAI_API_KEY="sk-..." \
  -e SOURCE_URL="https://github.com/myorg/repo#develop" \
  -e PROMPT="Test the feature branch" \
  codex-runner
```

### Full System Access

```bash
docker run --rm \
  -e OPENAI_API_KEY="sk-..." \
  -e SOURCE_URL="https://github.com/myorg/repo" \
  -e SANDBOX="danger-full-access" \
  -e PROMPT="Fix the failing tests and commit" \
  codex-runner
```

## What Goes in the Repository

The cloned repository should contain configuration for the Codex CLI:

- `AGENTS.md` - Agent instructions and context for Codex
- `.codex/` - Optional directory with configuration
- Any source code Codex should work with

## Behavior

1. Validates required environment variables (fails fast if missing)
2. Clones the repository (with token auth for private repos)
3. Optionally navigates to `SUB_PATH`
4. Authenticates the GitHub CLI if a GitHub token is available
5. Runs `codex exec --full-auto` with the provided prompt
6. All output is logged to stdout/stderr
7. Exits with Codex's exit code

## About Eyevinn Technology

[Eyevinn Technology](https://www.eyevinn.se) is an independent consultant firm specialized in video and streaming. We assist our customers in reducing their expenses and increasing revenue by enhancing the quality of their video and streaming services through innovative and cost-effective solutions.

## License

MIT
