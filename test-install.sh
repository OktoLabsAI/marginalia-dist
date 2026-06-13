#!/usr/bin/env bash
#
# Safe local tester for the public Marginalia installer.
#
# Runs the canonical raw GitHub installer with an isolated HOME/XDG/uv state so
# your real ~/.marginalia vaults and Claude config are not touched.

set -euo pipefail

DEFAULT_URL="https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/install.sh"
INSTALL_URL="${MARGINALIA_INSTALL_URL:-$DEFAULT_URL}"
TEST_HOME="${MARGINALIA_TEST_HOME:-${TMPDIR:-/tmp}/marginalia-install-test-$(date +%Y%m%d-%H%M%S)}"
ORIGINAL_HOME="${HOME:-}"
VAULT="${MARGINALIA_VAULT:-mynotes}"
API_BASE=""
MODEL=""
CLEANUP=0
NO_SERVE=0

usage() {
  cat <<'EOF'
Usage: ./test-install.sh [options]

Runs the public Marginalia installer in an isolated test home.

Options:
  --home PATH       Test HOME to use (default: a fresh $TMPDIR/marginalia-install-test-* path)
  --url URL         Installer URL (default: public raw GitHub install.sh)
  --vault NAME      Test vault name (default: mynotes)
  --api-base URL    Pre-fill MARGINALIA_LLM_API_BASE for noninteractive smoke tests
  --model NAME      Pre-fill MARGINALIA_LLM_MODEL for noninteractive smoke tests
  --no-serve        Install/configure only; do not start the daemon
  --cleanup         Stop the test daemon and delete the test home after the run
  -h, --help        Show this help

Default mode is interactive: answer the installer prompts in your terminal.
Your real ~/.marginalia and Claude MCP config are not used.
EOF
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --home)
      [ "$#" -ge 2 ] || die "--home requires a path"
      TEST_HOME="$2"
      shift 2
      ;;
    --url)
      [ "$#" -ge 2 ] || die "--url requires a URL"
      INSTALL_URL="$2"
      shift 2
      ;;
    --vault)
      [ "$#" -ge 2 ] || die "--vault requires a name"
      VAULT="$2"
      shift 2
      ;;
    --api-base)
      [ "$#" -ge 2 ] || die "--api-base requires a URL"
      API_BASE="$2"
      shift 2
      ;;
    --model)
      [ "$#" -ge 2 ] || die "--model requires a name"
      MODEL="$2"
      shift 2
      ;;
    --no-serve)
      NO_SERVE=1
      shift
      ;;
    --cleanup)
      CLEANUP=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v bash >/dev/null 2>&1 || die "bash is required"

port_open() {
  local port="$1"
  (echo >"/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1
}

if curl -fsS http://127.0.0.1:7777/health >/dev/null 2>&1 || port_open 7777; then
  die "127.0.0.1:7777 is already in use. Stop the real Marginalia daemon before this isolated install test."
fi
if [ "$NO_SERVE" -ne 1 ] && port_open 8201; then
  die "127.0.0.1:8201 is already in use. Stop the process using it before the full install test."
fi

TEST_HOME="$(mkdir -p "$TEST_HOME" && cd "$TEST_HOME" && pwd)"
if [ "$TEST_HOME" = "/" ]; then
  die "refusing to use / as a test home"
fi
if [ -n "$ORIGINAL_HOME" ]; then
  ORIGINAL_HOME="$(cd "$ORIGINAL_HOME" && pwd)"
  case "$TEST_HOME" in
    "$ORIGINAL_HOME"|"$ORIGINAL_HOME/.marginalia"|"$ORIGINAL_HOME/.marginalia"/*)
      die "refusing to use your real HOME or ~/.marginalia as the test home"
      ;;
  esac
fi
XDG_DATA_HOME="$TEST_HOME/.local/share"
XDG_CACHE_HOME="$TEST_HOME/.cache"
XDG_CONFIG_HOME="$TEST_HOME/.config"
UV_CACHE_DIR="$TEST_HOME/.cache/uv"
TOOL_BIN="$TEST_HOME/.local/bin"

cleanup() {
  if [ -x "$TOOL_BIN/marginalia" ]; then
    HOME="$TEST_HOME" \
    XDG_DATA_HOME="$XDG_DATA_HOME" \
    XDG_CACHE_HOME="$XDG_CACHE_HOME" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    UV_CACHE_DIR="$UV_CACHE_DIR" \
    PATH="$TOOL_BIN:$PATH" \
      "$TOOL_BIN/marginalia" stop --vault "$VAULT" >/dev/null 2>&1 || true
  fi
  rm -rf "$TEST_HOME"
}

if [ "$CLEANUP" -eq 1 ]; then
  trap cleanup EXIT
fi

printf 'Marginalia public installer test\n'
printf '  installer: %s\n' "$INSTALL_URL"
printf '  test HOME: %s\n' "$TEST_HOME"
printf '  vault:     %s\n' "$VAULT"
printf '  MCP:       disabled (MARGINALIA_NO_MCP=1)\n'
if [ "$CLEANUP" -eq 1 ]; then
  printf '  cleanup:   yes\n'
else
  printf '  cleanup:   no; sandbox is kept for inspection\n'
fi
printf '\n'

(
  export HOME="$TEST_HOME"
  export XDG_DATA_HOME
  export XDG_CACHE_HOME
  export XDG_CONFIG_HOME
  export UV_CACHE_DIR
  export MARGINALIA_NO_MCP=1
  export MARGINALIA_VAULT="$VAULT"
  [ "$NO_SERVE" -eq 1 ] && export MARGINALIA_NO_SERVE=1
  [ -n "$API_BASE" ] && export MARGINALIA_LLM_API_BASE="$API_BASE"
  [ -n "$MODEL" ] && export MARGINALIA_LLM_MODEL="$MODEL"

  curl -fsSL "$INSTALL_URL" | bash
)

if [ -x "$TOOL_BIN/marginalia" ]; then
  printf '\nInstalled CLI:\n'
  PATH="$TOOL_BIN:$PATH" "$TOOL_BIN/marginalia" --help | sed -n '1,12p'
fi

printf '\nTest install finished.\n'
if [ "$CLEANUP" -eq 1 ]; then
  printf 'Test home cleaned: %s\n' "$TEST_HOME"
else
  cat <<EOF

Sandbox kept at:
  $TEST_HOME

To stop and remove the sandbox later:
  HOME="$TEST_HOME" XDG_DATA_HOME="$XDG_DATA_HOME" XDG_CACHE_HOME="$XDG_CACHE_HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" UV_CACHE_DIR="$UV_CACHE_DIR" PATH="$TOOL_BIN:\$PATH" "$TOOL_BIN/marginalia" stop --vault "$VAULT" || true
  rm -rf "$TEST_HOME"
EOF
fi
