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
4. asks for your LLM endpoint (any OpenAI-compatible server — LM Studio, Ollama, llama.cpp, vLLM, a remote box). Press Enter to skip; `explore` works immediately, `ask`/`remember` after you add the endpoint;
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
| `MARGINALIA_LLM_API_BASE` | — | LLM base URL (skips the prompt) |
| `MARGINALIA_LLM_MODEL` | — | LLM model name (skips the prompt) |
| `MARGINALIA_WHEEL` | — | install a specific wheel path/URL |
| `MARGINALIA_NO_SERVE` | — | `1` = install + configure only |
| `MARGINALIA_NO_MCP` | — | `1` = don't run `claude mcp add` |

Example, fully non-interactive on macOS/Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/install.sh \
  | MARGINALIA_LLM_API_BASE=http://localhost:1234/v1 MARGINALIA_LLM_MODEL=my-model bash
```

Example, fully non-interactive on Windows:

```powershell
$env:MARGINALIA_LLM_API_BASE = "http://localhost:1234/v1"
$env:MARGINALIA_LLM_MODEL = "my-model"
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/install.ps1 | iex"
```

## Safe Onboarding Test

To test the full macOS/Linux onboarding flow without touching your real
`~/.marginalia` vaults or Claude config:

```bash
./test-install.sh
```

The test wrapper uses a fresh isolated `HOME`, disables MCP registration, and
keeps the sandbox so you can inspect the vault and UI. To run a noninteractive
install-only smoke test and delete the sandbox afterward:

```bash
./test-install.sh --api-base http://localhost:1234/v1 --model my-model --no-serve --cleanup
```

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
