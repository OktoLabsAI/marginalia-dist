# Marginalia — install

One-shot installer for [Marginalia](https://github.com/OktoLabsAI/marginalia), a
local-first knowledge graph you can drive from Claude Code (MCP), the CLI, or as
a Python library.

The current release is `0.2.0`, a prerelease: source tag
`v0.2.0` at commit `314e3af15a901c71c0bcb7af75a63f081298859f`, wheel
[`marginalia-0.2.0-py3-none-any.whl`](https://github.com/OktoLabsAI/marginalia-dist/releases/download/v0.2.0/marginalia-0.2.0-py3-none-any.whl),
SHA-256 `59adee4483d8f85525e30a5e6271e6328238ac275d4b3fe05e29325d2ed29520`,
1,275,757 bytes. It succeeds the `0.1.0` prerelease. The verification status below
records what ran for this exact release, what did not, and why `0.2.0` is not
designated stable.

`0.2.0` is a reliability release on top of the `0.1.0` agent-facing MCP surface.
What changed since `0.1.0`:

1. **ChatGPT subscription sign-in from the CLI.** `marginalia provider login chatgpt`
   runs an interactive device-code login into Marginalia's own credential directory. It
   refuses `~/.codex` and `~/.pi/agent` (symlinks included), a non-TTY session, and an
   existing credential unless `--force` is given. `marginalia provider status chatgpt
   [--json]` is a read-only report of plan, account, subscription and token expiry that
   exits 1 when the credential is unusable.
2. **LoCoMo benchmark harness (source repo).** `--enable-chatgpt` scopes the ChatGPT
   opt-in to a single run, and `--ingest-concurrency` ingests several conversations at
   once. Each conversation keeps its own vault and daemon and its documents are still
   posted in order, so no vault's content changes.
3. **Transient provider errors are retried** in `ask` synthesis and in every ingest judge
   and curator step (curator, relation curator, merge judge, predicate resolution, type
   adjudication, correction judge, predicate-propose sweep judge). Same policy extraction
   already used: two attempts, retryable errors only, `Retry-After` capped at 60 s, and
   every retry recorded. A single 503 used to turn an answer into empty text or silently
   degrade the step. The reconcile cluster judge stays single-shot on purpose.
4. **A case-variant re-mention no longer wedges a vault.** A later document naming an
   existing entity with different capitalisation raised "node artifact differs from
   sealed plan", the plan was never receipted, and every later `remember` replayed it and
   failed. The sealed-plan applier now compares exactly what the node id is built from
   (type, folded title, content).
5. **Committing a parked manual-review item no longer wedges** when another document
   already committed the same node. The review path shares the same id-input comparison;
   a vault the old code wedged heals by re-running the same review resolution.
6. **Every `remember` write failure is logged on both MCP and REST.** Real graph-write
   failures log at ERROR with cause and traceback, caller mistakes at WARNING. REST
   previously logged nothing. Response codes are unchanged.
7. **`ingest_units_failed` is surfaced** in LoCoMo benchmark summaries, reports, compare
   output and the ledger, so a run that lost units can no longer read as clean.
8. **Neo4j backend: `DriverError` is translated** to `GraphBackendError` at every driver
   entry point (reads, writes, wipe, `Neo4jStaging`). A closed driver used to leak out of
   `get_node` untranslated.
9. **The bundled web UI was rebuilt** to match its source; it had not been rebuilt since
   `0.0.50`, so the provider panel was missing providers added in source.
10. **Private network addresses were removed from published docs**, including the
    README that ships as the wheel's long description.

Known issue in `0.2.0`: the contract test
`tests/store/contract/test_snapshot_concurrency.py::TestLadybugSnapshotPinnedDumpVsSwap::test_dump_never_mixes_pre_and_post_swap_rows`
fails under load. It is a race between the two renames in the Ladybug staging commit and
`LadybugStore.snapshot()` opening `graph.lbug` read-only. A deterministic probe that holds
the swap between the renames reproduces it identically on `0.1.0`, so it is pre-existing
and not a `0.2.0` regression. The owner waived it for this prerelease; it is not fixed.

`0.1.0` was the agent-facing MCP surface release (five tools, `ask` policy set per call,
per-source provenance, `synthesis_status` on every `ask`). The release notes below that
describe the `0.0.50` and `0.0.49` prereleases are kept as history from those releases.

`0.0.50` is an ingest-quality release. Defects were found by auditing actual graph
nodes over a 76-document corpus rather than by trusting counters:

1. **Literal claims are no longer silently discarded.** The per-block edge accumulator
   keyed literal claims on `dst_ref`, which is empty for a literal, so every literal
   claim sharing (predicate, subject, block) collapsed into the first. Replay recovered
   165 of 358 discarded claims with zero residual duplicates.
2. **Blocking no longer welds numbered items together.** A trailing numeric token was
   read as a surname, so `TASK-01` yielded `01` and every numbered item joined one
   blocking family, flooding the alias cap with identity-grade false pairs.
3. **The Web UI folder picker applies the same filter as the API.** A folder the walk
   reduced to 76 files was queued as 168; both paths now share one selection predicate.
4. **Unregistered predicates are resolved against the live registry at ingestion**
   (same / inverse / narrower / distinct) instead of being minted freely.
5. **Per-role `sampling_payload`** accepts a verbatim JSON dict, so a role can send
   provider-specific keys the managed parameter map could not express.
6. **`llm_request` traces report what is actually sent on the wire**, not pre-merge values.

The base-URL canonicalization below shipped in `0.0.49` and is unchanged in `0.0.50`:

1. **The base URL is canonicalized in a single resolver, regardless of the form typed.**
   Discovery used to probe `{base}/models` (treating user input as the server root) while
   completions POSTed `{base}/chat/completions` (treating input as already versioned), so a
   server root like `http://host:port` passed discovery but 404'd on the completion step,
   while a `/v1`-form base failed discovery on servers that only serve `/v1` (oMLX). Every
   input form (root, `root/`, `/v1`, `/v1/`, subpath variants) now derives the identical
   pair — discovery at `{root}/v1/models`, completions at `{root}/v1` — and the base
   persisted to `marginalia.yaml` is always the canonical `{root}/v1`, so the saved config
   never depends on which form was entered. A query string on the base (Azure-style
   `?api-version=`) is preserved on every derived URL; non-OpenAI-contract drivers
   (Anthropic, Gemini, Azure, Ollama, …) are untouched.

2. **Onboarding runs a real completion before it saves anything.** After discovery lists
   models, a minimal completion runs through the exact canonical endpoint every real
   ask/ingest call uses. On failure the run aborts with the exact attempted URL and
   nothing is saved — no LLM config block, no env secret — instead of persisting a base the
   runtime could not actually use.

3. **A non-interactive run without `--model` never silently defaults to the first
   discovered model.** On a multi-model server `models[0]` can be a non-chat model; the run
   now lists what it found and demands an explicit `--model` (a preset's own declared
   default is still honored when it is among the discovered models).

   **Migration consequence.** Existing vaults keep their pinned config; for OpenAI-compatible
   drivers the stored `api_base` is now canonicalized to the runtime's own shape on
   load/write, so a previously saved root-form base now resolves to the same `/v1` endpoint
   a fresh install would get — previously broken root-form configs start working, and
   correctly saved `/v1` configs are unchanged.

## Verification status of `0.2.0`

`0.2.0` remains a prerelease. What was and was not run for this exact release:

- **Source-repo GitHub Actions did not run** on `314e3af15a901c71c0bcb7af75a63f081298859f`.
  All four workflows were triggered and every job failed within about 4 s without starting:
  "The job was not started because recent account payments have failed or your spending
  limit needs to be increased." Runs: `docs-gate` 35925976054, `eval-gate` 35925976076,
  `model-free-tests` 35925976061, `release-artifact-gate` 35925976028 (its
  `neo4j-backend-gate` job was skipped).
- **The source gates were reproduced locally on that exact commit** on 2026-09-23:
  - `model-free-tests / tests`: `uv lock --check`, `actionlint` and `ruff` clean; the
    canonical CI pytest selection 1 failed / 4,440 passed / 65 skipped / 37 deselected /
    1 xfailed, the one failure being the waived snapshot race above; `npm ci`,
    `npm audit` (0 vulnerabilities), typecheck and build clean; no `frontend_dist`
    drift; the docs build leaves the tree clean.
  - `model-free-tests / acceptance`: every scenario PASS on the default grafx backend
    (54 skipped by design on grafx), overall green.
  - `eval-gate / floor`: gold 32/32, distractors 20/20, provenance gate pass,
    `recall_floor` selftest PASS, regressions `[]`.
  - `release-artifact-gate / neo4j-backend-gate`: against a live `neo4j:5-community`
    container, the Neo4j contract tests 9 passed / 0 skipped, the CI pytest step
    1 failed (the waived race) / 1,394 passed, acceptance scenario 84 PASS with 25
    assertions.
  - `release-artifact-gate / wheel`: every extra resolved in its own clean Python 3.12
    environment, a live `[serve]` start, JSON-LD export, both CLI entry points, retired
    constructors failing closed, grafx and neo4j init without `--accept-experimental`,
    wheel byte scan clean.
- **`release-artifact-gate / windows-managed-credentials` did not run.** It needs a
  Windows runner and has no local substitute.
- **The wheel artifact gates passed against the exact published wheel** above, built
  from the clean tagged commit: dependency contract 17 passed, install footprint 1
  passed, a live `marginalia serve --no-open` from the `[serve]` extra in an isolated
  HOME with zero vaults answering `/health`, `/version` (`0.2.0`) and the SPA, and a
  JSON-LD export through the `[jsonld]` extra.
- **The interactive Windows PowerShell 5.1 lifecycle rehearsal was not performed**
  for this release. No published Marginalia version has ever passed it.
- **The Linux Docker+tmux `release-lifecycle` rehearsal passed** on 2026-09-23
  against dist commit `29683d2156840eadaff43efd6133750cd7f24465`; see the record
  below.
- **The public `distribution-gate` is GREEN** on
  `29683d2156840eadaff43efd6133750cd7f24465` (run 35926619850: parity,
  bash-transaction, powershell-syntax).

Nothing beyond the list above was verified for `0.2.0`. Gate results recorded for
earlier versions elsewhere in this file belong to those versions and were not
re-run here.

## Verification status of `0.1.0` (history)

`0.1.0` remains a prerelease. What was and was not run for that release:

- **Source-repo GitHub Actions did not run** on `8e0e9ae2c51e6c452705548dcba5af8fd77d909c`;
  the source org's Actions are billing-blocked.
- **The source gates were reproduced locally** at that commit: the test suite
  4,052 passed / 94 skipped / 1 xfailed, `ruff` clean, `uv lock --check` clean,
  and the docs gate 47 passed.
- **The wheel artifact gates passed against the exact published wheel** above:
  dependency contract 17 passed, install footprint 1 passed.
- **The Neo4j backend gate runs only in source CI**, so it did not run for this
  release.
- **The interactive Windows PowerShell 5.1 lifecycle rehearsal was not performed**
  for this release. No published Marginalia version has ever passed it.
- **The Linux Docker+tmux `release-lifecycle` rehearsal passed** on 2026-09-18
  against dist commit `a64c9e97df76cffbfd78efb695350277b000d883`; see the record
  below.
- **The public `distribution-gate` is GREEN** on
  `a64c9e97df76cffbfd78efb695350277b000d883` (parity, bash-transaction,
  powershell-syntax).

Nothing beyond the list above was verified for `0.1.0`. Gate results recorded for
earlier versions elsewhere in this file belong to those versions and were not
re-run here.

## Install On macOS Or Linux

```bash
curl -fsSL https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/install.sh | bash
```

On a fresh interactive terminal with no existing Marginalia vault or config
(greenfield), the installer asks once, after installing the tool and before
starting the app:

```text
Marginalia first run: no vault configured.
Set up your vault and LLM provider now? [Y/n] (default Y)
```

`Y` or Enter runs the terminal `marginalia onboard` flow (you name your own
vault in-flow; the installer never creates one). `n` or EOF keeps the
application-first path and prints a hint that `marginalia onboard` is
available from any shell. The prompt is skipped silently for piped/CI
installs (no TTY), `MARGINALIA_NO_OPEN=1`, the `--no-onboard` flag,
`MARGINALIA_VAULT` preseeding, and every reinstall or upgrade — it only
appears while the Marginalia home is greenfield (no vault config and no
`~/.marginalia/defaults.yaml`), so upgrades never prompt.

## Install On Windows

The installer resolves the `0.2.0` release. There is still no retained native
PowerShell 5.1 lifecycle evidence for any published version, so treat this path as unverified.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/install.ps1 | iex"
```

The installer takes a fresh machine from zero to a running application wired into Claude Code:

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

`install.sh` also accepts one flag: `--no-onboard` force-skips the greenfield
first-run prompt (`curl … | bash -s -- --no-onboard`); any other flag is
rejected.

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
./test-install.sh --docker-tmux --profile onboard-prompt-yes
./test-install.sh --docker-tmux --profile onboard-prompt-no
./test-install.sh --docker-tmux --profile onboard-no-open
./test-install.sh --docker-tmux --profile onboard-no-flag
./test-install.sh --docker-tmux --profile onboard-upgrade-tty
./test-install.sh --docker-tmux --profile custom --api-base http://127.0.0.1:1234/v1 --model docker-custom-human-model

# macOS/Linux host with isolated HOME, prompts driven through tmux.
./test-install.sh --tmux --profile skip
./test-install.sh --tmux --profile existing-inspect
./test-install.sh --tmux --profile custom --api-base http://127.0.0.1:8123/v1 --model macos-custom-human-model

# Greenfield first-run matrix scenario without a TTY (direct mode only).
./test-install.sh --profile onboard-non-tty
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

### v0.2.0 Linux release rehearsal (exact driver commit)

Ran 2026-09-23. The first attempt for `0.2.0` did not reach the installer: the
host's Docker daemon now runs in a Colima VM that does not share macOS
`/var/folders`, so the tester's default sandbox under `$TMPDIR` bind-mounted
`/runner.sh` into the container as an empty directory (`/runner.sh: Is a
directory`, pane status 126). That is a host environment issue, not an installer
or wheel defect. The rehearsal was re-run from the same pinned driver with
`TMPDIR` set to a directory under the user's home, which Colima does share.

The tester was fetched from the exact dist commit
`29683d2156840eadaff43efd6133750cd7f24465` (driver `test-install.sh` SHA-256
`e6e0cc1b5f2a5479b9d09e97f9e70d50a34eda53bfe3daed28a06d8abb304c6d`) and that same
SHA was passed back as `--driver-commit`, so the run is pinned to a published
commit rather than a moving branch or a local checkout. The pinned
`install.sh` records SHA-256
`a4c0f72b757bbfe54c17ee766885c84d8b89b2126fe1027df4d562f8824b15a8` and
`release-manifest.json` SHA-256
`22eb2f07ee453a708052469d71382a2dc47b0491ff8534d7899325f3bea8068f`. `v0.2.0` in
this repo points at that commit. The full invocation was `--docker-tmux --profile
release-lifecycle --driver-commit 29683d2156840eadaff43efd6133750cd7f24465`.

Every stage verifies the published `0.2.0` wheel SHA-256
`59adee4483d8f85525e30a5e6271e6328238ac275d4b3fe05e29325d2ed29520`, matching
`release-manifest.json`. All thirteen `RELEASE_LIFECYCLE_*_OK` markers
(`FRESH_INSTALL`, `STATUS_UI`, `APP_FIRST`, `STOPPED_UPDATE`, `RUNNING_UPDATE`,
`CUSTOM_PORT_REFUSAL`, `LIVE_PID_REFUSAL`, `PREVIOUS_TOOL_SENTINEL`,
`ACTIVATION_ROLLBACK`, `PREDECESSOR_MIGRATION`, `PREDECESSOR_RUNNING`,
`PREDECESSOR_ROLLBACK`, `FINAL_STOP`) and the final
`DOCKER_TMUX_RELEASE_LIFECYCLE_OK` occur in one fresh Ubuntu container and one
real tmux TTY, and the pane exited with status 0. The run exercised a genuine
upgrade path: `marginalia-0.0.40-py3-none-any.whl` installed first, then updated
to `marginalia-0.2.0-py3-none-any.whl`.

Retained pane evidence:
[`evidence/v0.2.0/linux-docker-tmux-release-lifecycle.txt`](evidence/v0.2.0/linux-docker-tmux-release-lifecycle.txt),
SHA-256 `1d2e1c27b93c20eed0176bf857d5ed9f240f7f27a374c833dece6fe0eb356fd1`.

Only the `release-lifecycle` profile was run for `0.2.0`; the
`greenfield-first-run` and `custom-rootform` profiles were not re-run, so their
`0.0.49` evidence below is the most recent for those paths.

This is Linux rehearsal evidence only. It does not promote `0.2.0`: source-repo
Actions are billing-blocked so its gates were reproduced locally, the
snapshot-concurrency race is a waived known issue, the Windows managed-credentials
gate did not run, and promotion still waits on a real interactive Windows
PowerShell 5.1 lifecycle rehearsal, which has never passed for any published
version. `0.2.0` remains a prerelease.

### v0.1.0 Linux release rehearsal (exact driver commit)

Ran 2026-09-18. The first attempt for `0.1.0` failed: the installer's new flag
guard used a bare `${BASH_SOURCE[0]}`, which under `set -u` aborts the
`curl … | bash` path with an unbound-variable error. The static gates,
`shellcheck`, and the sourced-prefix unit tests all passed while that piped
install path was broken. The fix landed in dist
`a64c9e97df76cffbfd78efb695350277b000d883` (mirroring source `5d9d4f7`) and the
rehearsal was re-run green against the fixed driver.

The tester was fetched from the exact dist commit
`a64c9e97df76cffbfd78efb695350277b000d883` (driver `test-install.sh` SHA-256
`ce26bfc500e231f9c966cda816f0bbab6520563d691673052e0466000b3faba0`) and that same
SHA was passed back as `--driver-commit`, so the run is pinned to a published
commit rather than a moving branch or a local checkout. The pinned
`install.sh` records SHA-256
`efa2e841049efccafd607f64964efc6a88eae96c2703a3777ee840a12d930925` and
`release-manifest.json` SHA-256
`d6519faa2d126b3c7545eff48b98b0be23d3c31ccafaa2eac0771cadd365cb12`. `v0.1.0` in
this repo points at that commit, which was dist `main` at the time. The full invocation
was `--docker-tmux --profile release-lifecycle --driver-commit
a64c9e97df76cffbfd78efb695350277b000d883`.

Every stage verifies the published `0.1.0` wheel SHA-256
`185d787947d524f6fd7a88d120c6bbbff1d36d55348eb18d11bdf2c65bce8591`, matching
`release-manifest.json`. All thirteen `RELEASE_LIFECYCLE_*_OK` markers
(`FRESH_INSTALL`, `STATUS_UI`, `APP_FIRST`, `STOPPED_UPDATE`, `RUNNING_UPDATE`,
`CUSTOM_PORT_REFUSAL`, `LIVE_PID_REFUSAL`, `PREVIOUS_TOOL_SENTINEL`,
`ACTIVATION_ROLLBACK`, `PREDECESSOR_MIGRATION`, `PREDECESSOR_RUNNING`,
`PREDECESSOR_ROLLBACK`, `FINAL_STOP`) and the final
`DOCKER_TMUX_RELEASE_LIFECYCLE_OK` occur in one fresh Ubuntu container and one
real tmux TTY. The run exercised a genuine upgrade path:
`marginalia-0.0.40-py3-none-any.whl` installed first, then updated to
`marginalia-0.1.0-py3-none-any.whl`.

Retained pane evidence:
[`evidence/v0.1.0/linux-docker-tmux-release-lifecycle.txt`](evidence/v0.1.0/linux-docker-tmux-release-lifecycle.txt),
SHA-256 `84b8a37f48d23cf250c1b12550fce4b95b36a7f975b07fdf6e610498a27e49c7`.

Only the `release-lifecycle` profile was run for `0.1.0`; the
`greenfield-first-run` and `custom-rootform` profiles were not re-run, so their
`0.0.49` evidence below is the most recent for those paths.

The public `distribution-gate` is GREEN on
`a64c9e97df76cffbfd78efb695350277b000d883` (parity, bash-transaction,
powershell-syntax).

This is Linux rehearsal evidence only. It does not promote `0.1.0`: the Neo4j
backend gate runs only in source CI and therefore did not run, leaving that
surface unverified for this release, and promotion still waits on a real
interactive Windows PowerShell 5.1 lifecycle rehearsal, which has never passed
for any published version. `0.1.0` remains a prerelease pending both.

### v0.0.50 Linux release rehearsal (exact driver commit)

Ran 2026-09-17. The tester was fetched from the exact dist commit
`4300d4a0576f90b0c2609f4512b4c3ed6f37d1e5` (driver SHA-256 `18f591e3f7fd876d0fced187eaa534ce38ea2c52ebf0926b5ef726d7e3f1cc53`) and that same SHA was passed back as
`--driver-commit`, so the run is pinned to a published commit rather than a
moving branch or a local checkout. `v0.0.50` in this repo points at that commit.

Every stage verifies the published `0.0.50` wheel SHA-256
`cc524877686ad0227d6cd208c487f027acf1f1e25772c98afe00b96bbdf3ea1e`, matching `release-manifest.json`. All thirteen
`RELEASE_LIFECYCLE_*_OK` markers and the final `DOCKER_TMUX_RELEASE_LIFECYCLE_OK`
occur in one fresh Ubuntu container and one real tmux TTY. The run exercised a
genuine upgrade path: `marginalia-0.0.40-py3-none-any.whl` installed first, then
updated to `marginalia-0.0.50-py3-none-any.whl`. The four `error:` lines in the
pane are the asserted refusals (custom-port, unverified-live-PID, and two
activation rollbacks), each paired with its `_OK` marker.

Retained pane evidence:
[`evidence/v0.0.50/linux-docker-tmux-release-lifecycle.txt`](evidence/v0.0.50/linux-docker-tmux-release-lifecycle.txt),
SHA-256 `04850e6d70a709790f498e03570d3fad745a72a39d9c4986bcc2eff3b936d622`.

Only the `release-lifecycle` profile was run for `0.0.50`; the
`greenfield-first-run` and `custom-rootform` profiles were not re-run, so their
`0.0.49` evidence below is the most recent for those paths.

This is Linux rehearsal evidence only. It does not promote `0.0.50`: promotion
still waits on a real interactive Windows PowerShell 5.1 lifecycle rehearsal,
which has never passed for any published version.

### v0.0.49 Linux release rehearsal (exact driver commit)

Ran 2026-09-14. The 0.0.49 harness adaptation (provider menu gained the
`pi_cli`/`codex_cli` entries, the 0.0.47+ onboarding asks for the graph
backend before the provider, and the 0.0.49 onboarding verifies a real
completion before saving) required four fix commits after the 0.0.49 bake
(`de929b4` mock-launch chain, `266631d` backend prompt, `13355f9` provider
11, `f1ea4e3` evidence-checker return status). All three rehearsals below
therefore drove from the final dist-main commit
`f1ea4e3591b2d65db3b656933e30281249d867b5`, and `v0.0.49` in this repo points
at that exact commit.

First, the release lifecycle: `./test-install.sh --docker-tmux --profile
release-lifecycle --driver-commit f1ea4e3591b2d65db3b656933e30281249d867b5`
fetched the driver from the exact public raw URL of that commit. The pane
header records `DRIVER_COMMIT=f1ea4e3591b2d65db3b656933e30281249d867b5` with
driver, installer, and manifest URLs and SHA-256 values resolved from that
pinned commit. Every successor stage verifies the published `0.0.49` wheel
SHA-256 `8274abea746e9ec6d1b8450e5d416ea626ec8e325effbe1f240929ad9ec9d4c3`,
matching `release-manifest.json`. All thirteen `RELEASE_LIFECYCLE_*_OK`
markers and the final `DOCKER_TMUX_RELEASE_LIFECYCLE_OK` occur exactly once,
and the final line records tmux pane status 0. Retained transcript:
[`evidence/v0.0.49/linux-docker-tmux-release-lifecycle.txt`](evidence/v0.0.49/linux-docker-tmux-release-lifecycle.txt),
SHA-256 `5f444a7d4c261cf78fdd782b7b8b1902792d89714d7623064e2fb7ec52841e07`
(54,708 bytes; 1,978 lines).

Second, the greenfield first-run prompt: a fresh `ubuntu:24.04` container in
a real tmux TTY installed from the pinned raw URL
`https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/f1ea4e3591b2d65db3b656933e30281249d867b5/install.sh`
(`--profile onboard-prompt-yes`). On the greenfield + TTY install the
installer printed, after installing the tool and before starting the app:

```text
Marginalia first run: no vault configured.
Set up your vault and LLM provider now? [Y/n] (default Y)
```

Answering `Y` (Enter) ran `marginalia onboard`: the default graph backend
(`grafx`) was accepted, the in-flow user-named vault `onboarded-vault` was
created, and provider choice `0` skipped LLM setup, so the created
`marginalia.yaml` carries no `llm:` block. The daemon then started
(`server: ready (http://127.0.0.1:7777, version 0.0.49)`), the run tore down
with `marginalia stop`, and it ended in `DOCKER_TMUX_HUMAN_INSTALL_OK` with
tmux pane status 0. Retained transcript:
[`evidence/v0.0.49/linux-docker-tmux-greenfield-first-run.txt`](evidence/v0.0.49/linux-docker-tmux-greenfield-first-run.txt),
SHA-256 `1f0e72081eaa80b570bce545e6179f07c6be6ad7728c0210678ebef19f438189`
(9,604 bytes; 334 lines).

Third, new for 0.0.49, the `custom-rootform` profile exercised the
verify-before-save fix end to end against a hermetic `/v1`-only mock OpenAI
server inside the container (the documented 0.0.49 choice instead of
host-networking a LAN endpoint — no LAN address appears in any retained
evidence). The driven install (`--profile custom-rootform`) entered the
base URL `http://127.0.0.1:18123` (no trailing `/v1`, root form) and model
`fake-chat-model` (the second of two discovered models — not a
`models[0]` default). The mock log records the canonical
`MOCK-REQ GET /v1/models` discovery probe and a pre-save
`MOCK-REQ POST /v1/chat/completions` verify; the onboarding summary then
shows the canonicalized `base URL: http://127.0.0.1:18123/v1`, and the
runner asserted the saved `marginalia.yaml` contains
`api_base: http://127.0.0.1:18123/v1` and `fake-chat-model`. Two post-steps
ran in the same container: (f) a non-interactive dead-endpoint run failed
with `verify failed — nothing was saved:` showing the exact attempted URL
`POST http://127.0.0.1:18124/v1/chat/completions`, and the runner asserted
the vault `marginalia.yaml` contains no `llm:` block
(`CUSTOM_ROOTFORM_DEAD_ENDPOINT_OK`); (g) a non-interactive run without
`--model` refused to pick `models[0]`, printing the exact error listing the
discovered models and saving nothing
(`CUSTOM_ROOTFORM_NO_SILENT_MODEL_OK`). No root-level `MOCK-REQ GET /models`
or `MOCK-REQ POST /chat/completions` probe (the pre-0.0.49 bug) appears
anywhere in the transcript. It ended in `DOCKER_TMUX_HUMAN_INSTALL_OK` with
tmux pane status 0. Retained transcript:
[`evidence/v0.0.49/linux-docker-tmux-custom-rootform.txt`](evidence/v0.0.49/linux-docker-tmux-custom-rootform.txt),
SHA-256 `e8133c6411ac5756851855362512cefe7bf951df2bca463586dd93968eab53bd`
(10,820 bytes; 360 lines).

All three containers ran on the host's default bridge network with no
published ports and no `--network host`, so each container's
`:7777`/`:8201` was isolated in its own network namespace and no host
daemon or host port was touched.

This satisfies section 6's exact-commit driver requirement for the Linux
rehearsal only. It does not by itself promote `0.0.49`: promotion
additionally requires the separate real interactive Windows PowerShell 5.1
rehearsal, which has still never passed for any published version — `0.0.49`
included. The public `distribution-gate` runs on push of this recording
commit. `0.0.49` remains a prerelease pending that Windows evidence, and
this rehearsal deliberately did not attempt the Windows rehearsal or clear
the release's prerelease flag.

### v0.0.48 Linux release rehearsal (exact driver commit)

Ran 2026-09-13. This run satisfies section 6's exact-commit driver requirement
for the Linux platform: it fetched `test-install.sh` from the exact public
dist-main commit `6de65ad19df4dfd4d3d813e707010f6f6b3c5d84` (the pushed tip of
`origin/main`, i.e. the `release: 0.0.48 manifest + README` commit) and ran
`./test-install.sh --docker-tmux --profile release-lifecycle --driver-commit
6de65ad19df4dfd4d3d813e707010f6f6b3c5d84`. The pane header records
`DRIVER_COMMIT=6de65ad19df4dfd4d3d813e707010f6f6b3c5d84`, with the driver,
installer, and manifest URLs and SHA-256 values all resolved from that pinned
commit rather than a moving branch or local checkout. Its retained transcript
is
[`evidence/v0.0.48/linux-docker-tmux-release-lifecycle.txt`](evidence/v0.0.48/linux-docker-tmux-release-lifecycle.txt),
SHA-256 `6914ea31d4c13647f3b17d518fc7abcad25497eb7c5c722656b7f65b456f2a81`
(54,711 bytes; 1,978 lines). It records the exact raw driver/install/manifest
URLs and SHA-256 values it verified, plus the pinned immutable v0.0.40
predecessor's URL and SHA-256
`8cdf7e0f604c5f21cb2c6ed79aecb5161ebe259835842c28795b47142b6293eb`. Every
successor stage verifies the published `0.0.48` wheel SHA-256
`884a6721590583eda836dcb127b0e0bb729557db461b27100a3a8e6c99808b24`, matching
`release-manifest.json`. All thirteen `RELEASE_LIFECYCLE_*_OK` markers and the
final `DOCKER_TMUX_RELEASE_LIFECYCLE_OK` occur exactly once, covering
predecessor rollback and migration, app-first zero-vault startup,
credential-free status and UI, stopped and running updates, custom-port
refusal, unverified-live-PID refusal, previous-tool-sentinel restoration,
activation rollback, and final stop. The final line records tmux pane status 0.
No fake hosted-provider secret appears in the transcript.

New for 0.0.48, the one-shot greenfield first-run prompt was exercised in the
same rehearsal: a second fresh `ubuntu:24.04` container in a real tmux TTY ran
the public raw-URL installer (`curl -fsSL
https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/install.sh
| bash`, driven by `./test-install.sh --docker-tmux --profile
onboard-prompt-yes`) with `main` still at that same commit `6de65ad` (the raw
`main` installer, manifest, and driver byte-match the pinned-commit SHAs
recorded in the lifecycle pane header). On the greenfield + TTY install the
installer printed, after installing the tool and before starting the app:

```text
Marginalia first run: no vault configured.
Set up your vault and LLM provider now? [Y/n] (default Y)
```

Answering `Y` (Enter) ran `marginalia onboard`: the default graph backend
(`grafx`) was accepted, the in-flow user-named vault `onboarded-vault` was
created and confirmed at `/root/.marginalia/vaults/onboarded-vault`, and
provider choice `0` skipped LLM setup (no LLM in the container), so the
created `marginalia.yaml` carries no `llm:` block. The daemon then started
(UI/REST `:7777` + MCP `:8201`) with `server: ready (http://127.0.0.1:7777,
version 0.0.48)`, the plain loopback UI was reachable (`/health` returned
`{"status":"ok"}` and the installer opened the verified app at
`http://127.0.0.1:7777/`), the installed wheel SHA-256 matched
`release-manifest.json`, and the run tore down with `marginalia stop`, ending
in `DOCKER_TMUX_HUMAN_INSTALL_OK` with tmux pane status 0. Its retained
transcript is
[`evidence/v0.0.48/linux-docker-tmux-greenfield-first-run.txt`](evidence/v0.0.48/linux-docker-tmux-greenfield-first-run.txt),
SHA-256 `11ad67dbe4d81c7743051ad7aa7ce1e8f052bffaed50acc4a657f911eba6e052`
(9,604 bytes; 334 lines).

Both containers ran on the host's default bridge network with no published
ports and no `--network host`, so each container's `:7777`/`:8201` was
isolated in its own network namespace and no host daemon or host port was
touched.

This satisfies section 6's exact-commit driver requirement for the Linux
rehearsal only. It does not by itself promote `0.0.48`: promotion additionally
requires the separate real interactive Windows PowerShell 5.1 rehearsal, which
has still never passed for any published version — `0.0.48` included. The
public `distribution-gate` runs on push of this recording commit. `0.0.48`
remains a prerelease pending that Windows evidence, and this rehearsal
deliberately did not attempt the Windows rehearsal or clear the release's
prerelease flag.

### v0.0.47 Linux release rehearsal (exact driver commit)

Ran 2026-09-12. This run satisfies section 6's exact-commit driver requirement
for the Linux platform: it fetched `test-install.sh` from the exact public
dist-main commit `087a28a12c22a73b6c3b11ef911158e413342cea` (the pushed tip of
`origin/main`, i.e. the `release: bake v0.0.47` commit) and ran
`./test-install.sh --docker-tmux --profile release-lifecycle --driver-commit
087a28a12c22a73b6c3b11ef911158e413342cea`. The pane header records
`DRIVER_COMMIT=087a28a12c22a73b6c3b11ef911158e413342cea`, with the driver,
installer, and manifest URLs and SHA-256 values all resolved from that pinned
commit rather than a moving branch or local checkout. Its retained transcript
is
[`evidence/v0.0.47/linux-docker-tmux-release-lifecycle.txt`](evidence/v0.0.47/linux-docker-tmux-release-lifecycle.txt),
SHA-256 `9701ca1939136588b141572cb32d26741850f2cd3310cd626990e395aabfab7d`
(54,500 bytes; 1,966 lines). It records the exact raw driver/install/manifest
URLs and SHA-256 values it verified, plus the pinned immutable v0.0.40
predecessor's URL and SHA-256
`8cdf7e0f604c5f21cb2c6ed79aecb5161ebe259835842c28795b47142b6293eb`. Every
successor stage verifies the published `0.0.47` wheel SHA-256
`b9c62fb2e8690c3f62b0ad26b3bf84535fd245e8dc2c2a2171bb7ef2b2dd8d14`, matching
`release-manifest.json`. All thirteen `RELEASE_LIFECYCLE_*_OK` markers and the
final `DOCKER_TMUX_RELEASE_LIFECYCLE_OK` occur exactly once, covering
predecessor rollback and migration, app-first zero-vault startup,
credential-free status and UI, stopped and running updates, custom-port
refusal, unverified-live-PID refusal, previous-tool-sentinel restoration,
activation rollback, and final stop. The final line records tmux pane status 0.
No fake hosted-provider secret appears in the transcript.

This satisfies section 6's exact-commit driver requirement for the Linux
rehearsal only. It does not by itself promote `0.0.47`: promotion additionally
requires the separate real interactive Windows PowerShell 5.1 rehearsal, which
has still never passed for any published version — `0.0.47` included — and
GitHub Actions is unavailable for this org (billing not enabled), so no
`distribution-gate` CI run exists on this or any other commit; the required
gates were instead reproduced locally (`git diff --check`, `bash -n`,
`shellcheck`, `actionlint`, and this rehearsal itself). `0.0.47` remains a
prerelease pending both, and this rehearsal deliberately did not attempt the
Windows rehearsal or clear the release's prerelease flag.

### v0.0.46 Linux release rehearsal (exact driver commit)

Ran 2026-09-09. This run satisfies section 6's exact-commit driver requirement
for the Linux platform: it fetched `test-install.sh` from the exact public
dist-main commit `c817e3c2f834ca5f0f3fbec721024824d20e0be1` (the pushed tip of
`origin/main`, i.e. the `release: 0.0.46` commit) and ran
`./test-install.sh --docker-tmux --profile release-lifecycle --driver-commit
c817e3c2f834ca5f0f3fbec721024824d20e0be1`. The pane header records
`DRIVER_COMMIT=c817e3c2f834ca5f0f3fbec721024824d20e0be1`, with the driver,
installer, and manifest URLs and SHA-256 values all resolved from that pinned
commit rather than a moving branch or local checkout. Its retained transcript
is
[`evidence/v0.0.46/linux-docker-tmux-release-lifecycle.txt`](evidence/v0.0.46/linux-docker-tmux-release-lifecycle.txt),
SHA-256 `617dbfe64798c2ca166c02714c49ee91a3b8e2b8227d2386c64ab2d5c5fc7eef`
(54,193 bytes; 1,954 lines). It records the exact raw driver/install/manifest
URLs and SHA-256 values it verified, plus the pinned immutable v0.0.40
predecessor's URL and SHA-256
`8cdf7e0f604c5f21cb2c6ed79aecb5161ebe259835842c28795b47142b6293eb`. Every
successor stage verifies the published `0.0.46` wheel SHA-256
`b5c3a825f7b734db62b2774c8a8cfb1b79ebfa23b8580d05619ae0b23dc5ab81`, matching
`release-manifest.json`. All thirteen `RELEASE_LIFECYCLE_*_OK` markers and the
final `DOCKER_TMUX_RELEASE_LIFECYCLE_OK` occur exactly once, covering
predecessor rollback and migration, app-first zero-vault startup,
credential-free status and UI, stopped and running updates, custom-port
refusal, unverified-live-PID refusal, previous-tool-sentinel restoration,
activation rollback, and final stop. The final line records tmux pane status 0.

The rehearsal container runs `--rm`, so its own managed vault does not survive
the run for inspection. To confirm the default graph backend separately, a
throwaway Ubuntu container (`marginalia-install-rehearsal-backend-check`,
removed after the check, no new image left behind — it reused the
already-cached `ubuntu:24.04` base) downloaded the exact published `0.0.46`
wheel from its public release URL, verified its SHA-256 against
`release-manifest.json` before installing, then ran
`marginalia vault create backendcheck --no-use`, which wrote `backend: grafx`
under `storage:` in the created vault's `marginalia.yaml`.

This satisfies section 6's exact-commit driver requirement for the Linux
rehearsal only. It does not by itself promote `0.0.46`: promotion additionally
requires the separate real interactive Windows PowerShell 5.1 rehearsal, which
has still never passed for any published version — `0.0.46` included — and the
post-rehearsal `SOURCE_EVIDENCE_SHA`/`DIST_EVIDENCE_SHA` CI-gate verification,
which has not been run against this commit. `0.0.46` remains a prerelease
pending both, and this rehearsal deliberately did not attempt the Windows
rehearsal or clear the release's prerelease flag.

### v0.0.45 Linux release rehearsal (exact driver commit)

Ran 2026-09-09. This run satisfies section 6's exact-commit driver requirement
for the Linux platform: it fetched `test-install.sh` from the exact public
dist-main commit `5bf829656087af2484b9db922c9b8e2a3b13fec3` (the pushed tip of
`origin/main`, i.e. the `release: 0.0.45` commit) and ran
`./test-install.sh --docker-tmux --profile release-lifecycle --driver-commit
5bf829656087af2484b9db922c9b8e2a3b13fec3`. The pane header records
`DRIVER_COMMIT=5bf829656087af2484b9db922c9b8e2a3b13fec3`, with the driver,
installer, and manifest URLs and SHA-256 values all resolved from that pinned
commit rather than a moving branch or local checkout. This supersedes an
earlier same-day local-checkout run of the same profile (no `--driver-commit`,
`DRIVER_COMMIT=LOCAL_UNCOMMITTED`), which was a dry run only and did not
satisfy this requirement.
Its retained transcript is
[`evidence/v0.0.45/linux-docker-tmux-release-lifecycle.txt`](evidence/v0.0.45/linux-docker-tmux-release-lifecycle.txt),
SHA-256 `6fc57ca4c3cc1dacd7ef0094a6626c6d344bc14acbfead617d7658358c00ad92`
(53,803 bytes; 1,950 lines). It records the exact raw driver/install/manifest
URLs and SHA-256 values it verified, plus the pinned immutable v0.0.40
predecessor's URL and SHA-256
`8cdf7e0f604c5f21cb2c6ed79aecb5161ebe259835842c28795b47142b6293eb`. Every
successor stage verifies the published `0.0.45` wheel SHA-256
`8a10b4d65d04e70a4612aba6788547c2a51bd31f3e9de446494d271b5cb7aaa9`, matching
`release-manifest.json`. All fourteen `RELEASE_LIFECYCLE_*_OK` markers and the
final `DOCKER_TMUX_RELEASE_LIFECYCLE_OK` occur exactly once, covering
predecessor rollback and migration, app-first zero-vault startup,
credential-free status and UI, stopped and running updates, custom-port
refusal, unverified-live-PID refusal, previous-tool-sentinel restoration,
activation rollback, and final stop. The final line records tmux pane status 0.

The rehearsal container runs `--rm`, so its own managed vault does not survive
the run for inspection. To confirm the default graph backend separately, a
throwaway Ubuntu container (`marginalia-install-rehearsal-backendcheck`,
removed after the check, along with no new image left behind — it reused the
already-cached `ubuntu:24.04` base) downloaded the exact published `0.0.45`
wheel from its public release URL, verified its SHA-256 against
`release-manifest.json` before installing, then ran
`marginalia vault create --help` (reports `--backend` default `grafx`) and
`marginalia vault create backendcheck --use`, which wrote `backend: grafx`
under `storage:` in the created vault's `marginalia.yaml`.

This satisfies section 6's exact-commit driver requirement for the Linux
rehearsal only. It does not by itself promote `0.0.45`: promotion additionally
requires the separate real interactive Windows PowerShell 5.1 rehearsal, which
has still never passed for any published version — `0.0.45` included — and the
post-rehearsal `SOURCE_EVIDENCE_SHA`/`DIST_EVIDENCE_SHA` CI-gate verification,
which has not been run against this commit (nothing here was pushed). `0.0.45`
remains a prerelease pending both.

### v0.0.44 Linux release evidence

The v0.0.44 rehearsal fetched the driver from exact public dist commit
`99c8be9f2f4b7ea00943dd570bc8b92f5cfc69cb`, after all three jobs in
[`distribution-gate` run 30479042461](https://github.com/OktoLabsAI/marginalia-dist/actions/runs/30479042461)
passed on that SHA. That is the atomic bake commit: manifest, both installers, both testers,
README, and the gate moved together, so no gate ran against a half-updated distribution.
Its retained transcript is
[`evidence/v0.0.44/linux-docker-tmux-release-lifecycle.txt`](evidence/v0.0.44/linux-docker-tmux-release-lifecycle.txt),
SHA-256 `d9f56549f6d91677d7a59b74e476d48e03e71c28364240cfc4cfb55b9e223e61`
(53,500 bytes; 1,936 lines). It records exact raw driver, installer, manifest, and immutable
v0.0.40 predecessor URLs and SHA-256 values. Every successor stage verifies the published
v0.0.44 wheel SHA-256 `fbab50524b107436c19b0f790d10358789eae45222d0bf3ebe4ba5b79af8fed1`; the
only other wheel digest in the pane is the pinned immutable predecessor
`8cdf7e0f604c5f21cb2c6ed79aecb5161ebe259835842c28795b47142b6293eb`. All thirteen
`RELEASE_LIFECYCLE_*_OK` markers and the final `DOCKER_TMUX_RELEASE_LIFECYCLE_OK` occur exactly
once, covering predecessor rollback and migration, app-first zero-vault startup, credential-free
status and UI, stopped and running updates, custom-port refusal, unverified-live-PID refusal,
previous-tool-sentinel restoration, activation rollback, and final stop. The final line records
tmux pane status 0.

This proves the exact Linux lifecycle only. It does not replace the separate real interactive
Windows PowerShell 5.1 rehearsal, which has still never passed for any published version —
`0.0.44` included. That is why `0.0.44` remains a prerelease.

### v0.0.43 Linux release evidence

The v0.0.43 rehearsal fetched the driver from exact public dist commit
`2fab7c6adde336e248047b043a5ca65429c29ede`, after all three jobs in
[`distribution-gate` run 29363097517](https://github.com/OktoLabsAI/marginalia-dist/actions/runs/29363097517)
passed on that SHA. Its retained transcript is
[`evidence/v0.0.43/linux-docker-tmux-release-lifecycle.txt`](evidence/v0.0.43/linux-docker-tmux-release-lifecycle.txt),
SHA-256 `67d9795b97fbaf4965453cd897dad44b79bdb1aa74544adfa6695b2c660e80f8`
(53,477 bytes; 1,934 lines). It records exact raw driver, installer, manifest, and immutable
v0.0.40 predecessor URLs and SHA-256 values. Every successor stage verifies the published
v0.0.43 wheel SHA-256 `2ca924eadbad3819a32679fb4f2076e251f12921080c7510d281147ffad1ee44`; the
only other wheel digest in the pane is the pinned immutable predecessor
`8cdf7e0f604c5f21cb2c6ed79aecb5161ebe259835842c28795b47142b6293eb`. Every lifecycle marker
occurs exactly once, including predecessor rollback and migration, app-first zero-vault startup
with `marginalia --help` and `{"status":"ok"}` health on a reachable UI, stopped/running updates,
refusal paths, activation rollback, and final stop. The final line records tmux pane status 0.
This proves the exact Linux lifecycle only; it does not replace the separate real interactive
Windows PowerShell rehearsal, which has still never passed for any published version.

### v0.0.42 Linux release evidence

The corrected v0.0.42 rehearsal fetched the driver from exact public dist commit
`acf004529196ed5e6e2a5b533b8c00cf348eb960`, after all three jobs in
[`distribution-gate` run 29360994849](https://github.com/OktoLabsAI/marginalia-dist/actions/runs/29360994849)
passed on that SHA. Its retained transcript is
[`evidence/v0.0.42/linux-docker-tmux-release-lifecycle.txt`](evidence/v0.0.42/linux-docker-tmux-release-lifecycle.txt),
SHA-256 `936c6035cf7d8ac5ac7dc49d10ce747308b30fbb48423c31ec88da87934d4f62`
(53,650 bytes; 1,938 lines). It records exact raw driver, installer, manifest, and immutable
v0.0.40 predecessor URLs and SHA-256 values. Every lifecycle marker occurs exactly once, including
predecessor rollback and migration, app-first zero-vault startup, stopped/running updates, refusal
paths, activation rollback, and final stop. The final line records tmux pane status 0.

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
`WINDOWS_RELEASE_LIFECYCLE_OK`. The `0.0.42` profile first uses the pinned successor installer to
materialize the immutable `0.0.41` wheel with serving disabled, verifies its exact CLI identity
with no PID records or open daemon ports, and performs one stopped update to the exact `0.0.42`
wheel. It requires the CLI to change while the daemon remains stopped, then runs the complete
fresh, running, refusal, rollback, and final-stop lifecycle. This honest stopped-predecessor check
replaces the impossible claim that a healthy `0.0.41` Windows daemon could be rehearsed.
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
