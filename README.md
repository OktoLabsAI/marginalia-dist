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
6. registers Claude Code with the daemon's private capability token.

## Requirements

- macOS or Linux with `curl` and `bash`, or Windows with PowerShell
- An LLM provider is optional: `explore` works without one, while `ask` and
  `remember` require one configured by `marginalia onboard`.

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
| `MARGINALIA_EXPECTED_VERSION` | `0.0.40` | required version check; override with `MARGINALIA_WHEEL` for another release |
| `MARGINALIA_MANIFEST` | release manifest on this repository's `main` | manifest path/URL supplying wheel URL, version, and SHA-256 |
| `MARGINALIA_WHEEL_SHA256` | manifest SHA-256 | required when using a custom wheel without a manifest |
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

## Direct AWS Bedrock

The public installer stays provider-neutral by default: it installs
`embeddings,ladybug,mcp,litellm`, creates or selects the vault, and delegates
provider setup to `marginalia onboard`. It does not install AWS SDK dependencies
or write Bedrock-specific `llm:` YAML.

If you configure direct `provider: bedrock` and Marginalia reports that `boto3`
is missing, reinstall the tool with the opt-in `bedrock` extra, then rerun
onboarding for the same vault:

```bash
marginalia stop --vault mynotes || true
uv tool install --force --python 3.12 \
  "https://github.com/OktoLabsAI/marginalia-dist/releases/download/v0.0.40/marginalia-0.0.40-py3-none-any.whl[embeddings,ladybug,mcp,litellm,bedrock]"
marginalia onboard --vault mynotes --reconfigure
```

```powershell
marginalia stop --vault mynotes
uv tool install --force --python 3.12 "https://github.com/OktoLabsAI/marginalia-dist/releases/download/v0.0.40/marginalia-0.0.40-py3-none-any.whl[embeddings,ladybug,mcp,litellm,bedrock]"
marginalia onboard --vault mynotes --reconfigure
```

If you installed from a specific `MARGINALIA_WHEEL` or `MARGINALIA_SRC`, reuse
that same wheel URL or source checkout and add `bedrock` to the extras list, for
example:

```bash
uv tool install --force --python 3.12 \
  "<wheel-url>[embeddings,ladybug,mcp,litellm,bedrock]"
```

AWS credentials and any remote endpoint approval remain outside the installer.
Use `marginalia onboard` for provider/model configuration, and pass
`--allow-remote-llm --yes` only for explicit noninteractive remote setup.

## Safe Onboarding Test

To test the full macOS/Linux onboarding flow without touching your real
`~/.marginalia` vaults or Claude config:

```bash
./test-install.sh
```

The test wrapper uses an isolated `HOME`, disables MCP registration, and deletes
only prior sandboxes carrying its ownership marker. It refuses unowned paths,
tmux sessions, and Docker containers. It keeps the new sandbox after the run so
you can inspect the vault and UI. To run a
noninteractive install-only smoke test and delete the sandbox afterward:

```bash
./test-install.sh --api-base http://localhost:1234/v1 --model my-model --no-serve --cleanup
```

Canonical human-prompt tests use tmux and still install from the raw URL. These
examples keep the new sandbox so the current `capture-pane` evidence remains;
add `--cleanup` only for throwaway smoke runs.

```bash
# Local-only lifecycle preflight; final evidence must use the exact-SHA command below.
./test-install.sh --docker-tmux --profile release-lifecycle
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

`release-lifecycle` is the canonical Linux release rehearsal. Fetch the tester
from the exact green dist commit and pass that same SHA back to the tester:

```bash
DIST_DRIVER_SHA=<exact-green-dist-driver-sha>
curl -fsSLo /tmp/marginalia-test-install.sh \
  "https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/${DIST_DRIVER_SHA}/test-install.sh"
bash /tmp/marginalia-test-install.sh --docker-tmux \
  --profile release-lifecycle --driver-commit "$DIST_DRIVER_SHA"
```

The tester byte-compares itself with the exact public raw driver, pins the
installer and manifest to that same commit, and records all three URLs and
SHA-256 values in the pane. In one fresh Ubuntu container and one real tmux TTY
it verifies
authenticated status, an authenticated SPA fetch, and `marginalia ui --no-open`,
exercises stopped and running updates, proves
custom-port and unverified-live-PID refusal before replacement, injects an
activation failure, and verifies exact tool/config/daemon rollback. A
previous-tool-only sentinel with a stable recorded hash proves restoration even
when the candidate and previous package have the same version. The rehearsal
then stops cleanly. The retained pane must end with
`DOCKER_TMUX_RELEASE_LIFECYCLE_OK`; the individual `RELEASE_LIFECYCLE_*_OK`
markers identify every required phase. This profile is Linux-only and does not
replace the separate real interactive Windows PowerShell rehearsal.

The current local-uncommitted preflight transcript is staged as
[`evidence/v0.0.40/linux-docker-tmux-release-lifecycle.txt`](evidence/v0.0.40/linux-docker-tmux-release-lifecycle.txt),
SHA-256 `aeeedd896594a9e34545976f72d2ab78480c3650bb88c6ca331b06f5ec57b290`
(35,995 bytes; 1,268 lines). The transcript contains every lifecycle marker
exactly once, including `RELEASE_LIFECYCLE_PREVIOUS_TOOL_SENTINEL_OK`, and
records sentinel SHA-256
`478c57d828b23e24c31834f8d49aeafa8822fac5421d4266670216f38d2222b5`.
This is preflight evidence, not the final release rehearsal: after the driver
commit is public and `distribution-gate` is green on its exact SHA, rerun the
exact command above and replace this
transcript and hash with the resulting public-driver evidence.

Release evidence is produced after the immutable release asset exists. Commit
the final tester, workflow, README, and retained transcript together on `main`,
push that evidence commit, and require every `distribution-gate` job to pass on
its exact SHA before trusting the rehearsal. This evidence commit must not move
the dist tag, recreate the prerelease, or replace the wheel asset.

Windows uses a matching PowerShell tester. Run it from an interactive Windows
PowerShell 5.1 terminal, not PowerShell 7, macOS/Linux PowerShell, or Docker:

```powershell
$DistDriverSha = "<exact-green-dist-driver-sha>"
$Driver = Join-Path $env:TEMP "marginalia-test-install.ps1"
Invoke-WebRequest -UseBasicParsing `
  "https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/$DistDriverSha/test-install.ps1" `
  -OutFile $Driver
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -NoProfile -ExecutionPolicy Bypass -File $Driver `
  -Profile release-lifecycle -DriverCommit $DistDriverSha
```

The Windows tester starts a child PowerShell with an isolated `HOME`,
`USERPROFILE`, `APPDATA`, `LOCALAPPDATA`, `TEMP`, `TMP`, `XDG_*`, and every uv
install/tool/Python/cache path, disables
Claude MCP registration, prevents uv from modifying the user PATH or Windows
Python registry, runs the public raw `install.ps1` URL, and writes a transcript
under its uniquely owned temp sandbox. For release-lifecycle, the driver
byte-compares itself with the exact public raw commit and pins `install.ps1`
and `release-manifest.json` to that same SHA. The profile requires
`INPUT_REDIRECTED=False`: at the live provider prompt, enter `0` to select
`Skip LLM setup`. The tester verifies that this choice was made interactively,
then must end with `WINDOWS_RELEASE_LIFECYCLE_OK`. Its phase markers cover
interactive onboarding, fresh install, authenticated status and SPA/UI access,
stopped and running updates, custom-port refusal, unverified-live-PID refusal,
hash-verified restoration of a previous-tool-only sentinel after forced
activation failure, and final stop. Retain the sandbox; do not add `-Cleanup`
to the evidence run. Publish only the deterministic `*.public.log` sanitized
evidence. The `*.private.raw.log` PowerShell transcript can contain Windows
user/machine metadata and must remain private. The tester stops any sandbox
daemon even when a lifecycle assertion fails, while retaining both files for
diagnosis. It refuses unowned test directories and resource-name collisions.
For a smaller noninteractive smoke check:

```powershell
.\test-install.ps1 -Profile skip -Cleanup
.\test-install.ps1 -Profile custom -ApiBase http://127.0.0.1:8123/v1 -Model local-model -NoServe -Cleanup
```

Windows coverage must be driven in a real Windows PowerShell terminal; Docker,
script parsing, or macOS/Linux PowerShell is not a substitute. The skip and
custom profile commands are noninteractive configuration smoke checks, not
release-lifecycle evidence.

## After install

- Web UI: `marginalia ui` (opens an authenticated browser session)
- In Claude Code: *"remember this note: …"* then *"ask Marginalia about …"*
- Status: `marginalia status`
- Stop: `marginalia stop --vault mynotes`
- Update: rerun the installer. It preserves a stopped daemon, or drains and
  restarts the same active vault when the daemon was running.
- Uninstall the command: `uv tool uninstall marginalia` (vault data under
  `~/.marginalia` is intentionally left in place).

Install and update are transactional. The release wheel is downloaded and
checked against `release-manifest.json`, then installed and smoke-tested in a
temporary environment before the current daemon is stopped. The previous uv
tool environment and command launchers are retained until the new package,
version, and requested daemon state are verified. Any activation or restart
failure restores the exact previous tool; a previously running daemon is also
restarted. Vaults and provider configuration are outside this transaction and
are never replaced.

When overriding `MARGINALIA_WHEEL`, also provide a matching
`MARGINALIA_MANIFEST` or `MARGINALIA_WHEEL_SHA256`, and override
`MARGINALIA_EXPECTED_VERSION` when installing another version.

The installer creates an authenticated user-scope Claude MCP entry. Do not add
the raw `:8201/mcp` URL without its Bearer header; it will correctly return
`401 Unauthorized`. To pin a project to another vault, add a project-scope HTTP
entry with `?vault=<name>` and the same token from that vault's private
`.marginalia/daemon.token` file.

## Connect multiple projects (multi-vault)

One daemon serves many vaults. Each MCP connection selects its own via `?vault=`
(a registered name, or a loopback-only absolute path). Create more vaults with
`marginalia vault create <name> --use`, or the `init_vault` MCP tool.
