#!/usr/bin/env bash
#
# Marginalia is now Okto Neuron. This script only forwards to the Okto Neuron
# installer, so the old one-liner keeps working:
#
#   curl -fsSL https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/install.sh | bash
#
# It downloads https://raw.githubusercontent.com/OktoLabsAI/okto-neuron/main/install.sh
# and runs it with the same arguments (for example `bash -s -- --no-onboard`).
# The environment is inherited unchanged: the Okto Neuron installer reads every
# pre-0.3.0 MARGINALIA_* variable (MARGINALIA_NO_SERVE, MARGINALIA_NO_MCP,
# MARGINALIA_VAULT, ...) as its OKTO_NEURON_* equivalent, and it upgrades an
# existing `marginalia` install in place (vaults stay where they are).
#
# Marginalia 0.2.0 stays pinned in release-manifest.json. To install it on
# purpose, run the installer from the immutable v0.2.0 tag instead:
#
#   curl -fsSL https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/v0.2.0/install.sh | bash
#
# The whole script is one function called on the last line, so under
# `curl ... | bash` nothing runs until bash has read all of it, and the child
# installer never consumes this script's remaining bytes from stdin.
set -euo pipefail

forward_to_okto_neuron() {
  local installer_url="https://raw.githubusercontent.com/OktoLabsAI/okto-neuron/main/install.sh"
  local work="" installer="" first_line="" status=0

  printf '%s\n' "Marginalia is now Okto Neuron; forwarding to the Okto Neuron installer" >&2
  printf '    %s\n' "${installer_url}" >&2
  printf '    %s\n' "Project: https://github.com/OktoLabsAI/okto-neuron" >&2

  command -v curl >/dev/null 2>&1 || {
    printf 'error: curl not found; install curl and re-run, or run the Okto Neuron installer directly: %s\n' \
      "${installer_url}" >&2
    return 1
  }

  work="$(mktemp -d "${TMPDIR:-/tmp}/marginalia-forward.XXXXXX")" || {
    printf '%s\n' "error: could not create a temporary directory" >&2
    return 1
  }
  # The EXIT trap only removes the downloaded copy; the exit status is kept.
  # shellcheck disable=SC2064
  trap "rm -rf '${work}'" EXIT
  installer="${work}/okto-neuron-install.sh"

  if ! curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "${installer}" "${installer_url}"; then
    printf 'error: could not download the Okto Neuron installer from %s\n' "${installer_url}" >&2
    return 1
  fi
  if [ -s "${installer}" ]; then
    IFS= read -r first_line < "${installer}" || true
  fi
  if [[ "${first_line}" != '#!'*bash* ]] \
     || ! grep -q '^# Okto Neuron one-shot installer' "${installer}"; then
    printf 'error: the download from %s is not the Okto Neuron installer; refusing to run it\n' "${installer_url}" >&2
    return 1
  fi

  bash "${installer}" "$@" || status=$?
  if [ "${status}" -ne 0 ]; then
    printf 'error: the Okto Neuron installer exited with status %s\n' "${status}" >&2
  fi
  return "${status}"
}

forward_to_okto_neuron "$@"
