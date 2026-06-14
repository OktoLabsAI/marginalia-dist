#!/usr/bin/env bash
#
# Canonical public-installer tester for Marginalia.
#
# Default mode runs the raw GitHub installer with an isolated HOME/XDG/uv state.
# `--tmux` and `--docker-tmux` run the same raw installer through a real TTY and
# drive prompts with tmux send-keys, producing capture-pane evidence.

set -euo pipefail

DEFAULT_URL="https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/install.sh"
INSTALL_URL="${MARGINALIA_INSTALL_URL:-$DEFAULT_URL}"
TEST_HOME="${MARGINALIA_TEST_HOME:-${TMPDIR:-/tmp}/marginalia-install-test-$(date +%Y%m%d-%H%M%S)}"
ORIGINAL_HOME="${HOME:-}"
VAULT="${MARGINALIA_VAULT:-mynotes}"
PROVIDER="${MARGINALIA_LLM_PROVIDER:-}"
API_BASE="${MARGINALIA_LLM_API_BASE:-}"
MODEL="${MARGINALIA_LLM_MODEL:-}"
PROFILE="interactive"
MODE="direct"
CLEANUP=0
NO_SERVE=0
SESSION="marginalia-install-$(date +%H%M%S)"
CONTAINER="marginalia-install-human"
EVIDENCE=""

usage() {
  cat <<'EOF'
Usage: ./test-install.sh [options]

Runs the public Marginalia installer in an isolated sandbox.

Modes:
  default          Run in this terminal with isolated HOME/XDG/uv state.
  --tmux          Run on this host inside tmux and drive prompts.
  --docker-tmux   Run in a fresh Ubuntu container inside tmux and drive prompts.

Profiles for tmux modes:
  --profile skip       Choose "Skip LLM setup"; verifies no explicit llm block.
  --profile lm-studio  Start a mock LM Studio /v1/models endpoint and choose it.
  --profile ollama     Start a mock Ollama OpenAI-compatible endpoint and choose it.
  --profile litellm    Start a mock LiteLLM Proxy model-info endpoint and choose it.
  --profile hosted-openai  Choose OpenAI with a fake exported key and manual model.
  --profile custom     Choose custom endpoint; requires --api-base and --model.
  --profile interactive  Do not auto-drive prompts; print tmux attach command.

Options:
  --home PATH       Test HOME/evidence directory (default: fresh $TMPDIR path)
  --url URL         Installer URL (default: public raw GitHub install.sh)
  --vault NAME      Test vault name (default: mynotes)
  --provider ID     Pre-fill MARGINALIA_LLM_PROVIDER for direct mode
  --api-base URL    Pre-fill MARGINALIA_LLM_API_BASE
  --model NAME      Pre-fill MARGINALIA_LLM_MODEL
  --session NAME    tmux session name
  --container NAME  Docker container name for --docker-tmux
  --no-serve        Install/configure only; do not start the daemon
  --cleanup         Stop daemon/container and delete the test home after the run
  -h, --help        Show this help

All modes install from the raw URL by default, set MARGINALIA_NO_MCP=1, and
refuse to use your real HOME or ~/.marginalia as the sandbox.
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
    --provider)
      [ "$#" -ge 2 ] || die "--provider requires an id"
      PROVIDER="$2"
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
    --profile)
      [ "$#" -ge 2 ] || die "--profile requires a name"
      PROFILE="$2"
      shift 2
      ;;
    --session)
      [ "$#" -ge 2 ] || die "--session requires a name"
      SESSION="$2"
      shift 2
      ;;
    --container)
      [ "$#" -ge 2 ] || die "--container requires a name"
      CONTAINER="$2"
      shift 2
      ;;
    --tmux)
      MODE="tmux"
      shift
      ;;
    --docker-tmux)
      MODE="docker-tmux"
      shift
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

case "$PROFILE" in
  interactive|skip|lm-studio|ollama|litellm|hosted-openai|custom) ;;
  *) die "unknown profile: $PROFILE" ;;
esac
if [ "$PROFILE" = "custom" ] && { [ -z "$API_BASE" ] || [ -z "$MODEL" ]; }; then
  die "--profile custom requires --api-base and --model"
fi
if [ "$PROFILE" = "hosted-openai" ] && [ -z "$MODEL" ]; then
  MODEL="hosted-human-model"
fi

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v bash >/dev/null 2>&1 || die "bash is required"
if [ "$MODE" = "tmux" ] || [ "$MODE" = "docker-tmux" ]; then
  command -v tmux >/dev/null 2>&1 || die "tmux is required"
fi
if [ "$MODE" = "docker-tmux" ]; then
  command -v docker >/dev/null 2>&1 || die "docker is required"
fi

port_open() {
  local port="$1"
  (echo >"/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1
}

prepare_home() {
  if curl -fsS http://127.0.0.1:7777/health >/dev/null 2>&1 || port_open 7777; then
    die "127.0.0.1:7777 is already in use. Stop the real Marginalia daemon first."
  fi
  if [ "$NO_SERVE" -ne 1 ] && port_open 8201; then
    die "127.0.0.1:8201 is already in use. Stop the process using it first."
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
  EVIDENCE="$TEST_HOME/evidence-${SESSION}.txt"
}

cleanup_sandbox() {
  local tool_bin="$TEST_HOME/.local/bin"
  if [ -x "$tool_bin/marginalia" ]; then
    HOME="$TEST_HOME" \
    XDG_DATA_HOME="$TEST_HOME/.local/share" \
    XDG_CACHE_HOME="$TEST_HOME/.cache" \
    XDG_CONFIG_HOME="$TEST_HOME/.config" \
    UV_CACHE_DIR="$TEST_HOME/.cache/uv" \
    PATH="$tool_bin:$PATH" \
      "$tool_bin/marginalia" stop --vault "$VAULT" >/dev/null 2>&1 || true
  fi
  if [ "$MODE" = "docker-tmux" ]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi
  tmux kill-session -t "$SESSION" >/dev/null 2>&1 || true
  rm -rf "$TEST_HOME"
}

write_host_runner() {
  local runner="$TEST_HOME/host-runner.sh"
  cat > "$runner" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail

start_mock_lm_studio() {
  python3 - <<'PY' &
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = "mac-human-model"

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.rstrip("/") == "/v1/models":
            body = json.dumps({"data": [{"id": MODEL}]}).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()
    def log_message(self, *_args):
        return

ThreadingHTTPServer(("127.0.0.1", 1234), Handler).serve_forever()
PY
  MOCK_PID="$!"
  trap 'kill "$MOCK_PID" >/dev/null 2>&1 || true' EXIT
  for _ in $(seq 1 30); do
    curl -fsS http://127.0.0.1:1234/v1/models >/dev/null 2>&1 && return
    sleep 0.2
  done
  echo "mock LM Studio server did not start" >&2
  exit 80
}

start_mock_ollama() {
  python3 - <<'PY' &
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = "mac-ollama-human-model"

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.rstrip("/") == "/v1/models":
            body = json.dumps({"data": [{"id": MODEL}]}).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()
    def log_message(self, *_args):
        return

ThreadingHTTPServer(("127.0.0.1", 11434), Handler).serve_forever()
PY
  MOCK_PID="$!"
  trap 'kill "$MOCK_PID" >/dev/null 2>&1 || true' EXIT
  for _ in $(seq 1 30); do
    curl -fsS http://127.0.0.1:11434/v1/models >/dev/null 2>&1 && return
    sleep 0.2
  done
  echo "mock Ollama server did not start" >&2
  exit 80
}

start_mock_litellm() {
  python3 - <<'PY' &
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = "mac-litellm-human-model"

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.rstrip("/") == "/v1/model/info":
            body = json.dumps({
                "data": [
                    {
                        "model_name": MODEL,
                        "litellm_params": {
                            "model": "openai/hidden-upstream",
                            "api_key": "should-not-surface"
                        }
                    }
                ]
            }).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()
    def log_message(self, *_args):
        return

ThreadingHTTPServer(("127.0.0.1", 4000), Handler).serve_forever()
PY
  MOCK_PID="$!"
  trap 'kill "$MOCK_PID" >/dev/null 2>&1 || true' EXIT
  for _ in $(seq 1 30); do
    curl -fsS http://127.0.0.1:4000/v1/model/info >/dev/null 2>&1 && return
    sleep 0.2
  done
  echo "mock LiteLLM server did not start" >&2
  exit 80
}

export HOME="$TEST_HOME"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_CONFIG_HOME="$HOME/.config"
export UV_CACHE_DIR="$HOME/.cache/uv"
export MARGINALIA_NO_MCP=1
export MARGINALIA_VAULT="$VAULT"
[ "$NO_SERVE" = "1" ] && export MARGINALIA_NO_SERVE=1

if [ "$PROFILE" = "lm-studio" ]; then
  start_mock_lm_studio
elif [ "$PROFILE" = "ollama" ]; then
  start_mock_ollama
elif [ "$PROFILE" = "litellm" ]; then
  start_mock_litellm
elif [ "$PROFILE" = "hosted-openai" ]; then
  export MARGINALIA_LLM_MODEL="$MODEL"
  export MARGINALIA_LLM_API_KEY_ENV=MARGINALIA_HOSTED_TEST_KEY
  export MARGINALIA_HOSTED_TEST_KEY=sk-fake-public-installer-test
fi

printf 'TEST_HOME=%s\nINSTALL_URL=%s\nPROFILE=%s\n' "$HOME" "$INSTALL_URL" "$PROFILE"
curl -fsSL "$INSTALL_URL" | bash

export PATH="$HOME/.local/bin:$PATH"
marginalia --help | sed -n '1,12p'
marginalia vault current
if [ "$NO_SERVE" != "1" ]; then
  curl -fsS http://127.0.0.1:7777/health
fi
YAML="$HOME/.marginalia/vaults/$VAULT/marginalia.yaml"
case "$PROFILE" in
  skip)
    ! grep -q '^llm:' "$YAML"
    ;;
  lm-studio)
    grep -q 'provider: lm_studio' "$YAML"
    grep -q 'mac-human-model' "$YAML"
    ;;
  ollama)
    grep -q 'provider: ollama' "$YAML"
    grep -q 'mac-ollama-human-model' "$YAML"
    ;;
  litellm)
    grep -q 'provider: litellm_proxy' "$YAML"
    grep -q 'api_base: http://127.0.0.1:4000' "$YAML"
    grep -q 'mac-litellm-human-model' "$YAML"
    ! grep -q 'should-not-surface' "$YAML"
    ;;
  hosted-openai)
    grep -q 'provider: openai' "$YAML"
    grep -q "$MODEL" "$YAML"
    grep -q 'api_key_env: MARGINALIA_HOSTED_TEST_KEY' "$YAML"
    ! grep -q 'sk-fake-public-installer-test' "$YAML"
    ;;
  custom)
    grep -q "$MODEL" "$YAML"
    ;;
esac
marginalia stop --vault "$VAULT" >/dev/null 2>&1 || true
echo MAC_TMUX_HUMAN_INSTALL_OK
RUNNER
  chmod +x "$runner"
  printf '%s\n' "$runner"
}

write_docker_runner() {
  local runner="$TEST_HOME/docker-runner.sh"
  cat > "$runner" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null
apt-get install -y --no-install-recommends ca-certificates curl bash python3 >/dev/null

start_mock_lm_studio() {
  python3 - <<'PY' &
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = "docker-human-model"

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.rstrip("/") == "/v1/models":
            body = json.dumps({"data": [{"id": MODEL}]}).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()
    def log_message(self, *_args):
        return

ThreadingHTTPServer(("127.0.0.1", 1234), Handler).serve_forever()
PY
  MOCK_PID="$!"
  trap 'kill "$MOCK_PID" >/dev/null 2>&1 || true' EXIT
  for _ in $(seq 1 30); do
    curl -fsS http://127.0.0.1:1234/v1/models >/dev/null 2>&1 && return
    sleep 0.2
  done
  echo "mock LM Studio server did not start" >&2
  exit 80
}

start_mock_ollama() {
  python3 - <<'PY' &
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = "docker-ollama-human-model"

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.rstrip("/") == "/v1/models":
            body = json.dumps({"data": [{"id": MODEL}]}).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()
    def log_message(self, *_args):
        return

ThreadingHTTPServer(("127.0.0.1", 11434), Handler).serve_forever()
PY
  MOCK_PID="$!"
  trap 'kill "$MOCK_PID" >/dev/null 2>&1 || true' EXIT
  for _ in $(seq 1 30); do
    curl -fsS http://127.0.0.1:11434/v1/models >/dev/null 2>&1 && return
    sleep 0.2
  done
  echo "mock Ollama server did not start" >&2
  exit 80
}

start_mock_litellm() {
  python3 - <<'PY' &
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = "docker-litellm-human-model"

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.rstrip("/") == "/v1/model/info":
            body = json.dumps({
                "data": [
                    {
                        "model_name": MODEL,
                        "litellm_params": {
                            "model": "openai/hidden-upstream",
                            "api_key": "should-not-surface"
                        }
                    }
                ]
            }).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()
    def log_message(self, *_args):
        return

ThreadingHTTPServer(("127.0.0.1", 4000), Handler).serve_forever()
PY
  MOCK_PID="$!"
  trap 'kill "$MOCK_PID" >/dev/null 2>&1 || true' EXIT
  for _ in $(seq 1 30); do
    curl -fsS http://127.0.0.1:4000/v1/model/info >/dev/null 2>&1 && return
    sleep 0.2
  done
  echo "mock LiteLLM server did not start" >&2
  exit 80
}

export MARGINALIA_NO_MCP=1
export MARGINALIA_VAULT="$VAULT"
[ "$NO_SERVE" = "1" ] && export MARGINALIA_NO_SERVE=1

if [ "$PROFILE" = "lm-studio" ]; then
  start_mock_lm_studio
elif [ "$PROFILE" = "ollama" ]; then
  start_mock_ollama
elif [ "$PROFILE" = "litellm" ]; then
  start_mock_litellm
elif [ "$PROFILE" = "hosted-openai" ]; then
  export MARGINALIA_LLM_MODEL="$MODEL"
  export MARGINALIA_LLM_API_KEY_ENV=MARGINALIA_HOSTED_TEST_KEY
  export MARGINALIA_HOSTED_TEST_KEY=sk-fake-public-installer-test
fi

printf 'INSTALL_URL=%s\nPROFILE=%s\n' "$INSTALL_URL" "$PROFILE"
curl -fsSL "$INSTALL_URL" | bash

export PATH="$HOME/.local/bin:$PATH"
marginalia --help | sed -n '1,12p'
marginalia vault current
if [ "$NO_SERVE" != "1" ]; then
  curl -fsS http://127.0.0.1:7777/health
fi
YAML="$HOME/.marginalia/vaults/$VAULT/marginalia.yaml"
case "$PROFILE" in
  skip)
    ! grep -q '^llm:' "$YAML"
    ;;
  lm-studio)
    grep -q 'provider: lm_studio' "$YAML"
    grep -q 'docker-human-model' "$YAML"
    ;;
  ollama)
    grep -q 'provider: ollama' "$YAML"
    grep -q 'docker-ollama-human-model' "$YAML"
    ;;
  litellm)
    grep -q 'provider: litellm_proxy' "$YAML"
    grep -q 'api_base: http://127.0.0.1:4000' "$YAML"
    grep -q 'docker-litellm-human-model' "$YAML"
    ! grep -q 'should-not-surface' "$YAML"
    ;;
  hosted-openai)
    grep -q 'provider: openai' "$YAML"
    grep -q "$MODEL" "$YAML"
    grep -q 'api_key_env: MARGINALIA_HOSTED_TEST_KEY' "$YAML"
    ! grep -q 'sk-fake-public-installer-test' "$YAML"
    ;;
  custom)
    grep -q "$MODEL" "$YAML"
    ;;
esac
marginalia stop --vault "$VAULT" >/dev/null 2>&1 || true
echo DOCKER_TMUX_HUMAN_INSTALL_OK
RUNNER
  chmod +x "$runner"
  printf '%s\n' "$runner"
}

capture() {
  tmux capture-pane -pt "$SESSION" -S -4000 > "$EVIDENCE" || true
}

wait_for_text() {
  local needle="$1" timeout="$2" start now
  start="$(date +%s)"
  while true; do
    capture
    if grep -Fq "$needle" "$EVIDENCE"; then
      return 0
    fi
    now="$(date +%s)"
    if [ $((now - start)) -ge "$timeout" ]; then
      printf 'timed out waiting for %s; evidence: %s\n' "$needle" "$EVIDENCE" >&2
      return 1
    fi
    sleep 1
  done
}

drive_profile() {
  case "$PROFILE" in
    interactive)
      printf 'tmux session started. Attach and drive prompts:\n  tmux attach -t %s\n' "$SESSION"
      return
      ;;
    skip)
      wait_for_text "Provider" 900
      tmux send-keys -t "$SESSION" "0" C-m
      ;;
    lm-studio)
      wait_for_text "Provider" 900
      tmux send-keys -t "$SESSION" "2" C-m
      wait_for_text "Base URL" 120
      tmux send-keys -t "$SESSION" C-m
      wait_for_text "API key" 120
      tmux send-keys -t "$SESSION" C-m
      wait_for_text "Model" 120
      tmux send-keys -t "$SESSION" C-m
      ;;
    ollama)
      wait_for_text "Provider" 900
      tmux send-keys -t "$SESSION" "3" C-m
      wait_for_text "Base URL" 120
      tmux send-keys -t "$SESSION" C-m
      wait_for_text "API key" 120
      tmux send-keys -t "$SESSION" C-m
      wait_for_text "Model" 120
      tmux send-keys -t "$SESSION" C-m
      ;;
    litellm)
      wait_for_text "Provider" 900
      tmux send-keys -t "$SESSION" "4" C-m
      wait_for_text "Base URL" 120
      tmux send-keys -t "$SESSION" C-m
      wait_for_text "API key" 120
      tmux send-keys -t "$SESSION" C-m
      wait_for_text "Model" 120
      tmux send-keys -t "$SESSION" C-m
      ;;
    hosted-openai)
      wait_for_text "Provider" 900
      tmux send-keys -t "$SESSION" "6" C-m
      wait_for_text "Base URL" 120
      tmux send-keys -t "$SESSION" C-m
      wait_for_text "Allow this endpoint?" 120
      tmux send-keys -t "$SESSION" "y" C-m
      wait_for_text "API key" 120
      tmux send-keys -t "$SESSION" C-m
      ;;
    custom)
      wait_for_text "Provider" 900
      tmux send-keys -t "$SESSION" "9" C-m
      wait_for_text "Base URL" 120
      tmux send-keys -t "$SESSION" "$API_BASE" C-m
      wait_for_text "API key" 120
      tmux send-keys -t "$SESSION" C-m
      wait_for_text "Model" 120
      tmux send-keys -t "$SESSION" "$MODEL" C-m
      ;;
  esac
}

run_direct() {
  local xdg_data="$TEST_HOME/.local/share"
  local xdg_cache="$TEST_HOME/.cache"
  local xdg_config="$TEST_HOME/.config"
  local uv_cache="$TEST_HOME/.cache/uv"
  local tool_bin="$TEST_HOME/.local/bin"

  printf 'Marginalia public installer test\n'
  printf '  installer: %s\n' "$INSTALL_URL"
  printf '  test HOME: %s\n' "$TEST_HOME"
  printf '  vault:     %s\n' "$VAULT"
  printf '  MCP:       disabled (MARGINALIA_NO_MCP=1)\n\n'

  (
    export HOME="$TEST_HOME"
    export XDG_DATA_HOME="$xdg_data"
    export XDG_CACHE_HOME="$xdg_cache"
    export XDG_CONFIG_HOME="$xdg_config"
    export UV_CACHE_DIR="$uv_cache"
    export MARGINALIA_NO_MCP=1
    export MARGINALIA_VAULT="$VAULT"
    [ "$NO_SERVE" -eq 1 ] && export MARGINALIA_NO_SERVE=1
    [ -n "$PROVIDER" ] && export MARGINALIA_LLM_PROVIDER="$PROVIDER"
    [ -n "$API_BASE" ] && export MARGINALIA_LLM_API_BASE="$API_BASE"
    [ -n "$MODEL" ] && export MARGINALIA_LLM_MODEL="$MODEL"
    if [ -n "$API_BASE" ] || [ -n "$MODEL" ] || [ -n "$PROVIDER" ]; then
      export MARGINALIA_ONBOARD_NONINTERACTIVE=1
    fi
    curl -fsSL "$INSTALL_URL" | bash
  )

  if [ -x "$tool_bin/marginalia" ]; then
    printf '\nInstalled CLI:\n'
    PATH="$tool_bin:$PATH" "$tool_bin/marginalia" --help | sed -n '1,12p'
  fi
}

run_host_tmux() {
  local runner
  runner="$(write_host_runner)"
  tmux kill-session -t "$SESSION" >/dev/null 2>&1 || true
  tmux new-session -d -s "$SESSION" -x 200 -y 90 \
    "INSTALL_URL='$INSTALL_URL' TEST_HOME='$TEST_HOME' VAULT='$VAULT' PROFILE='$PROFILE' NO_SERVE='$NO_SERVE' MODEL='$MODEL' bash '$runner'"
  tmux set-option -t "$SESSION" remain-on-exit on
  drive_profile
  if [ "$PROFILE" != "interactive" ]; then
    wait_for_text "MAC_TMUX_HUMAN_INSTALL_OK" 1800
    capture
    if [ "$PROFILE" = "hosted-openai" ]; then
      if grep -q 'sk-fake-public-installer-test' "$EVIDENCE"; then
        die "fake hosted secret leaked into tmux evidence: $EVIDENCE"
      fi
    fi
    printf 'tmux host install passed. Evidence: %s\n' "$EVIDENCE"
  fi
}

run_docker_tmux() {
  local runner
  runner="$(write_docker_runner)"
  tmux kill-session -t "$SESSION" >/dev/null 2>&1 || true
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  tmux new-session -d -s "$SESSION" -x 200 -y 90 \
    "docker run --rm -it --name '$CONTAINER' -e INSTALL_URL='$INSTALL_URL' -e VAULT='$VAULT' -e PROFILE='$PROFILE' -e NO_SERVE='$NO_SERVE' -e MODEL='$MODEL' -v '$runner:/runner.sh:ro' ubuntu:24.04 bash /runner.sh"
  tmux set-option -t "$SESSION" remain-on-exit on
  drive_profile
  if [ "$PROFILE" != "interactive" ]; then
    wait_for_text "DOCKER_TMUX_HUMAN_INSTALL_OK" 2400
    capture
    if [ "$PROFILE" = "hosted-openai" ]; then
      if grep -q 'sk-fake-public-installer-test' "$EVIDENCE"; then
        die "fake hosted secret leaked into tmux evidence: $EVIDENCE"
      fi
    fi
    printf 'Docker tmux install passed. Evidence: %s\n' "$EVIDENCE"
  fi
}

prepare_home
if [ "$CLEANUP" -eq 1 ]; then
  trap cleanup_sandbox EXIT
fi

case "$MODE" in
  direct) run_direct ;;
  tmux) run_host_tmux ;;
  docker-tmux) run_docker_tmux ;;
esac

printf '\nTest install finished.\n'
if [ "$CLEANUP" -eq 1 ]; then
  printf 'Test home cleaned: %s\n' "$TEST_HOME"
else
  printf 'Sandbox/evidence kept at:\n  %s\n' "$TEST_HOME"
  [ -n "$EVIDENCE" ] && [ -f "$EVIDENCE" ] && printf 'Evidence:\n  %s\n' "$EVIDENCE"
fi
