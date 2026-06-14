# Marginalia — install

One-shot installer for [Marginalia](https://github.com/OktoLabsAI/marginalia), a
local-first knowledge graph you can drive from Claude Code (MCP), the CLI, or as
a Python library.

## Install On macOS Or Linux

```bash
curl -fsSL https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/install.sh | bash
```

## Install On Windows

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/install.ps1 | iex"
```

This takes a fresh machine from zero to a running daemon wired into Claude Code:

1. installs [`uv`](https://docs.astral.sh/uv/) if missing and pins Python 3.12 (uv-managed — your system Python is untouched);
2. downloads the released Marginalia wheel and installs the `marginalia` + `kg` commands;
3. creates a vault (`~/.marginalia/vaults/mynotes`);
4. runs `marginalia onboard`, a provider-first wizard for auto-detect, LM Studio, Ollama, LiteLLM Proxy, OpenRouter, OpenAI, Gemini, Anthropic, custom endpoints, or skip;
5. starts the server (web UI/REST on `:7777`, MCP on `:8201`);
6. registers the MCP server with Claude Code.

## Requirements

- macOS or Linux with `curl` and `bash`, or Windows with PowerShell
- An OpenAI-compatible LLM endpoint for `ask` / `remember` (embeddings run locally, no setup)

## Options

Everything is overridable by environment variable — useful under `curl … | bash`:

| Variable | Default | Purpose |
|----------|---------|---------|
| `MARGINALIA_VAULT` | `mynotes` | vault name |
| `MARGINALIA_PACKS` | `core,research,personal` | type packs |
| `MARGINALIA_LLM_PROVIDER` | — | provider id passed to `marginalia onboard` |
| `MARGINALIA_LLM_API_BASE` | — | provider base URL |
| `MARGINALIA_LLM_MODEL` | — | model name; also skips model discovery |
| `MARGINALIA_LLM_API_KEY_ENV` | — | `MARGINALIA_*` env var name for the provider key |
| `MARGINALIA_LLM_ALLOW_REMOTE` | — | `1` = confirm non-loopback LLM egress |
| `MARGINALIA_ONBOARD_NONINTERACTIVE` | — | `1` = run onboarding without prompts |
| `MARGINALIA_WHEEL` | — | install a specific wheel path/URL |
| `MARGINALIA_NO_SERVE` | — | `1` = install + configure only |
| `MARGINALIA_NO_MCP` | — | `1` = don't run `claude mcp add` |

Example, fully non-interactive skip on macOS/Linux:

```bash
MARGINALIA_ONBOARD_NONINTERACTIVE=1 \
MARGINALIA_LLM_PROVIDER=skip \
  bash -c 'curl -fsSL https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/install.sh | bash'
```

Example, fully non-interactive local endpoint on macOS/Linux:

```bash
MARGINALIA_ONBOARD_NONINTERACTIVE=1 \
MARGINALIA_LLM_PROVIDER=custom \
MARGINALIA_LLM_API_BASE=http://localhost:1234/v1 \
MARGINALIA_LLM_MODEL=my-model \
  bash -c 'curl -fsSL https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/install.sh | bash'
```

Example, fully non-interactive on Windows:

```powershell
$env:MARGINALIA_LLM_API_BASE = "http://localhost:1234/v1"
$env:MARGINALIA_LLM_MODEL = "my-model"
$env:MARGINALIA_ONBOARD_NONINTERACTIVE = "1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/install.ps1 | iex"
```

## Safe Onboarding Test

To test the full macOS/Linux onboarding flow without touching your real
`~/.marginalia` vaults or Claude config:

```bash
./test-install.sh
```

The test wrapper uses an isolated `HOME`, disables MCP registration, and deletes
previous `marginalia-install-test*` sandboxes before it starts. It keeps the new
sandbox after the run so you can inspect the vault and UI. To run a
noninteractive install-only smoke test and delete the sandbox afterward:

```bash
./test-install.sh --api-base http://localhost:1234/v1 --model my-model --no-serve --cleanup
```

Canonical human-prompt tests use tmux and still install from the raw URL. These
examples keep the new sandbox so the current `capture-pane` evidence remains;
add `--cleanup` only for throwaway smoke runs.

```bash
# Fresh Linux image in Docker, prompts driven through tmux.
./test-install.sh --docker-tmux --profile skip
./test-install.sh --docker-tmux --profile auto-lm-studio
./test-install.sh --docker-tmux --profile lm-studio
./test-install.sh --docker-tmux --profile ollama
./test-install.sh --docker-tmux --profile litellm
./test-install.sh --docker-tmux --profile hosted-openai
./test-install.sh --docker-tmux --profile hosted-openrouter
./test-install.sh --docker-tmux --profile hosted-gemini
./test-install.sh --docker-tmux --profile hosted-anthropic
./test-install.sh --docker-tmux --profile existing-keep
./test-install.sh --docker-tmux --profile existing-inspect
./test-install.sh --docker-tmux --profile existing-reconfigure
./test-install.sh --docker-tmux --profile disable-llm
./test-install.sh --docker-tmux --profile custom --api-base http://127.0.0.1:1234/v1 --model docker-custom-human-model

# macOS/Linux host with isolated HOME, prompts driven through tmux.
./test-install.sh --tmux --profile skip
./test-install.sh --tmux --profile existing-inspect
./test-install.sh --tmux --profile custom --api-base http://127.0.0.1:8123/v1 --model macos-custom-human-model
```

The scripted profiles cover skip, auto-detect, LM Studio, Ollama, LiteLLM
Proxy, OpenAI, OpenRouter, Gemini, Anthropic, existing-config keep,
existing-config inspect, existing-config reconfigure, disable, and custom
endpoints. Hosted profiles use a fake exported key and manual model; the tester
fails if that fake key appears in YAML or tmux evidence. Each tmux run writes
`capture-pane` evidence under the sandbox directory.

Windows uses a matching PowerShell tester. Run it from a real Windows
PowerShell terminal, not from macOS/Linux PowerShell or Docker:

```powershell
.\test-install.ps1
```

The Windows tester starts a child PowerShell with an isolated `HOME`,
`USERPROFILE`, `APPDATA`, `LOCALAPPDATA`, `XDG_*`, and `UV_CACHE_DIR`, disables
Claude MCP registration, runs the public raw `install.ps1` URL, and writes a
transcript under the sandbox. The transcript must show the public URL and
`INPUT_REDIRECTED=False`; then drive the provider prompt like a user. For a
noninteractive smoke check:

```powershell
.\test-install.ps1 -Profile skip -Cleanup
.\test-install.ps1 -Profile custom -ApiBase http://127.0.0.1:8123/v1 -Model local-model -NoServe -Cleanup
```

Windows coverage must be driven in a real Windows PowerShell terminal; Docker,
script parsing, or macOS/Linux PowerShell is not a substitute. The custom
profile command is a noninteractive YAML smoke check, not prompt coverage.

## After install

- Web UI: <http://127.0.0.1:7777>
- In Claude Code: *"remember this note: …"* then *"ask Marginalia about …"*
- Stop: `marginalia stop --vault mynotes`
- Pin a project to a vault in `.mcp.json`:
  `{"mcpServers":{"marginalia":{"type":"http","url":"http://127.0.0.1:8201/mcp?vault=mynotes"}}}`

## Connect multiple projects (multi-vault)

One daemon serves many vaults. Each MCP connection selects its own via `?vault=`
(a registered name, or a loopback-only absolute path). Create more vaults with
`marginalia vault create <name> --use`, or the `init_vault` MCP tool.
