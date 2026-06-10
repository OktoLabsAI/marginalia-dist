#!/usr/bin/env bash
#
# Marginalia one-shot installer.
#
#   curl -fsSL https://<dist-host>/install.sh | bash
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
#   MARGINALIA_LLM_API_BASE OpenAI-compatible base URL (skips the prompt)
#   MARGINALIA_LLM_MODEL    model name                 (skips the prompt)
#   MARGINALIA_NO_SERVE=1   install + configure only; don't start the daemon
#   MARGINALIA_NO_MCP=1     don't run `claude mcp add`
#
set -euo pipefail

# ── config ────────────────────────────────────────────────────────────────
# The public distribution copy of this script bakes a release-wheel URL here so
# `curl … | bash` needs no env. Empty in the source repo (which clones instead).
DEFAULT_WHEEL_URL="${MARGINALIA_DEFAULT_WHEEL_URL:-https://github.com/OktoLabsAI/marginalia-dist/releases/download/v0.0.8/marginalia-0.0.8-py3-none-any.whl}"
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
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; X=$'\033[0m'
else B=""; G=""; Y=""; R=""; D=""; X=""; fi
step() { printf "\n%s==>%s %s%s%s\n" "$B$G" "$X" "$B" "$1" "$X"; }
info() { printf "    %s\n" "$1"; }
warn() { printf "%s !! %s%s\n" "$Y" "$1" "$X"; }
die()  { printf "%serror:%s %s\n" "$R" "$X" "$1" >&2; exit 1; }

# Read a value from the real terminal even when stdin is the piped script.
prompt() { # prompt <var> <message> [default]
  local __var="$1" __msg="$2" __def="${3:-}" __ans=""
  if [ -e /dev/tty ]; then
    printf "%s%s%s " "$B" "$__msg" "$X" > /dev/tty
    [ -n "$__def" ] && printf "%s[%s]%s " "$D" "$__def" "$X" > /dev/tty
    IFS= read -r __ans < /dev/tty || __ans=""
  fi
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

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

# ── 3. install the global tool ────────────────────────────────────────────
step "Installing the marginalia + kg commands (extras: ${EXTRAS})"
uv tool install --force --python "${PY_VERSION}" "${SPEC}"
[ -n "${CLONE_TMP}" ] && rm -rf "${CLONE_TMP}"
if ! command -v marginalia >/dev/null 2>&1; then
  export PATH="${HOME}/.local/bin:${PATH}"
  command -v marginalia >/dev/null 2>&1 \
    || die "marginalia installed but not on PATH. Run 'uv tool update-shell', restart your shell, re-run."
fi
info "marginalia: $(command -v marginalia)"

# ── 4. vault ──────────────────────────────────────────────────────────────
step "Creating vault '${VAULT}' (packs: ${PACKS})"
if [ -f "${VAULT_DIR}/marginalia.yaml" ]; then
  info "vault already exists at ${VAULT_DIR} — leaving it as-is"
  marginalia vault use "${VAULT}" >/dev/null 2>&1 || true
else
  marginalia vault create "${VAULT}" --packs "${PACKS}" --use
  info "created ${VAULT_DIR}"
fi

# ── 5. LLM endpoint (needed for ask + remember) ───────────────────────────
step "Configuring the LLM endpoint (ask + remember need one; explore does not)"
YAML="${VAULT_DIR}/marginalia.yaml"
if grep -q '^llm:' "${YAML}" 2>/dev/null; then
  info "an llm: block already exists — leaving it untouched"
else
  API_BASE="${MARGINALIA_LLM_API_BASE:-}"
  MODEL="${MARGINALIA_LLM_MODEL:-}"
  if [ -z "${API_BASE}" ] || [ -z "${MODEL}" ]; then
    info "Point Marginalia at any OpenAI-compatible endpoint (LM Studio, Ollama, llama.cpp, vLLM, a remote box...)."
    info "Press Enter to skip — explore() works now; add the block later to enable ask()/remember()."
    [ -z "${API_BASE}" ] && prompt API_BASE "  LLM api_base URL:" "http://localhost:1234/v1"
    [ -z "${MODEL}" ]    && prompt MODEL    "  LLM model name:"  ""
  fi
  if [ -n "${API_BASE}" ] && [ -n "${MODEL}" ]; then
    cat >> "${YAML}" <<EOF
llm:
  allow_remote: true
  defaults:
    provider: openai
    api_base: ${API_BASE}
    model: ${MODEL}
    max_tokens: 16000
    temperature: 0.7
  extraction:
    enable_thinking: false
  judge:
    temperature: 0.2
    enable_thinking: false
EOF
    info "wrote llm: block → ${MODEL} @ ${API_BASE}"
  else
    cat >> "${YAML}" <<'EOF'
# llm:                       # ← uncomment + fill in to enable ask() / remember()
#   allow_remote: true
#   defaults:
#     provider: openai
#     api_base: http://localhost:1234/v1   # your OpenAI-compatible endpoint
#     model: your-model-name
#     max_tokens: 16000
EOF
    warn "no endpoint given — wrote a commented placeholder. ask()/remember() stay disabled until you edit ${YAML}"
  fi
fi

# ── 6. serve ──────────────────────────────────────────────────────────────
if [ "${MARGINALIA_NO_SERVE:-}" = "1" ]; then
  step "Skipping daemon start (MARGINALIA_NO_SERVE=1)"
else
  step "Starting the Marginalia daemon (UI/REST :7777 + MCP :8201)"
  marginalia serve --daemon --vault "${VAULT}"
  info "waiting for the server to come up ..."
  up=""
  for _ in $(seq 1 30); do
    if curl -fs "${REST_URL}/health" >/dev/null 2>&1; then up="yes"; break; fi
    sleep 1
  done
  if [ -n "${up}" ]; then
    info "health: ${G}ok${X} (${REST_URL})"
  else
    warn "server did not report healthy within 30s — check 'marginalia serve --foreground --vault ${VAULT}'"
  fi
fi

# ── 7. wire Claude Code ───────────────────────────────────────────────────
CONNECT_URL="${MCP_URL}?vault=${VAULT}"
if [ "${MARGINALIA_NO_MCP:-}" = "1" ]; then
  step "Skipping Claude Code wiring (MARGINALIA_NO_MCP=1)"
  info "register later with: claude mcp add marginalia --transport http \"${CONNECT_URL}\""
elif command -v claude >/dev/null 2>&1; then
  step "Registering the MCP server with Claude Code"
  if claude mcp add marginalia --transport http "${CONNECT_URL}" 2>/dev/null; then
    info "added 'marginalia' (4 tools: ask · explore · remember · init_vault)"
  else
    warn "couldn't add automatically (already registered?). Run manually if needed:"
    info "claude mcp add marginalia --transport http \"${CONNECT_URL}\""
  fi
else
  step "Claude Code CLI not found"
  info "once 'claude' is on PATH, run:"
  info "claude mcp add marginalia --transport http \"${CONNECT_URL}\""
fi

# ── done ──────────────────────────────────────────────────────────────────
printf "\n%s🎉 Marginalia is ready.%s\n" "$B$G" "$X"
info "vault   : ${VAULT_DIR}"
info "web UI  : ${REST_URL}"
info "MCP url : ${CONNECT_URL}"
info "stop    : marginalia stop --vault ${VAULT}"
info "Try in Claude Code: \"remember this note: ...\" then \"ask Marginalia about ...\""
