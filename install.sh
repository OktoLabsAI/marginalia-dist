#!/usr/bin/env bash
#
# Marginalia one-shot installer.
#
#   curl -fsSL https://<dist-host>/install.sh | bash
#
# Takes a fresh machine from zero to a running Marginalia application wired into
# Claude Code: prereqs → install tool → serve/open the app → register MCP.
# Vault creation and provider setup are application-first by default. Automation
# may explicitly preseed one vault and run CLI onboarding with MARGINALIA_VAULT.
#
# Everything is overridable by environment variable so the SAME script works
# piped to bash (non-interactive) and run from a clone (interactive):
#
#   MARGINALIA_SRC          path to an existing checkout (skips clone)
#   MARGINALIA_WHEEL        path/URL to a built wheel (skips clone+source build)
#   MARGINALIA_EXPECTED_VERSION required version when overriding the wheel
#   MARGINALIA_MANIFEST     release-manifest.json path/URL for wheel verification
#   MARGINALIA_WHEEL_SHA256 required SHA-256 for a custom wheel without a manifest
#   MARGINALIA_REPO         git URL to clone   (default: SSH source repo)
#   MARGINALIA_REF          git ref to check out (default: repo default branch)
#   MARGINALIA_VAULT        optional vault name to preseed before opening the app
#   MARGINALIA_PACKS        preseed type packs (requires MARGINALIA_VAULT)
#   MARGINALIA_LLM_PROVIDER preseed provider passed to `marginalia onboard`
#   MARGINALIA_LLM_API_BASE provider base URL
#   MARGINALIA_LLM_MODEL    model name (also skips model discovery)
#   MARGINALIA_LLM_API_KEY_ENV MARGINALIA_* environment variable holding the key
#   MARGINALIA_LLM_ALLOW_REMOTE=1 explicit opt-in for a non-loopback LLM endpoint
#   MARGINALIA_ONBOARD_NONINTERACTIVE=1 never prompt during onboarding
#   MARGINALIA_NO_SERVE=1   install + configure only; don't start the daemon
#   MARGINALIA_NO_OPEN=1    don't open the verified local UI in a browser
#   MARGINALIA_NO_MCP=1     don't run `claude mcp add`
#
set -euo pipefail

# ── config ────────────────────────────────────────────────────────────────
# The public distribution copy of this script bakes a release-wheel URL here so
# `curl … | bash` needs no env. Empty in the source repo (which clones instead).
DEFAULT_WHEEL_URL="${MARGINALIA_DEFAULT_WHEEL_URL:-https://github.com/OktoLabsAI/marginalia-dist/releases/download/v0.0.41/marginalia-0.0.41-py3-none-any.whl}"
DEFAULT_MANIFEST_URL="${MARGINALIA_DEFAULT_MANIFEST_URL:-https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/release-manifest.json}"
EXPECTED_VERSION="${MARGINALIA_EXPECTED_VERSION:-0.0.41}"
EXTRAS="serve,litellm"
PY_VERSION="3.12"
REPO="${MARGINALIA_REPO:-git@github.com:OktoLabsAI/marginalia.git}"
REF="${MARGINALIA_REF:-}"
VAULT="${MARGINALIA_VAULT:-}"
PACKS="${MARGINALIA_PACKS:-core,research,personal}"
HOME_ROOT="${HOME}/.marginalia"
VAULT_DIR=""
if [ -n "${VAULT}" ]; then
  VAULT_DIR="${HOME_ROOT}/vaults/${VAULT}"
fi
REST_URL="http://127.0.0.1:7777"
MCP_URL="http://127.0.0.1:8201/mcp"
DAEMON_TOKEN_FILE="${HOME_ROOT}/daemon-7777.token"
DAEMON_RUNTIME_ROOT="${HOME_ROOT}/runtime"
DAEMON_PID_FILE="${DAEMON_RUNTIME_ROOT}/.marginalia/server.pid"

# Transaction state. The EXIT trap restores the exact prior uv tool if anything
# fails after activation begins; vault/provider configuration always remains
# outside the tool directory and is never replaced by the transaction.
WORK_TMP=""
CLONE_TMP=""
TOOL_ROOT=""
TOOL_BIN=""
BACKUP_ROOT=""
PREVIOUS_VERSION=""
PREVIOUS_COMMAND=""
PREVIOUS_DAEMON_VAULT=""
LEGACY_DAEMON=""
ACTIVATION_STARTED=""
ACTIVATION_COMMITTED=""
CANDIDATE_DAEMON_STARTED=""
WAS_RUNNING=""
SHUTDOWN_REQUESTED=""

# ── pretty logging ────────────────────────────────────────────────────────
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; X=$'\033[0m'
else B=""; G=""; Y=""; R=""; X=""; fi
step() { printf "\n%s==>%s %s%s%s\n" "$B$G" "$X" "$B" "$1" "$X"; }
info() { printf "    %s\n" "$1"; }
warn() { printf "%s !! %s%s\n" "$Y" "$1" "$X"; }
die()  { printf "%serror:%s %s\n" "$R" "$X" "$1" >&2; exit 1; }

validate_preseed_inputs() {
  [ -n "${VAULT}" ] && return 0

  local name value
  for name in \
    MARGINALIA_PACKS \
    MARGINALIA_LLM_PROVIDER \
    MARGINALIA_LLM_API_BASE \
    MARGINALIA_LLM_MODEL \
    MARGINALIA_LLM_API_KEY_ENV \
    MARGINALIA_LLM_SKIP_DISCOVERY \
    MARGINALIA_LLM_ALLOW_REMOTE \
    MARGINALIA_ALLOW_REMOTE_LLM \
    MARGINALIA_ONBOARD_NONINTERACTIVE
  do
    value="${!name:-}"
    if [ -n "${value}" ]; then
      die "${name} requires MARGINALIA_VAULT; omit preseed settings and configure vaults in the Web UI, or set MARGINALIA_VAULT explicitly"
    fi
  done
}

validate_preseed_inputs

open_application_ui() {
  local url="$1"
  case "$(uname -s 2>/dev/null || true)" in
    Darwin)
      command -v open >/dev/null 2>&1 || return 1
      open "${url}" >/dev/null 2>&1
      ;;
    MINGW*|MSYS*|CYGWIN*)
      command -v cmd.exe >/dev/null 2>&1 || return 1
      cmd.exe /c start "" "${url}" >/dev/null 2>&1
      ;;
    *)
      command -v xdg-open >/dev/null 2>&1 || return 1
      xdg-open "${url}" >/dev/null 2>&1
      ;;
  esac
}

require_expected_wheel_version() {
  [ -n "${1:-}" ] \
    || die "wheel verification requires a manifest version or MARGINALIA_EXPECTED_VERSION"
}

read_server_pid() {
  local pid_file="$1"
  [ -f "${pid_file}" ] || return 0
  "${VERIFY_PYTHON}" -c '
import json, sys
with open(sys.argv[1], "rb") as handle:
    raw = handle.read(16385)
if len(raw) > 16384:
    raise SystemExit(0)
text = raw.decode("utf-8").strip()
try:
    payload = json.loads(text)
except (TypeError, ValueError):
    payload = None
value = payload.get("pid", "") if isinstance(payload, dict) else (text.splitlines()[0] if text else "")
try:
    pid = int(value)
except (TypeError, ValueError):
    pid = 0
if pid > 0:
    print(pid)
' "${pid_file}" 2>/dev/null || true
}

find_daemon_lock_root() {
  local target_pid="$1" recorded_pid=""
  [ -f "${DAEMON_PID_FILE}" ] || return 1
  recorded_pid="$(read_server_pid "${DAEMON_PID_FILE}")"
  if [ "${recorded_pid}" = "${target_pid}" ]; then
    printf '%s' "${DAEMON_RUNTIME_ROOT}"
    return 0
  fi
  return 1
}

claude_mcp_registration_matches() {
  local output="$1" expected_url="$2"
  printf '%s\n' "${output}" | awk '
    $1 == "Scope:" { scope += 1 }
    $1 == "Status:" { status += 1 }
    $1 == "Type:" { type += 1 }
    $1 == "URL:" { url += 1 }
    END { exit(scope == 1 && status == 1 && type == 1 && url == 1 ? 0 : 1) }
  ' || return 1
  printf '%s\n' "${output}" | grep -Eq \
    '^[[:space:]]*Scope:[[:space:]]*User config([[:space:]]+\([^()]*\))?[[:space:]]*$' \
    || return 1
  printf '%s\n' "${output}" | grep -Eq \
    '^[[:space:]]*Status:[[:space:]]*([^[:alnum:]][[:space:]]*)?Connected[[:space:]]*$' \
    || return 1
  printf '%s\n' "${output}" | grep -Eq \
    '^[[:space:]]*Type:[[:space:]]*http[[:space:]]*$' || return 1
  printf '%s\n' "${output}" | awk -v expected="${expected_url}" '
    $1 == "URL:" && $2 == expected && NF == 2 { found = 1 }
    END { exit(found ? 0 : 1) }
  '
}

claude_mcp_registration_scope() {
  local output="$1"
  if printf '%s\n' "${output}" | grep -Eq \
      '^[[:space:]]*Scope:[[:space:]]*Local config([[:space:]]+\([^()]*\))?[[:space:]]*$'; then
    printf 'local'
  elif printf '%s\n' "${output}" | grep -Eq \
      '^[[:space:]]*Scope:[[:space:]]*Project config([[:space:]]+\([^()]*\))?[[:space:]]*$'; then
    printf 'project'
  elif printf '%s\n' "${output}" | grep -Eq \
      '^[[:space:]]*Scope:[[:space:]]*User config([[:space:]]+\([^()]*\))?[[:space:]]*$'; then
    printf 'user'
  else
    printf 'unknown'
  fi
}

daemon_version() {
  local cli="$1" vault="${2:-}" payload="" version=""
  local status_command=("${cli}" status --json --timeout 2)
  [ -n "${vault}" ] && status_command+=(--vault "${vault}")
  payload="$("${status_command[@]}" 2>/dev/null || true)"
  version="$(printf '%s' "${payload}" | "${VERIFY_PYTHON}" -c \
    'import json,sys; print(json.load(sys.stdin).get("marginalia_version", ""))' \
    2>/dev/null || true)"
  if [ -z "${version}" ]; then
    payload="$(curl -fsS --max-time 2 "${REST_URL}/version" 2>/dev/null || true)"
    version="$(printf '%s' "${payload}" | "${VERIFY_PYTHON}" -c \
      'import json,sys; print(json.load(sys.stdin).get("marginalia_version", ""))' \
      2>/dev/null || true)"
  fi
  [ -n "${version}" ] || return 1
  printf '%s' "${version}"
}

restart_previous_daemon() {
  [ -n "${WAS_RUNNING}" ] || return 0

  # Before activation the old PID may still own the daemon. Never launch a
  # duplicate; the unchanged prior process already preserves running state.
  if [ -z "${ACTIVATION_STARTED}" ] && [ -n "${OLD_PID:-}" ] \
     && kill -0 "${OLD_PID}" 2>/dev/null; then
    info "previous Marginalia daemon remains running (pid ${OLD_PID})"
    SHUTDOWN_REQUESTED=""
    return 0
  fi

  local restart_command="${TOOL_BIN}/marginalia"
  [ -x "${restart_command}" ] || restart_command="${PREVIOUS_COMMAND}"
  if [ -z "${restart_command}" ] || [ ! -x "${restart_command}" ]; then
    warn "previous daemon was running but its command could not be restored"
    return 1
  fi
  local restart_args=(serve --daemon)
  # ADR-0034 daemons open the browser by default and support --no-open. The
  # immutable 0.0.40 predecessor lacks that option and never auto-opened.
  if "${restart_command}" serve --help 2>/dev/null | grep -q -- '--no-open'; then
    restart_args+=(--no-open)
  fi
  if [ -n "${PREVIOUS_DAEMON_VAULT}" ]; then
    restart_args+=(--vault "${PREVIOUS_DAEMON_VAULT}")
  fi
  if ! "${restart_command}" "${restart_args[@]}" >/dev/null 2>&1; then
    warn "previous tool is available but its daemon could not be restarted"
    return 1
  fi

  local running_version=""
  for _ in $(seq 1 30); do
    running_version="$(daemon_version "${restart_command}" "${PREVIOUS_DAEMON_VAULT}" || true)"
    [ -n "${running_version}" ] && break
    sleep 1
  done
  if [ -z "${running_version}" ] \
     || { [ -n "${PREVIOUS_VERSION}" ] && [ "${running_version}" != "${PREVIOUS_VERSION}" ]; }; then
    warn "previous daemon restart could not be verified"
    return 1
  fi
  SHUTDOWN_REQUESTED=""
  info "restored and restarted Marginalia ${PREVIOUS_VERSION:-previous version}"
}

stop_candidate_daemon() {
  [ -n "${CANDIDATE_DAEMON_STARTED}" ] || return 0
  local candidate_pid=""
  candidate_pid="$(read_server_pid "${DAEMON_PID_FILE}")"
  if [ -x "${TOOL_BIN}/marginalia" ]; then
    "${TOOL_BIN}/marginalia" stop --timeout 10 \
      >/dev/null 2>&1 || true
  fi
  if { [ -n "${candidate_pid}" ] && kill -0 "${candidate_pid}" 2>/dev/null; } \
     || port_in_use || mcp_port_in_use; then
    warn "candidate daemon is still live; refusing to remove its environment"
    return 1
  fi
}

restore_previous_tool() {
  [ -n "${ACTIVATION_STARTED}" ] || return 0
  warn "activation failed; restoring the previous Marginalia tool"

  stop_candidate_daemon || return 1

  if [ -n "${TOOL_ROOT}" ] && [ "${TOOL_ROOT}" != "/" ]; then
    rm -rf "${TOOL_ROOT}/marginalia" || return 1
  fi
  if [ -n "${TOOL_BIN}" ] && [ "${TOOL_BIN}" != "/" ]; then
    rm -f "${TOOL_BIN}/marginalia" "${TOOL_BIN}/kg" || return 1
  fi
  if [ -n "${BACKUP_ROOT}" ] && [ -d "${BACKUP_ROOT}/tool" ]; then
    mv "${BACKUP_ROOT}/tool" "${TOOL_ROOT}/marginalia" || return 1
  elif [ -n "${PREVIOUS_VERSION}" ]; then
    warn "previous tool backup is missing at ${BACKUP_ROOT}/tool"
    return 1
  fi
  if [ -n "${BACKUP_ROOT}" ] && [ -d "${BACKUP_ROOT}/bin" ]; then
    for launcher in marginalia kg; do
      if [ -e "${BACKUP_ROOT}/bin/${launcher}" ] || [ -L "${BACKUP_ROOT}/bin/${launcher}" ]; then
        mv "${BACKUP_ROOT}/bin/${launcher}" "${TOOL_BIN}/${launcher}" || return 1
      fi
    done
  fi

  local restored=""
  if [ -x "${TOOL_ROOT}/marginalia/bin/python" ]; then
    restored="$("${TOOL_ROOT}/marginalia/bin/python" -c \
      'import importlib.metadata; print(importlib.metadata.version("marginalia"))' \
      2>/dev/null || true)"
  fi
  if [ -n "${PREVIOUS_VERSION}" ] && [ "${restored}" != "${PREVIOUS_VERSION}" ]; then
    warn "previous tool restoration could not be verified (expected ${PREVIOUS_VERSION}, got ${restored:-missing})"
    return 1
  fi

  if [ -n "${WAS_RUNNING}" ]; then
    restart_previous_daemon || return 1
  else
    info "restored Marginalia ${PREVIOUS_VERSION:-previous version}; daemon remains stopped"
  fi
  ACTIVATION_STARTED=""
}

installer_exit() {
  local rc=$?
  local retain_backup=""
  trap - EXIT
  if [ -n "${ACTIVATION_STARTED}" ] && [ -z "${ACTIVATION_COMMITTED}" ]; then
    if ! restore_previous_tool; then
      rc=1
      retain_backup="1"
    fi
  elif [ -n "${SHUTDOWN_REQUESTED}" ]; then
    restart_previous_daemon || rc=1
  fi
  if [ -n "${BACKUP_ROOT}" ]; then
    if [ -n "${retain_backup}" ]; then
      warn "rollback is incomplete; recovery backup retained at ${BACKUP_ROOT}"
    else
      rm -rf "${BACKUP_ROOT}"
    fi
  fi
  [ -n "${WORK_TMP}" ] && rm -rf "${WORK_TMP}"
  [ -n "${CLONE_TMP}" ] && rm -rf "${CLONE_TMP}"
  exit "${rc}"
}
trap installer_exit EXIT

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

# A prior uv tool can exist even when this shell has not loaded uv's PATH
# update yet. Make it reachable before update detection needs to stop it.
PREINSTALL_TOOL_BIN="$(uv tool dir --bin 2>/dev/null || true)"
[ -n "${PREINSTALL_TOOL_BIN}" ] && export PATH="${PREINSTALL_TOOL_BIN}:${PATH}"
TOOL_ROOT="$(uv tool dir 2>/dev/null || true)"
TOOL_BIN="${PREINSTALL_TOOL_BIN:-${HOME}/.local/bin}"
WORK_TMP="$(mktemp -d)"

step "Ensuring Python ${PY_VERSION} (uv-managed; no system Python touched)"
uv python install "${PY_VERSION}" >/dev/null 2>&1 || true
VERIFY_PYTHON="$(uv python find "${PY_VERSION}" 2>/dev/null || true)"
[ -x "${VERIFY_PYTHON}" ] || die "uv could not resolve Python ${PY_VERSION} for release verification"

# ── 2. obtain the source / wheel ──────────────────────────────────────────
fetch_file() {
  local source="$1" destination="$2"
  case "${source}" in
    http://*|https://*) curl -fsSL "${source}" -o "${destination}" ;;
    file://*) cp "${source#file://}" "${destination}" ;;
    *) cp "${source}" "${destination}" ;;
  esac
}

manifest_value() {
  "${VERIFY_PYTHON}" -c \
    'import json,sys; value=json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2], ""); print(value)' \
    "$1" "$2"
}

step "Resolving and staging the Marginalia candidate"
SPEC=""
CANDIDATE_KIND=""
WHEEL_SOURCE=""
SOURCE_PATH=""
if [ -n "${MARGINALIA_WHEEL:-}" ]; then
  CANDIDATE_KIND="wheel"
  WHEEL_SOURCE="${MARGINALIA_WHEEL}"
  info "using wheel: ${WHEEL_SOURCE}"
elif [ -n "${MARGINALIA_SRC:-}" ]; then
  [ -f "${MARGINALIA_SRC}/pyproject.toml" ] \
    || die "MARGINALIA_SRC has no pyproject.toml: ${MARGINALIA_SRC}"
  CANDIDATE_KIND="source"
  SOURCE_PATH="${MARGINALIA_SRC}"
  info "using checkout: ${SOURCE_PATH}"
else
  if ! SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"; then
    SELF_DIR=""
  fi
  if [ -n "${SELF_DIR}" ] && [ -f "${SELF_DIR}/../pyproject.toml" ] \
     && grep -q '^name = "marginalia"' "${SELF_DIR}/../pyproject.toml" 2>/dev/null; then
    CANDIDATE_KIND="source"
    SOURCE_PATH="$(cd "${SELF_DIR}/.." && pwd)"
    info "running from a clone: ${SOURCE_PATH}"
  elif [ -n "${DEFAULT_WHEEL_URL}" ]; then
    CANDIDATE_KIND="wheel"
    WHEEL_SOURCE="${DEFAULT_WHEEL_URL}"
    info "using release wheel: ${WHEEL_SOURCE}"
  else
    command -v git >/dev/null 2>&1 \
      || die "git not found; install git or set MARGINALIA_SRC / MARGINALIA_WHEEL."
    CLONE_TMP="${WORK_TMP}/source"
    info "cloning ${REPO} ..."
    git clone --depth 1 ${REF:+--branch "$REF"} "${REPO}" "${CLONE_TMP}" \
      || die "clone failed. Private repo? Set up SSH access, or pass MARGINALIA_SRC=<path> / MARGINALIA_WHEEL=<url>."
    CANDIDATE_KIND="source"
    SOURCE_PATH="${CLONE_TMP}"
  fi
fi

if [ "${CANDIDATE_KIND}" = "wheel" ]; then
  MANIFEST_SOURCE="${MARGINALIA_MANIFEST:-}"
  if [ -z "${MANIFEST_SOURCE}" ] && [ "${WHEEL_SOURCE}" = "${DEFAULT_WHEEL_URL}" ]; then
    MANIFEST_SOURCE="${DEFAULT_MANIFEST_URL}"
  fi
  MANIFEST_SHA=""
  MANIFEST_WHEEL=""
  if [ -n "${MANIFEST_SOURCE}" ]; then
    MANIFEST_FILE="${WORK_TMP}/release-manifest.json"
    fetch_file "${MANIFEST_SOURCE}" "${MANIFEST_FILE}" \
      || die "could not load release manifest: ${MANIFEST_SOURCE}"
    MANIFEST_VERSION="$(manifest_value "${MANIFEST_FILE}" version)"
    MANIFEST_URL="$(manifest_value "${MANIFEST_FILE}" wheel_url)"
    MANIFEST_SHA="$(manifest_value "${MANIFEST_FILE}" sha256)"
    MANIFEST_WHEEL="$(manifest_value "${MANIFEST_FILE}" wheel)"
    if [ -z "${MANIFEST_VERSION}" ] || [ -z "${MANIFEST_URL}" ] \
      || [ -z "${MANIFEST_SHA}" ] || [ -z "${MANIFEST_WHEEL}" ]; then
      die "release manifest is missing version, wheel_url, wheel, or sha256"
    fi
    [ "$(basename "${MANIFEST_WHEEL}")" = "${MANIFEST_WHEEL}" ] \
      || die "release manifest wheel must be a filename, not a path"
    if [ -n "${EXPECTED_VERSION}" ] && [ "${EXPECTED_VERSION}" != "${MANIFEST_VERSION}" ]; then
      die "release manifest version ${MANIFEST_VERSION} does not match expected ${EXPECTED_VERSION}"
    fi
    EXPECTED_VERSION="${MANIFEST_VERSION}"
    case "${WHEEL_SOURCE}" in
      http://*|https://*)
        [ "${WHEEL_SOURCE}" = "${MANIFEST_URL}" ] \
          || die "wheel URL does not match release manifest"
        ;;
      *)
        [ "$(basename "${WHEEL_SOURCE}")" = "${MANIFEST_WHEEL}" ] \
          || die "wheel filename does not match release manifest"
        ;;
    esac
  fi

  require_expected_wheel_version "${EXPECTED_VERSION}"

  EXPECTED_SHA="${MARGINALIA_WHEEL_SHA256:-${MANIFEST_SHA}}"
  [ -n "${EXPECTED_SHA}" ] \
    || die "wheel verification requires MARGINALIA_MANIFEST or MARGINALIA_WHEEL_SHA256"
  if [ -n "${MANIFEST_SHA}" ] && [ -n "${MARGINALIA_WHEEL_SHA256:-}" ] \
     && [ "${MARGINALIA_WHEEL_SHA256}" != "${MANIFEST_SHA}" ]; then
    die "MARGINALIA_WHEEL_SHA256 does not match the release manifest"
  fi
  case "${EXPECTED_SHA}" in
    *[!0-9a-fA-F]*|'') die "wheel SHA-256 must be 64 hexadecimal characters" ;;
  esac
  [ "${#EXPECTED_SHA}" -eq 64 ] || die "wheel SHA-256 must be 64 hexadecimal characters"

  WHEEL_NAME="${MANIFEST_WHEEL:-$(basename "${WHEEL_SOURCE%%\?*}")}"
  case "${WHEEL_NAME}" in *.whl) ;; *) die "wheel filename must end in .whl" ;; esac
  CANDIDATE_WHEEL="${WORK_TMP}/${WHEEL_NAME}"
  fetch_file "${WHEEL_SOURCE}" "${CANDIDATE_WHEEL}" \
    || die "could not download wheel: ${WHEEL_SOURCE}"
  ACTUAL_SHA="$("${VERIFY_PYTHON}" -c \
    'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' \
    "${CANDIDATE_WHEEL}")"
  [ "$(printf '%s' "${ACTUAL_SHA}" | tr '[:upper:]' '[:lower:]')" = \
    "$(printf '%s' "${EXPECTED_SHA}" | tr '[:upper:]' '[:lower:]')" ] \
    || die "wheel SHA-256 mismatch; expected ${EXPECTED_SHA}, got ${ACTUAL_SHA}"
  info "verified wheel SHA-256: ${ACTUAL_SHA}"
  SPEC="${CANDIDATE_WHEEL}[${EXTRAS}]"
else
  SPEC="${SOURCE_PATH}[${EXTRAS}]"
fi

# Resolve/build/install the candidate in a throwaway venv while the current
# daemon and uv tool remain untouched. Activation only begins after this passes.
STAGE_VENV="${WORK_TMP}/stage"
uv venv --python "${PY_VERSION}" "${STAGE_VENV}" >/dev/null
STAGE_PYTHON="${STAGE_VENV}/bin/python"
STAGE_CLI="${STAGE_VENV}/bin/marginalia"
uv pip install --python "${STAGE_PYTHON}" "${SPEC}"
CANDIDATE_VERSION="$("${STAGE_PYTHON}" -c \
  'import importlib.metadata; print(importlib.metadata.version("marginalia"))')"
if [ -n "${EXPECTED_VERSION}" ] && [ "${CANDIDATE_VERSION}" != "${EXPECTED_VERSION}" ]; then
  die "staged Marginalia ${CANDIDATE_VERSION}, expected ${EXPECTED_VERSION}"
fi
EXPECTED_VERSION="${CANDIDATE_VERSION}"
[ -x "${STAGE_CLI}" ] || die "staged wheel did not install the marginalia command"
"${STAGE_CLI}" --help >/dev/null
STAGED_CLI_VERSION="$("${STAGE_CLI}" --version 2>/dev/null || true)"
if [ -n "${STAGED_CLI_VERSION}" ] \
   && [ "${STAGED_CLI_VERSION}" != "marginalia ${CANDIDATE_VERSION}" ]; then
  die "staged CLI does not match package version ${CANDIDATE_VERSION}"
fi
info "staged Marginalia ${CANDIDATE_VERSION}; active installation is still untouched"

# ── 2b. app-scoped update discovery ──────────────────────────────────
# Replacing the installed package under a LIVE daemon leaves it serving stale
# file handles. Lifecycle ownership and status are application-scoped; selecting
# a vault is independent of starting, stopping, or updating the daemon.
json_value() {
  printf '%s' "$1" | "${VERIFY_PYTHON}" -c \
    'import json,sys; value=json.load(sys.stdin).get(sys.argv[1], ""); print(value if value is not None else "")' \
    "$2" 2>/dev/null || true
}

port_in_use() {
  (: >/dev/tcp/127.0.0.1/7777) >/dev/null 2>&1
}

mcp_port_in_use() {
  (: >/dev/tcp/127.0.0.1/8201) >/dev/null 2>&1
}

discover_daemon_status() {
  local payload=""
  if [ -n "${PREVIOUS_COMMAND}" ] && [ -x "${PREVIOUS_COMMAND}" ]; then
    payload="$("${PREVIOUS_COMMAND}" status --json --timeout 2 2>/dev/null || true)"
    if [ -n "${payload}" ] && [ -n "$(json_value "${payload}" pid)" ]; then
      printf '%s' "${payload}"
      return 0
    fi
  fi
  payload="$(curl -fsS --max-time 2 "${REST_URL}/api/v1/status" 2>/dev/null || true)"
  if [ -n "${payload}" ] && [ -n "$(json_value "${payload}" pid)" ]; then
    printf '%s' "${payload}"
  fi
  return 0
}

legacy_vault_paths() {
  local payload="" config=""
  if [ -n "${PREVIOUS_COMMAND}" ] && [ -x "${PREVIOUS_COMMAND}" ]; then
    payload="$("${PREVIOUS_COMMAND}" vault list --json 2>/dev/null || true)"
  fi
  if [ -n "${payload}" ]; then
    printf '%s' "${payload}" | "${VERIFY_PYTHON}" -c '
import json, sys
try:
    payload = json.load(sys.stdin)
except (TypeError, ValueError):
    raise SystemExit(0)
for row in payload.get("vaults", []):
    path = row.get("path") if isinstance(row, dict) else None
    if isinstance(path, str) and path and "\n" not in path and "\r" not in path:
        print(path)
' 2>/dev/null || true
  fi
  for config in "${HOME_ROOT}"/vaults/*/marginalia.yaml; do
    [ -f "${config}" ] || continue
    dirname "${config}"
  done
}

find_unverified_live_legacy_daemon() {
  local vault="" pid=""
  while IFS= read -r vault; do
    [ -n "${vault}" ] || continue
    pid="$(read_server_pid "${vault}/.marginalia/server.pid")"
    case "${pid}" in ''|*[!0-9]*) continue ;; esac
    if kill -0 "${pid}" 2>/dev/null; then
      "${VERIFY_PYTHON}" -c \
        'import json,sys; print(json.dumps({"pid": int(sys.argv[1]), "vault": sys.argv[2]}))' \
        "${pid}" "${vault}"
      return 0
    fi
  done < <(legacy_vault_paths | sort -u)
}

find_verified_legacy_lock_root() {
  local target_pid="$1" vault="$2" recorded_pid=""
  [ -n "${vault}" ] && [ -f "${vault}/marginalia.yaml" ] || return 1
  recorded_pid="$(read_server_pid "${vault}/.marginalia/server.pid")"
  [ "${recorded_pid}" = "${target_pid}" ] || return 1
  printf '%s' "${vault}"
}

find_unverified_live_daemon() {
  local pid=""
  [ -f "${DAEMON_PID_FILE}" ] || return 0
  pid="$(read_server_pid "${DAEMON_PID_FILE}")"
  case "${pid}" in ''|*[!0-9]*) return 0 ;; esac
  if kill -0 "${pid}" 2>/dev/null; then
    "${VERIFY_PYTHON}" -c \
      'import json,sys; print(json.dumps({"pid": int(sys.argv[1])}))' "${pid}"
  fi
}

UPGRADE=""
OLD_PID=""
PREVIOUS_COMMAND="$(command -v marginalia 2>/dev/null || true)"
if [ -x "${TOOL_ROOT}/marginalia/bin/python" ]; then
  PREVIOUS_VERSION="$("${TOOL_ROOT}/marginalia/bin/python" -c \
    'import importlib.metadata; print(importlib.metadata.version("marginalia"))' \
    2>/dev/null || true)"
fi
STATUS_JSON="$(discover_daemon_status)"
if [ -z "${STATUS_JSON}" ]; then
  UNVERIFIED_DAEMON="$(find_unverified_live_daemon)"
  if [ -n "${UNVERIFIED_DAEMON}" ]; then
    UNVERIFIED_PID="$(json_value "${UNVERIFIED_DAEMON}" pid)"
      die "live Marginalia daemon (pid ${UNVERIFIED_PID}) has an application PID record at ${DAEMON_PID_FILE}, but status at ${REST_URL} is unavailable; update aborted before replacing the installed tool. Stop it first: marginalia stop. If it uses custom ports, stop it manually and rerun."
  fi
  if [ "${PREVIOUS_VERSION}" = "0.0.40" ]; then
    UNVERIFIED_LEGACY_DAEMON="$(find_unverified_live_legacy_daemon)"
    if [ -n "${UNVERIFIED_LEGACY_DAEMON}" ]; then
      UNVERIFIED_PID="$(json_value "${UNVERIFIED_LEGACY_DAEMON}" pid)"
      UNVERIFIED_VAULT="$(json_value "${UNVERIFIED_LEGACY_DAEMON}" vault)"
      die "live Marginalia 0.0.40 daemon (pid ${UNVERIFIED_PID}) has a vault-scoped PID record at ${UNVERIFIED_VAULT}/.marginalia/server.pid, but verified status at ${REST_URL} is unavailable; update aborted before replacing the installed tool. Stop it first: marginalia stop --vault \"${UNVERIFIED_VAULT}\", then rerun the installer."
    fi
  fi
fi
if [ -n "${STATUS_JSON}" ]; then
  UPGRADE="1"
  WAS_RUNNING="1"
  OLD_PID="$(json_value "${STATUS_JSON}" pid)"
  STATUS_ENDPOINT="$(json_value "${STATUS_JSON}" endpoint)"
  STATUS_VERSION="$(json_value "${STATUS_JSON}" marginalia_version)"
  OLD_LOCK_ROOT="$(find_daemon_lock_root "${OLD_PID}" || true)"
  if [ -z "${OLD_LOCK_ROOT}" ]; then
    STATUS_VAULT="$(json_value "${STATUS_JSON}" vault_path)"
    if [ "${PREVIOUS_VERSION}" != "0.0.40" ] \
      || [ "${STATUS_VERSION}" != "0.0.40" ]; then
      die "Marginalia status reported pid ${OLD_PID}, but its application lifecycle lock could not be verified; update aborted before shutdown"
    fi
    OLD_LOCK_ROOT="$(find_verified_legacy_lock_root "${OLD_PID}" "${STATUS_VAULT}" || true)"
    [ -n "${OLD_LOCK_ROOT}" ] \
      || die "Marginalia 0.0.40 status reported pid ${OLD_PID} and vault ${STATUS_VAULT:-unknown}, but the matching vault-scoped lifecycle lock could not be verified; update aborted before shutdown"
    LEGACY_DAEMON="1"
    PREVIOUS_DAEMON_VAULT="${STATUS_VAULT}"
  fi
  case "${STATUS_ENDPOINT%/}" in
    ""|"${REST_URL}"|"http://localhost:7777") ;;
    *)
      if [ -n "${LEGACY_DAEMON}" ]; then
        die "live Marginalia 0.0.40 daemon uses custom endpoint ${STATUS_ENDPOINT}; update aborted before shutdown because the installer cannot preserve custom ports automatically. Stop it first: marginalia stop --vault \"${PREVIOUS_DAEMON_VAULT}\""
      fi
      die "live Marginalia daemon uses custom endpoint ${STATUS_ENDPOINT}; update aborted before shutdown because the installer cannot preserve custom ports automatically. Stop it first: marginalia stop"
      ;;
  esac
  step "Existing Marginalia daemon detected — updating in place"
  [ -n "${PREVIOUS_COMMAND}" ] \
    || die "daemon is running but its installed marginalia command was not found"
  # From this point every exit path must leave the unchanged prior daemon
  # running until activation has a restorable tool backup.
  SHUTDOWN_REQUESTED="1"
  if [ -n "${LEGACY_DAEMON}" ]; then
    STOP_COMMAND=("${STAGE_CLI}" stop --vault "${PREVIOUS_DAEMON_VAULT}" --timeout 30)
  else
    STOP_COMMAND=("${STAGE_CLI}" stop --timeout 30)
  fi
  if ! "${STOP_COMMAND[@]}"; then
    die "could not stop the verified daemon (pid ${OLD_PID}); update aborted before replacing the installed tool"
  fi

  # Never replace files under a process that is still draining.
  for _ in $(seq 1 10); do
    if [ -n "${OLD_PID}" ] && kill -0 "${OLD_PID}" 2>/dev/null; then sleep 1; continue; fi
    port_in_use && { sleep 1; continue; }
    break
  done
  if { [ -n "${OLD_PID}" ] && kill -0 "${OLD_PID}" 2>/dev/null; } \
     || port_in_use; then
    die "old daemon${OLD_PID:+ (pid ${OLD_PID})} still owns its process or port after a successful stop; update aborted before replacing the installed tool"
  fi
  info "stopped the running daemon — it will restart on the new version below"
elif port_in_use; then
  die "port 7777 is in use but verified Marginalia status is unavailable; update aborted"
elif [ -x "${TOOL_ROOT}/marginalia/bin/python" ] \
  || ls "${HOME_ROOT}/vaults"/*/marginalia.yaml >/dev/null 2>&1; then
  # Daemon isn't up (crashed, machine rebooted, whatever) but this machine was
  # already set up before — a re-run should update in place, not treat this
  # as a fresh install and re-run vault-create/onboard against existing state.
  UPGRADE="1"
  step "Existing Marginalia install detected (daemon not running) — updating in place"
fi

# ── 3. install the global tool ────────────────────────────────────────────
step "Activating staged Marginalia ${CANDIDATE_VERSION}"
PREVIOUS_COMMAND="${PREVIOUS_COMMAND:-$(command -v marginalia 2>/dev/null || true)}"
if [ -z "${PREVIOUS_VERSION}" ] && [ -x "${TOOL_ROOT}/marginalia/bin/python" ]; then
  PREVIOUS_VERSION="$("${TOOL_ROOT}/marginalia/bin/python" -c \
    'import importlib.metadata; print(importlib.metadata.version("marginalia"))' \
    2>/dev/null || true)"
fi

# Rename the prior environment and launchers on the same filesystem. This
# preserves the exact dependency set and uv receipt for a lossless rollback.
BACKUP_ROOT="${TOOL_ROOT}/.marginalia-installer-backup-$$"
mkdir -p "${BACKUP_ROOT}/bin"
ACTIVATION_STARTED="1"
if [ -d "${TOOL_ROOT}/marginalia" ]; then
  mv "${TOOL_ROOT}/marginalia" "${BACKUP_ROOT}/tool"
fi
for launcher in marginalia kg; do
  if [ -e "${TOOL_BIN}/${launcher}" ] || [ -L "${TOOL_BIN}/${launcher}" ]; then
    mv "${TOOL_BIN}/${launcher}" "${BACKUP_ROOT}/bin/${launcher}"
  fi
done

if ! uv tool install --python "${PY_VERSION}" "${SPEC}"; then
  die "candidate activation failed"
fi
export PATH="${TOOL_BIN}:${PATH}"
# Best-effort: persist PATH into the user's shell rc so a NEW shell (next
# terminal, next `curl | bash` re-run) finds marginalia without manual setup.
# Opt out for sandboxed/test runs that must not touch real shell rc files.
if [ "${MARGINALIA_NO_UPDATE_SHELL:-}" != "1" ]; then
  uv tool update-shell >/dev/null 2>&1 || warn "run 'uv tool update-shell' to persist PATH"
fi
command -v marginalia >/dev/null 2>&1 \
  || die "marginalia installed but not found in ${TOOL_BIN}. Run 'uv tool update-shell', restart your shell, re-run."
info "marginalia: $(command -v marginalia)"
TOOL_PYTHON="${TOOL_ROOT}/marginalia/bin/python"
[ -x "${TOOL_PYTHON}" ] || die "could not locate Marginalia's uv-managed Python at ${TOOL_PYTHON}"
INSTALLED_VERSION="$("${TOOL_PYTHON}" -c 'import importlib.metadata; print(importlib.metadata.version("marginalia"))')"
if [ "${INSTALLED_VERSION}" != "${CANDIDATE_VERSION}" ]; then
  die "installed Marginalia ${INSTALLED_VERSION}, expected staged ${CANDIDATE_VERSION}"
fi
CLI_VERSION="$(marginalia --version 2>/dev/null || true)"
if [ -n "${CLI_VERSION}" ] && [ "${CLI_VERSION}" != "marginalia ${INSTALLED_VERSION}" ]; then
  die "the installed marginalia command does not match package version ${INSTALLED_VERSION}"
fi
info "version: ${INSTALLED_VERSION}"

if [ -n "${UPGRADE}" ]; then
  # Update path: the machine is already set up — don't create vaults, don't
  # touch the default, and don't re-prompt for an LLM.
  step "Update mode — leaving your vaults, default, and LLM config untouched"
elif [ -z "${VAULT}" ]; then
  step "Application-first setup"
  info "no vault preseed requested; create, select, and configure vaults in the Web UI"
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

# ── 5. LLM provider (marginalia onboard; ask + remember need one) ──────────
# Provider-first setup is delegated to `marginalia onboard`: it selects the vault
# we just created, walks the provider menu (auto-detect · skip · LM Studio ·
# Ollama · LiteLLM Proxy · OpenRouter · OpenAI · Gemini · Anthropic · custom),
# stores any API key in ~/.marginalia/env (never in marginalia.yaml), and writes
# the llm: block. Keys stay out of config and non-loopback endpoints are opt-in.
step "Configuring the LLM provider via 'marginalia onboard'"
ONBOARD=(marginalia onboard --vault "${VAULT}")
NONINTERACTIVE=""
if [ "${MARGINALIA_ONBOARD_NONINTERACTIVE:-}" = "1" ]; then
  NONINTERACTIVE="1"
elif ! (exec < /dev/tty) 2>/dev/null; then
  NONINTERACTIVE="1"
fi
if [ -n "${MARGINALIA_LLM_PROVIDER:-}" ]; then
  ONBOARD+=(--provider "${MARGINALIA_LLM_PROVIDER}")
elif [ -n "${MARGINALIA_LLM_API_BASE:-}" ] || [ -n "${MARGINALIA_LLM_MODEL:-}" ]; then
  ONBOARD+=(--provider custom)
elif [ -n "${NONINTERACTIVE}" ]; then
  ONBOARD+=(--provider skip)
fi
[ -n "${MARGINALIA_LLM_API_BASE:-}" ] \
  && ONBOARD+=(--api-base "${MARGINALIA_LLM_API_BASE}")
[ -n "${MARGINALIA_LLM_MODEL:-}" ] \
  && ONBOARD+=(--model "${MARGINALIA_LLM_MODEL}" --skip-model-discovery)
[ "${MARGINALIA_LLM_SKIP_DISCOVERY:-}" = "1" ] \
  && [ -z "${MARGINALIA_LLM_MODEL:-}" ] && ONBOARD+=(--skip-model-discovery)
[ -n "${MARGINALIA_LLM_API_KEY_ENV:-}" ] \
  && ONBOARD+=(--api-key-env "${MARGINALIA_LLM_API_KEY_ENV}")
if [ "${MARGINALIA_LLM_ALLOW_REMOTE:-${MARGINALIA_ALLOW_REMOTE_LLM:-}}" = "1" ]; then
  ONBOARD+=(--allow-remote-llm --yes)
fi
if [ -n "${NONINTERACTIVE}" ]; then
  ONBOARD+=(--non-interactive)
  info "using noninteractive onboarding"
  "${ONBOARD[@]}"
else
  # Interactive, including `curl … | bash` where stdin is the piped script:
  # drive onboard's provider-first prompts from the real terminal.
  info "choose a provider (or pick Skip — explore() works without an LLM)."
  "${ONBOARD[@]}" < /dev/tty
fi
fi  # end update / application-first / explicit-preseed setup

server_version() {
  local cli="$1" payload="" version=""
  payload="$("${cli}" status --json --timeout 2 2>/dev/null || true)"
  version="$(json_value "${payload}" marginalia_version)"
  if [ -z "${version}" ]; then
    payload="$(curl -fsS --max-time 2 "${REST_URL}/version" 2>/dev/null || true)"
    version="$(json_value "${payload}" marginalia_version)"
  fi
  [ -n "${version}" ] || return 1
  printf '%s' "${version}"
}

# ── 6. serve ──────────────────────────────────────────────────────────────
# Keep install-only and intentionally stopped updates successful, while treating
# a requested daemon start that does not serve the installed version as failure.
SERVE_OK="1"
SERVER_STARTED=""
DAEMON_LOG="${HOME_ROOT}/logs/marginalia-serve.log"
if [ "${MARGINALIA_NO_SERVE:-}" = "1" ]; then
  step "Skipping daemon start (MARGINALIA_NO_SERVE=1)"
elif [ -n "${UPGRADE}" ] && [ -z "${WAS_RUNNING}" ]; then
  step "Preserving stopped daemon state"
  info "the daemon was stopped before this update, so it remains stopped"
else
  if [ -n "${UPGRADE}" ]; then
    step "Restarting the application daemon on the new version"
  else
    step "Starting the Marginalia daemon (UI/REST :7777 + MCP :8201)"
  fi
  # The installer no longer exports a process-wide placeholder LLM key (forbidden
  # by the distribution rules). The LLM client injects a placeholder api_key for a
  # keyless custom api_base on its own (marginalia/llm __init__), so keyless local
  # LLM serve works. Real keys stay in ~/.marginalia/env under the MARGINALIA_*
  # name onboard recorded. (A keyless *remote* embedding endpoint is not covered
  # here; the default fastembed embedder is local and needs no key.)
  CANDIDATE_DAEMON_STARTED="1"
  SERVE_ARGS=(serve --daemon --no-open)
  # The 0.0.40 daemon credential lives under its verified vault. Give the
  # successor that vault exactly once so its runtime can adopt the credential
  # into application scope without rotating connected MCP clients. Fresh and
  # already application-scoped starts remain vaultless.
  if [ -n "${LEGACY_DAEMON}" ] && [ -n "${PREVIOUS_DAEMON_VAULT}" ]; then
    SERVE_ARGS+=(--vault "${PREVIOUS_DAEMON_VAULT}")
  fi
  if ! marginalia "${SERVE_ARGS[@]}"; then
    SERVE_OK=""
    warn "daemon start command failed"
  else
    info "waiting for server version ${INSTALLED_VERSION} ..."
    SERVER_VERSION=""
    for _ in $(seq 1 60); do
      SERVER_VERSION="$(server_version "${TOOL_BIN}/marginalia" || true)"
      [ "${SERVER_VERSION}" = "${INSTALLED_VERSION}" ] && break
      sleep 1
    done
    if [ "${SERVER_VERSION}" = "${INSTALLED_VERSION}" ]; then
      SERVER_STARTED="1"
      info "server: ${G}ready${X} (${REST_URL}, version ${SERVER_VERSION})"
    else
      SERVE_OK=""
      if [ -n "${SERVER_VERSION}" ]; then
        warn "server reported version ${SERVER_VERSION}; installed version is ${INSTALLED_VERSION}"
      else
        warn "server did not become ready within 60s"
      fi
      warn "try 'marginalia serve --foreground --no-open'"
      warn "daemon log: ${DAEMON_LOG}"
    fi
  fi
  if [ -z "${SERVE_OK}" ] && [ -f "${DAEMON_LOG}" ]; then
    info "last 20 lines of ${DAEMON_LOG}:"
    tail -n 20 "${DAEMON_LOG}" || true
  fi
fi

if [ -z "${SERVE_OK}" ]; then
  die "candidate daemon verification failed; the previous installation will be restored"
fi

# Version and requested daemon-state verification passed. From this point the
# candidate is committed and the backup can be discarded.
ACTIVATION_COMMITTED="1"
SHUTDOWN_REQUESTED=""
rm -rf "${BACKUP_ROOT}"
BACKUP_ROOT=""

# ── 7. wire Claude Code ───────────────────────────────────────────────────
# MCP alone retains the daemon capability-token gate. Register the private token as a
# Bearer header without printing it to installer output.
GLOBAL_URL="${MCP_URL}"
TOKEN_FILE="${DAEMON_TOKEN_FILE}"
AUTH_TOKEN=""
if [ -f "${TOKEN_FILE}" ]; then
  IFS= read -r AUTH_TOKEN < "${TOKEN_FILE}" || true
fi
MCP_WIRED=""
if [ "${MARGINALIA_NO_MCP:-}" = "1" ]; then
  step "Skipping Claude Code wiring (MARGINALIA_NO_MCP=1)"
elif [ -z "${AUTH_TOKEN}" ]; then
  step "Claude Code wiring deferred"
  info "start the daemon, then re-run this installer to register its authenticated MCP endpoint"
elif command -v claude >/dev/null 2>&1; then
  step "Registering the authenticated MCP server with Claude Code (user scope)"
  # Marginalia reuses the application credential across daemon restarts. Preserve an
  # existing user registration instead of deleting a working integration before
  # its replacement is proven. A fresh registration still uses Claude's only
  # documented HTTP-header input surface.
  MCP_GET_OUTPUT=""
  if MCP_GET_OUTPUT="$(claude mcp get marginalia 2>&1)"; then
    if claude_mcp_registration_matches "${MCP_GET_OUTPUT}" "${GLOBAL_URL}"; then
      MCP_WIRED="1"
      info "preserved connected 'marginalia' user-scope registration"
    else
      MCP_SCOPE="$(claude_mcp_registration_scope "${MCP_GET_OUTPUT}")"
      warn "an existing 'marginalia' Claude MCP entry is not the connected user-scope endpoint ${GLOBAL_URL}"
      if [ "${MCP_SCOPE}" = "local" ] || [ "${MCP_SCOPE}" = "project" ]; then
        info "resolve it with: claude mcp remove marginalia --scope ${MCP_SCOPE}"
      else
        info "inspect it with: claude mcp get marginalia"
      fi
      die "Claude MCP registration conflict; resolve the existing entry and re-run this installer"
    fi
  elif claude mcp add --scope user --transport http \
       marginalia "${GLOBAL_URL}" \
       --header "Authorization: Bearer ${AUTH_TOKEN}" >/dev/null 2>&1; then
    MCP_GET_OUTPUT="$(claude mcp get marginalia 2>&1 || true)"
    if ! claude_mcp_registration_matches "${MCP_GET_OUTPUT}" "${GLOBAL_URL}"; then
      die "Claude MCP registration was added but did not verify as a connected user-scope endpoint"
    fi
    MCP_WIRED="1"
    info "registered and verified the app-scoped 'marginalia' MCP endpoint"
  else
    warn "automatic Claude Code registration failed"
  fi
else
  step "Claude Code CLI not found"
  info "install Claude Code, then re-run this installer to register Marginalia"
fi

# The daemon itself stays headless while the installer proves the exact version.
# Only the committed, verified application is allowed to launch a browser.
if [ -n "${SERVER_STARTED}" ] && [ "${MARGINALIA_NO_OPEN:-}" != "1" ]; then
  step "Opening the verified Marginalia application"
  if open_application_ui "${REST_URL}/"; then
    info "opened ${REST_URL}/"
  else
    warn "browser launch is unavailable; open ${REST_URL}/"
  fi
fi

# ── done ──────────────────────────────────────────────────────────────────
if [ -z "${SERVE_OK}" ]; then
  printf "\n%sMarginalia %s installed, but the daemon did not start correctly.%s\n" \
    "$Y" "${INSTALLED_VERSION}" "$X"
  info "start manually: marginalia serve --foreground"
  info "log      : ${DAEMON_LOG}"
  exit 1
fi

if [ -n "${UPGRADE}" ]; then
  if [ -n "${SERVER_STARTED}" ]; then
    printf "\n%sMarginalia %s updated and restarted.%s\n" "$B$G" "${INSTALLED_VERSION}" "$X"
  else
    printf "\n%sMarginalia %s updated; daemon remains stopped.%s\n" "$B$G" "${INSTALLED_VERSION}" "$X"
  fi
elif [ -n "${SERVER_STARTED}" ]; then
  printf "\n%sMarginalia %s is ready.%s\n" "$B$G" "${INSTALLED_VERSION}" "$X"
else
  printf "\n%sMarginalia %s installed; daemon was not started.%s\n" \
    "$B$G" "${INSTALLED_VERSION}" "$X"
fi
if [ -n "${VAULT_DIR}" ]; then
  info "preseed vault: ${VAULT_DIR} (managed independently from the daemon)"
else
  info "vaults   : create and manage them in the Web UI"
fi
if [ -n "${SERVER_STARTED}" ]; then
  info "web UI   : ${REST_URL}/"
  info "stop     : marginalia stop"
  if [ -n "${MCP_WIRED}" ]; then
    info "Claude MCP: authenticated user-scope connection registered"
  fi
else
  info "start    : marginalia serve --daemon"
fi
info "update   : re-run this installer"
