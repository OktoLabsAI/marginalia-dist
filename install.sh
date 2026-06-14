#!/usr/bin/env bash
#
# Marginalia one-shot installer.
#
#   curl -fsSL https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/install.sh | bash
#
# Windows users should use install.ps1 from this same repo:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/install.ps1 | iex"
#
# Takes a fresh machine from zero to a running Marginalia daemon wired into
# Claude Code:  prereqs → install tool → create vault → configure LLM →
# serve → register the MCP server.
#
# Everything is overridable by environment variable so the SAME script works
# piped to bash (non-interactive) and run from a clone (interactive):
#
#   MARGINALIA_SRC          path to an existing checkout (skips clone)
#   MARGINALIA_WHEEL        path/URL to a built wheel (skips clone+source build)
#   MARGINALIA_REPO         git URL to clone   (default: SSH source repo)
#   MARGINALIA_REF          git ref to check out (default: repo default branch)
#   MARGINALIA_VAULT        vault name         (default: mynotes)
#   MARGINALIA_PACKS        type packs         (default: core,research,personal)
#   MARGINALIA_LLM_PROVIDER provider id for `marginalia onboard`
#   MARGINALIA_LLM_API_BASE provider base URL
#   MARGINALIA_LLM_MODEL    model name
#   MARGINALIA_LLM_API_KEY_ENV MARGINALIA_* env var name for the provider key
#   MARGINALIA_LLM_SKIP_DISCOVERY=1 skip model discovery
#   MARGINALIA_LLM_ALLOW_REMOTE=1 confirm non-loopback provider egress
#   MARGINALIA_NO_SERVE=1   install + configure only; don't start the daemon
#   MARGINALIA_NO_MCP=1     don't run `claude mcp add`
#
set -euo pipefail

case "${OS:-}:$(uname -s 2>/dev/null || true)" in
  Windows_NT:*|*:CYGWIN*|*:MINGW*|*:MSYS*)
    printf "%s\n" "This Bash installer is for macOS/Linux."
    printf "%s\n" "On Windows, run:"
    printf "%s\n" "  powershell -NoProfile -ExecutionPolicy Bypass -Command \"irm https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/install.ps1 | iex\""
    exit 1
    ;;
esac

# ── config ────────────────────────────────────────────────────────────────
# The public distribution copy of this script bakes a release-wheel URL here so
# `curl … | bash` needs no env. Empty in the source repo (which clones instead).
DEFAULT_WHEEL_URL="${MARGINALIA_DEFAULT_WHEEL_URL:-https://github.com/OktoLabsAI/marginalia-dist/releases/download/v0.0.22/marginalia-0.0.22-py3-none-any.whl}"
EXTRAS="embeddings,ladybug,mcp,litellm"
PY_VERSION="3.12"
REPO="${MARGINALIA_REPO:-git@github.com:OktoLabsAI/marginalia.git}"
REF="${MARGINALIA_REF:-}"
VAULT="${MARGINALIA_VAULT:-mynotes}"
PACKS="${MARGINALIA_PACKS:-core,research,personal}"
HOME_ROOT="${HOME}/.marginalia"
VAULT_DIR="${HOME_ROOT}/vaults/${VAULT}"
REST_URL="http://127.0.0.1:7777"
MCP_URL="http://127.0.0.1:8201/mcp"

# ── pretty logging ────────────────────────────────────────────────────────
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; X=$'\033[0m'
else B=""; G=""; Y=""; R=""; X=""; fi
step() { printf "\n%s==>%s %s%s%s\n" "$B$G" "$X" "$B" "$1" "$X"; }
info() { printf "    %s\n" "$1"; }
warn() { printf "%s !! %s%s\n" "$Y" "$1" "$X"; }
die()  { printf "%serror:%s %s\n" "$R" "$X" "$1" >&2; exit 1; }

printf "%s\n" "${B}Marginalia installer${X} — local-first knowledge graph for Claude Code"

# ── 1. uv ─────────────────────────────────────────────────────────────────
step "Checking uv (the package manager Marginalia runs through)"
if ! command -v uv >/dev/null 2>&1; then
  info "uv not found — installing from astral.sh ..."
  curl -fsSL https://astral.sh/uv/install.sh | sh
  # Make uv visible for the rest of this run.
  export PATH="${HOME}/.local/bin:${PATH}"
  command -v uv >/dev/null 2>&1 || die "uv installed but not on PATH; restart your shell and re-run."
fi
info "uv: $(command -v uv)"

step "Ensuring Python ${PY_VERSION} (uv-managed; no system Python touched)"
uv python install "${PY_VERSION}" >/dev/null 2>&1 || true

# ── 2. obtain the source / wheel ──────────────────────────────────────────
step "Resolving Marginalia source"
SPEC=""
CLONE_TMP=""
if [ -n "${MARGINALIA_WHEEL:-}" ]; then
  info "using wheel: ${MARGINALIA_WHEEL}"
  SPEC="${MARGINALIA_WHEEL}[${EXTRAS}]"
elif [ -n "${MARGINALIA_SRC:-}" ]; then
  [ -f "${MARGINALIA_SRC}/pyproject.toml" ] || die "MARGINALIA_SRC has no pyproject.toml: ${MARGINALIA_SRC}"
  info "using checkout: ${MARGINALIA_SRC}"
  SPEC="${MARGINALIA_SRC}[${EXTRAS}]"
else
  # Running from inside the repo? Use it. Otherwise clone.
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
  if [ -n "${SELF_DIR}" ] && [ -f "${SELF_DIR}/../pyproject.toml" ] \
     && grep -q '^name = "marginalia"' "${SELF_DIR}/../pyproject.toml" 2>/dev/null; then
    SRC="$(cd "${SELF_DIR}/.." && pwd)"
    info "running from a clone: ${SRC}"
    SPEC="${SRC}[${EXTRAS}]"
  elif [ -n "${DEFAULT_WHEEL_URL}" ]; then
    info "using release wheel: ${DEFAULT_WHEEL_URL}"
    SPEC="${DEFAULT_WHEEL_URL}[${EXTRAS}]"
  else
    command -v git >/dev/null 2>&1 || die "git not found; install git or set MARGINALIA_SRC / MARGINALIA_WHEEL."
    CLONE_TMP="$(mktemp -d)"
    info "cloning ${REPO} ..."
    git clone --depth 1 ${REF:+--branch "$REF"} "${REPO}" "${CLONE_TMP}" \
      || die "clone failed. Private repo? Set up SSH access, or pass MARGINALIA_SRC=<path> / MARGINALIA_WHEEL=<url>."
    SPEC="${CLONE_TMP}[${EXTRAS}]"
  fi
fi

# ── 2b. upgrade-safe: stop any running daemon BEFORE swapping tool files ───
# Replacing the installed package under a LIVE daemon leaves it serving stale
# file handles (the built UI then 500s). So this doubles as the update path:
# if a daemon is up, note which vault it serves, stop it cleanly, reinstall,
# and restart that same vault — re-running this script == a clean in-place update.
UPGRADE=""
RESTART_VAULT=""
if curl -fs "${REST_URL}/health" >/dev/null 2>&1; then
  UPGRADE="1"
  RESTART_VAULT="$(curl -fs "${REST_URL}/health" | sed -n 's/.*"vault_path":"\([^"]*\)".*/\1/p')"
  step "Existing Marginalia daemon detected — updating in place"
  info "active vault: ${RESTART_VAULT:-unknown}"
  if command -v marginalia >/dev/null 2>&1; then
    marginalia stop --vault "${HOME}/.marginalia/runtime" >/dev/null 2>&1 \
      || marginalia stop --vault "${RESTART_VAULT}" >/dev/null 2>&1 || true
  fi
  for _ in $(seq 1 15); do
    curl -fs "${REST_URL}/health" >/dev/null 2>&1 || break
    sleep 1
  done
  info "stopped the running daemon — it will restart on the new version below"
fi

# ── 3. install the global tool ────────────────────────────────────────────
step "Installing the marginalia + kg commands (extras: ${EXTRAS})"
uv tool install --force --python "${PY_VERSION}" "${SPEC}"
[ -n "${CLONE_TMP}" ] && rm -rf "${CLONE_TMP}"
# Always prefer the binary we just installed — never a marginalia that happened
# to be earlier on PATH (a prior install, a dev checkout). Resolve uv's tool bin
# dir authoritatively and put it first.
TOOL_BIN="$(uv tool dir --bin 2>/dev/null || true)"
[ -z "${TOOL_BIN}" ] && TOOL_BIN="${HOME}/.local/bin"
export PATH="${TOOL_BIN}:${PATH}"
command -v marginalia >/dev/null 2>&1 \
  || die "marginalia installed but not found in ${TOOL_BIN}. Run 'uv tool update-shell', restart your shell, re-run."
info "marginalia: $(command -v marginalia)"

if [ -n "${UPGRADE}" ]; then
  # Update path: the machine is already set up — don't create vaults, don't
  # touch the default, don't re-prompt for an LLM. Just reinstall (done) and
  # restart the vault that was running (below).
  step "Update mode — leaving your vaults, default, and LLM config untouched"
else

# ── 4. vault ──────────────────────────────────────────────────────────────
step "Creating vault '${VAULT}' (packs: ${PACKS})"
if [ -f "${VAULT_DIR}/marginalia.yaml" ]; then
  info "vault already exists at ${VAULT_DIR} — leaving it as-is"
  marginalia vault use "${VAULT}" >/dev/null 2>&1 || true
else
  marginalia vault create "${VAULT}" --packs "${PACKS}" --use
  info "created ${VAULT_DIR}"
fi

# ── 5. provider/model onboarding ──────────────────────────────────────────
step "Configuring provider and model with 'marginalia onboard'"
ONBOARD_ARGS=(onboard --vault "${VAULT}")
if [ -n "${MARGINALIA_LLM_PROVIDER:-}" ]; then
  ONBOARD_ARGS+=(--provider "${MARGINALIA_LLM_PROVIDER}")
elif [ ! -e /dev/tty ] || [ "${MARGINALIA_ONBOARD_NONINTERACTIVE:-}" = "1" ]; then
  if [ -n "${MARGINALIA_LLM_API_BASE:-}" ] || [ -n "${MARGINALIA_LLM_MODEL:-}" ]; then
    ONBOARD_ARGS+=(--provider custom)
  else
    ONBOARD_ARGS+=(--provider skip)
  fi
fi
[ -n "${MARGINALIA_LLM_API_BASE:-}" ] && ONBOARD_ARGS+=(--api-base "${MARGINALIA_LLM_API_BASE}")
[ -n "${MARGINALIA_LLM_MODEL:-}" ] && ONBOARD_ARGS+=(--model "${MARGINALIA_LLM_MODEL}")
[ -n "${MARGINALIA_LLM_API_KEY_ENV:-}" ] && ONBOARD_ARGS+=(--api-key-env "${MARGINALIA_LLM_API_KEY_ENV}")
if [ "${MARGINALIA_LLM_SKIP_DISCOVERY:-}" = "1" ] || [ -n "${MARGINALIA_LLM_MODEL:-}" ]; then
  ONBOARD_ARGS+=(--skip-model-discovery)
fi
if [ "${MARGINALIA_LLM_ALLOW_REMOTE:-}" = "1" ]; then
  ONBOARD_ARGS+=(--allow-remote-llm --yes)
fi
if [ ! -e /dev/tty ] || [ "${MARGINALIA_ONBOARD_NONINTERACTIVE:-}" = "1" ]; then
  ONBOARD_ARGS+=(--non-interactive)
  info "no interactive terminal detected — using noninteractive onboarding"
  marginalia "${ONBOARD_ARGS[@]}"
else
  marginalia "${ONBOARD_ARGS[@]}" < /dev/tty
fi
fi  # end fresh-install (vault + LLM) block

# Which vault the daemon should (re)open, and its short label for URLs.
SERVE_VAULT="${VAULT}"
VAULT_LABEL="${VAULT}"
if [ -n "${UPGRADE}" ] && [ -n "${RESTART_VAULT}" ]; then
  SERVE_VAULT="${RESTART_VAULT}"
  VAULT_LABEL="$(basename "${RESTART_VAULT}")"
fi

# ── 6. serve ──────────────────────────────────────────────────────────────
if [ "${MARGINALIA_NO_SERVE:-}" = "1" ]; then
  step "Skipping daemon start (MARGINALIA_NO_SERVE=1)"
else
  if [ -n "${UPGRADE}" ]; then
    step "Restarting the daemon on the new version (vault: ${VAULT_LABEL})"
  else
    step "Starting the Marginalia daemon (UI/REST :7777 + MCP :8201)"
  fi
  marginalia serve --daemon --vault "${SERVE_VAULT}"
  info "waiting for the server to come up ..."
  up=""
  for _ in $(seq 1 30); do
    if curl -fs "${REST_URL}/health" >/dev/null 2>&1; then up="yes"; break; fi
    sleep 1
  done
  if [ -n "${up}" ]; then
    info "health: ${G}ok${X} (${REST_URL})"
  else
    warn "server did not report healthy within 30s — check 'marginalia serve --foreground --vault ${SERVE_VAULT}'"
  fi
fi

# ── 7. wire Claude Code ───────────────────────────────────────────────────
# Register at USER scope (available in every project) with NO ?vault= pin, so it
# defaults to the daemon's active vault. Per-project contextual routing is done by
# dropping a .mcp.json with ?vault=<that project's vault> into the project folder.
GLOBAL_URL="${MCP_URL}"
PROJECT_EXAMPLE="{\"mcpServers\":{\"marginalia\":{\"type\":\"http\",\"url\":\"${MCP_URL}?vault=${VAULT_LABEL}\"}}}"
if [ -n "${UPGRADE}" ]; then
  step "Update mode — Claude Code wiring left as-is"
elif [ "${MARGINALIA_NO_MCP:-}" = "1" ]; then
  step "Skipping Claude Code wiring (MARGINALIA_NO_MCP=1)"
  info "register later with: claude mcp add --scope user marginalia --transport http \"${GLOBAL_URL}\""
elif command -v claude >/dev/null 2>&1; then
  step "Registering the MCP server with Claude Code (user scope, all projects)"
  if claude mcp add --scope user marginalia --transport http "${GLOBAL_URL}" 2>/dev/null; then
    info "added 'marginalia' (4 tools: ask · explore · remember · init_vault) → active vault"
    info "per-project vault: drop a .mcp.json with ?vault=<name> in that project folder"
  else
    warn "couldn't add automatically (already registered?). Run manually if needed:"
    info "claude mcp add --scope user marginalia --transport http \"${GLOBAL_URL}\""
  fi
else
  step "Claude Code CLI not found"
  info "once 'claude' is on PATH, run:"
  info "claude mcp add --scope user marginalia --transport http \"${GLOBAL_URL}\""
fi

# ── done ──────────────────────────────────────────────────────────────────
if [ -n "${UPGRADE}" ]; then
  printf "\n%s🎉 Marginalia updated and restarted.%s\n" "$B$G" "$X"
else
  printf "\n%s🎉 Marginalia is ready.%s\n" "$B$G" "$X"
fi
info "vault    : ${SERVE_VAULT}"
info "web UI   : ${REST_URL}"
info "MCP url  : ${GLOBAL_URL}  (active vault; all projects)"
info "per-proj : add .mcp.json → ${PROJECT_EXAMPLE}"
info "stop     : marginalia stop --vault ${VAULT_LABEL}"
info "Try in Claude Code: \"remember this note: ...\" then \"ask Marginalia about ...\""
