# Marginalia — install

One-shot installer for [Marginalia](https://github.com/OktoLabsAI/marginalia), a
local-first knowledge graph you can drive from Claude Code (MCP), the CLI, or as
a Python library.

The current public prerelease is the immutable `0.0.41`: source tag
`aae59db84c2abd0e915ac4cb72c08e60209abe34`, wheel
[`marginalia-0.0.41-py3-none-any.whl`](https://github.com/OktoLabsAI/marginalia-dist/releases/download/v0.0.41/marginalia-0.0.41-py3-none-any.whl),
SHA-256 `6842a55fe5e1180c67e81035342ee8b300f5ff2ce2aafbe48129d709a76dbfa6`.
The exact Linux Docker+tmux lifecycle passed from public driver
`93d23c4f2504f333bd2a89250afa84d1762f020b`; its retained status-0 evidence is recorded below.
The real interactive Windows PowerShell 5.1 rehearsal then exposed three daemon-ownership defects
in the current wheel: Windows does not provide `os.fchmod`; its lifecycle lock covers a PID payload
byte that status and stop must read; and its venv launcher PID can differ from the runtime PID that
owns that lock. `0.0.41` is therefore permanently non-promotable, not a candidate waiting on one
final gate. No successful Windows release-lifecycle evidence exists for it. Its tag and wheel remain
immutable records; the fix requires a new source version and a complete rerun of the source,
artifact, distribution, Linux, and Windows release gates for that new version.
An unversioned source-candidate wheel has passed native Windows install plus daemon
start/status/stop, but that diagnostic smoke is not release evidence. Explicit authorization of a
new successor version is the sole current release blocker.

## Install On macOS Or Linux

```bash
curl -fsSL https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/install.sh | bash
```

## Install On Windows

**Known blocker:** the immutable `0.0.41` wheel cannot complete its Windows daemon lifecycle. Do
not treat this command as a release-qualified Windows path until an authorized successor passes the
native PowerShell lifecycle.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/install.ps1 | iex"
```

On macOS/Linux today, and on Windows only after a release-qualified successor, the installer takes
a fresh machine from zero to a running application wired into Claude Code:

1. installs [`uv`](https://docs.astral.sh/uv/) if missing and pins Python 3.12 (uv-managed — your system Python is untouched);
2. downloads the released Marginalia wheel and installs the `marginalia` + `kg` commands;
3. starts one application daemon without forcing a process-global vault (web UI/REST on `:7777`, MCP on `:8201`);
4. opens the plain loopback UI directly in your default browser;
5. lets you create, select, configure, and delete managed vaults inside the application;
6. registers Claude Code with the application-scoped MCP capability token.

Browser access on loopback does not use a cookie, bootstrap command, or URL token.
The MCP endpoint remains separately protected by its Bearer token.

## Requirements

- macOS or Linux with `curl` and `bash`, or Windows with PowerShell
- An LLM provider is optional: `explore` works without one, while `ask` and
  `remember` require one configured in the Web UI. `marginalia onboard` remains an explicit
  compatibility path for automation and installer preseeding.

## Options

Everything is overridable by environment variable — useful under `curl … | bash`:

| Variable | Default | Purpose |
|----------|---------|---------|
| `MARGINALIA_VAULT` | — | optional compatibility preseed: create this vault and run CLI onboarding before opening the app |
| `MARGINALIA_PACKS` | `core,research,personal` | compatibility-preseed type packs; requires `MARGINALIA_VAULT` |
| `MARGINALIA_LLM_PROVIDER` | — | provider id passed to `marginalia onboard` |
| `MARGINALIA_LLM_API_BASE` | — | provider base URL |
| `MARGINALIA_LLM_MODEL` | — | model name; also skips model discovery |
| `MARGINALIA_LLM_API_KEY_ENV` | — | `MARGINALIA_*` env var name for the provider key |
| `MARGINALIA_LLM_ALLOW_REMOTE` | — | `1` = confirm non-loopback LLM egress |
| `MARGINALIA_ONBOARD_NONINTERACTIVE` | — | `1` = run onboarding without prompts |
| `MARGINALIA_WHEEL` | — | install a specific wheel path/URL |
| `MARGINALIA_EXPECTED_VERSION` | current release | required version check; override with `MARGINALIA_WHEEL` for another release |
| `MARGINALIA_MANIFEST` | release manifest on this repository's `main` | manifest path/URL supplying wheel URL, version, and SHA-256 |
| `MARGINALIA_WHEEL_SHA256` | manifest SHA-256 | required when using a custom wheel without a manifest |
| `MARGINALIA_NO_SERVE` | — | `1` = install + configure only |
| `MARGINALIA_NO_OPEN` | — | `1` = start the verified daemon without opening a browser |
| `MARGINALIA_NO_MCP` | — | `1` = don't run `claude mcp add` |

The normal app-first installation needs no provider or vault environment variables.
For compatibility automation that intentionally preseeds a vault, set
`MARGINALIA_VAULT` and the onboarding options explicitly. Example, fully
non-interactive skip on macOS/Linux:

```bash
MARGINALIA_VAULT=mynotes \
MARGINALIA_ONBOARD_NONINTERACTIVE=1 \
MARGINALIA_LLM_PROVIDER=skip \
  bash -c 'curl -fsSL https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/install.sh | bash'
```

Example, fully non-interactive local endpoint on macOS/Linux:

```bash
MARGINALIA_VAULT=mynotes \
MARGINALIA_ONBOARD_NONINTERACTIVE=1 \
MARGINALIA_LLM_PROVIDER=custom \
MARGINALIA_LLM_API_BASE=http://localhost:1234/v1 \
MARGINALIA_LLM_MODEL=my-model \
  bash -c 'curl -fsSL https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/install.sh | bash'
```

Example, fully non-interactive on Windows:

```powershell
$env:MARGINALIA_VAULT = "mynotes"
$env:MARGINALIA_LLM_API_BASE = "http://localhost:1234/v1"
$env:MARGINALIA_LLM_MODEL = "my-model"
$env:MARGINALIA_ONBOARD_NONINTERACTIVE = "1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/install.ps1 | iex"
```

## Direct AWS Bedrock

The installer stays provider-neutral by default: it installs the complete
`serve` application aggregate plus `litellm`, then leaves vault and provider
management to the application. If `MARGINALIA_VAULT` is explicitly set, it
delegates that compatibility preseed to `marginalia onboard`. It does not install
AWS SDK dependencies or write Bedrock-specific `llm:` YAML.

If you configure direct `provider: bedrock` and Marginalia reports that `boto3`
is missing, reinstall the tool with the opt-in `bedrock` extra, then configure the same vault in
the Web UI. Explicit preseed automation may instead rerun `marginalia onboard`:

Stop the application daemon, reinstall the exact released wheel URL from
`release-manifest.json` with `[serve,litellm,bedrock]`, then restart the app and
configure the vault. Do not substitute the unrelated `marginalia` project on
PyPI for the manifest's wheel URL.

If you installed from a specific `MARGINALIA_WHEEL` or `MARGINALIA_SRC`, reuse
that same wheel URL or source checkout and add `bedrock` to the extras list, for
example:

```bash
uv tool install --force --python 3.12 \
  "<wheel-url>[serve,litellm,bedrock]"
```

AWS credentials and any remote endpoint approval remain outside the installer.
Use the Web UI for normal provider/model configuration. For explicit noninteractive preseed
automation, use `marginalia onboard` and pass `--allow-remote-llm --yes` only when approving remote
setup.

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
# Unpinned current-main preflight; final evidence must use the exact-SHA command below.
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
it first SHA-verifies the immutable v0.0.40 installer and manifest at dist commit
`19847892b7e129225011d21d6d1f2ce00f996458`, runs that predecessor with its
vault-scoped PID/token, forces successor activation to fail, and proves the exact
0.0.40 tool and daemon are restored. It then completes the real migration to the
successor's application-scoped PID/token and plain UI before starting the fresh
install lifecycle. That lifecycle verifies
application status, a plain loopback SPA fetch, and `marginalia ui --no-open`,
proves the default install starts with no forced vault, then creates a managed
vault for lifecycle testing,
exercises stopped and running updates, proves
custom-port refusal and refusal of a canonical locked application PID owner before replacement, injects an
activation failure, and verifies exact tool/config/daemon rollback. A
previous-tool-only sentinel with a stable recorded hash proves restoration even
when the candidate and previous package have the same version. The rehearsal
then stops cleanly. The retained pane must contain
`DOCKER_TMUX_RELEASE_LIFECYCLE_OK` exactly once and record pane exit status 0;
the individual `RELEASE_LIFECYCLE_*_OK` markers identify every required phase.
This profile is Linux-only and does not replace the separate real interactive
Windows PowerShell rehearsal.

### Immutable v0.0.41 Linux-only evidence

The retained v0.0.41 Linux rehearsal fetched the driver from exact public dist commit
`93d23c4f2504f333bd2a89250afa84d1762f020b`, after all three jobs in
[`distribution-gate` run 29333923002](https://github.com/OktoLabsAI/marginalia-dist/actions/runs/29333923002)
passed on that SHA. Its retained transcript is
[`evidence/v0.0.41/linux-docker-tmux-release-lifecycle.txt`](evidence/v0.0.41/linux-docker-tmux-release-lifecycle.txt),
SHA-256 `ec2b9701e3ac3274a7f31e244ffeddc73537e7e434d59bda0d1c5e08d1ef5141`
(53,651 bytes; 1,938 lines). It records the exact driver, installer, manifest, and immutable
v0.0.40 predecessor URLs and SHA-256 values. Every lifecycle marker occurs exactly once, including
the verified predecessor rollback and token-preserving application-scope migration, app-first
zero-vault startup, stopped/running updates, refusal paths, activation rollback, and final stop.
The final line records tmux pane status 0. This proves the exact Linux lifecycle only; it is not
successful cross-platform release evidence and does not override the Windows current-wheel blocker.

### Immutable historical v0.0.40 evidence

The final v0.0.40 Linux rehearsal fetched the driver from exact public dist commit
`3764845c7f92cae13e6f2b3b289665a06696d921`, after all three jobs in
[`distribution-gate` run 29265687564](https://github.com/OktoLabsAI/marginalia-dist/actions/runs/29265687564)
passed on that SHA. Its retained transcript is
[`evidence/v0.0.40/linux-docker-tmux-release-lifecycle.txt`](evidence/v0.0.40/linux-docker-tmux-release-lifecycle.txt),
SHA-256 `6b72dc5c4c2dbefd03772492234b9cf3f73e092644ef29469aa8ae431792101f`
(36,241 bytes; 1,270 lines). It records the exact driver, installer, and manifest
URLs plus their SHA-256 values; contains every lifecycle marker exactly once,
including `RELEASE_LIFECYCLE_PREVIOUS_TOOL_SENTINEL_OK`; records sentinel SHA-256
`478c57d828b23e24c31834f8d49aeafa8822fac5421d4266670216f38d2222b5`.
The final line records tmux pane status 0.

That transcript is retained as immutable evidence for the already-published
v0.0.40 artifact. Its authenticated-browser wording describes that historical
wheel and is not evidence for the successor's plain loopback UI or app-scoped
multi-vault lifecycle. The v0.0.41 transcript above independently proves only its Linux lifecycle;
the failed native Windows rehearsal makes that immutable artifact non-promotable. The v0.0.40 tag,
manifest history, wheel, and transcript remain immutable historical records.

The evidence, workflow, and this record must be committed together on `main`,
and every `distribution-gate` job must pass on that exact evidence commit before
the rehearsal is trusted. The evidence commit does not move the dist tag,
recreate the prerelease, or replace the wheel asset.

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
and `release-manifest.json` to that same SHA. The profile requires the real
Windows PowerShell 5.1 host and records `INPUT_REDIRECTED=False`; it does not
prompt because the default installation is app-first. A promotable candidate must end with
`WINDOWS_RELEASE_LIFECYCLE_OK`; no v0.0.41 rehearsal produced that successful release evidence.
The profile SHA-verifies the immutable v0.0.40
installer and manifest. Because that historical installer cannot preserve the quotes
in its three native Python version probes under PowerShell 5.1, the driver creates a
deterministic local compatibility copy changing only those probes, records
`PREDECESSOR_BOOTSTRAP_MODE=verified-ps51-quote-compat-copy` and its SHA-256. The native run then
reached the exact v0.0.40 wheel and failed on its missing `os.fchmod` before a running-predecessor
phase could complete. Current driver corrections are diagnostic history only: they do not prove a
successful predecessor lifecycle, repair `0.0.41`, or provide Windows release evidence. A future
authorized successor must exercise the complete lifecycle against its exact new wheel and exact
green public driver; it must not claim a Windows predecessor-running phase that never completed.
Retain the sandbox; do not add `-Cleanup` to an evidence run.
Publish only the deterministic `*.public.log` sanitized evidence. The `*.private.raw.log`
PowerShell transcript can contain Windows user/machine metadata and must remain private. The tester
stops any sandbox daemon even when a lifecycle assertion fails, while retaining both files for
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

- Web UI: `http://127.0.0.1:7777/` (opened automatically; `marginalia ui` reopens it)
- In Claude Code: *"remember this note: …"* then *"ask Marginalia about …"*
- Status: `marginalia status`
- Stop: `marginalia stop`
- Update: rerun the installer. It preserves a stopped application daemon, or
  drains and restarts the app without retargeting vault work.
- Uninstall the command: `uv tool uninstall marginalia` (vault data under
  `~/.marginalia` is intentionally left in place).

Install and update are transactional. The release wheel is downloaded and
checked against `release-manifest.json`, then installed and smoke-tested in a
temporary environment before the current daemon is stopped. The previous uv
tool environment and command launchers are retained until the new package,
version, and requested application-daemon state are verified. Any activation or restart
failure restores the exact previous tool; a previously running daemon is also
restarted. The one-release v0.0.40 compatibility seam recognizes only a verified
matching vault-scoped lifecycle lock, refuses custom-port or unverified legacy
processes before replacement, and restarts the old CLI without assuming newer
`--no-open` support. Vaults and provider configuration are outside this
transaction and are never replaced.

When overriding `MARGINALIA_WHEEL`, also provide a matching
`MARGINALIA_MANIFEST` or `MARGINALIA_WHEEL_SHA256`, and override
`MARGINALIA_EXPECTED_VERSION` when installing another version.

The installer creates an authenticated user-scope Claude MCP entry. Do not add
the raw `:8201/mcp` URL without its Bearer header; it will correctly return
`401 Unauthorized`. To pin a project to another vault, add a project-scope HTTP
entry with `?vault=<name>` and the application token from
`~/.marginalia/daemon-7777.token`.

## Connect multiple projects

One daemon serves many vaults. Browser tabs select a vault independently inside
the app; switching one tab does not retarget curator, ingest, watch, or MCP work
already running for another vault. Create and select managed vaults in the UI.
Managed vault deletion requires exact-name confirmation and removes only vaults
created by Marginalia; adopted/external paths are protected from deletion.

Each MCP connection selects its vault via `?vault=` (a registered name, or a
loopback-only absolute path). The configured default remains a compatibility
fallback for unscoped CLI/MCP clients, not a process-global server selection.

LLM and embedding provider keys use the same managed credential flow in the UI.
Keys are entered as secrets and are never written into vault YAML; explicit
environment-variable references remain available as an advanced configuration
option. POSIX stores managed values in an owner-only environment file; Windows stores each value as
a CurrentUser-DPAPI envelope so plaintext is absent at rest. The embedding connection test performs
a real provider call and returns metadata only, never the key or vector payload.
