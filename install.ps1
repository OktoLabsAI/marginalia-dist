# Marginalia is now Okto Neuron. This script only forwards to the Okto Neuron
# installer, so the old one-liner keeps working:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/install.ps1 | iex"
#
# It downloads https://raw.githubusercontent.com/OktoLabsAI/okto-neuron/main/install.ps1
# and runs it the same way the documented one-liner does (Invoke-Expression in
# this session). The environment is inherited unchanged: the Okto Neuron
# installer reads every pre-0.3.0 MARGINALIA_* variable (MARGINALIA_NO_SERVE,
# MARGINALIA_NO_MCP, MARGINALIA_VAULT, ...) as its OKTO_NEURON_* equivalent, and
# it upgrades an existing `marginalia` install in place (vaults stay where they are).
#
# Marginalia 0.2.0 stays pinned in release-manifest.json. To install it on
# purpose, run the installer from the immutable v0.2.0 tag instead:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/v0.2.0/install.ps1 | iex"

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$OktoNeuronInstallerUrl = "https://raw.githubusercontent.com/OktoLabsAI/okto-neuron/main/install.ps1"

Write-Host "Marginalia is now Okto Neuron; forwarding to the Okto Neuron installer" -ForegroundColor Yellow
Write-Host "    $OktoNeuronInstallerUrl"
Write-Host "    Project: https://github.com/OktoLabsAI/okto-neuron"

# Windows PowerShell 5.1 does not always offer TLS 1.2 by default.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

try {
    $OktoNeuronInstaller = (Invoke-WebRequest -UseBasicParsing -Uri $OktoNeuronInstallerUrl).Content
} catch {
    throw "could not download the Okto Neuron installer from ${OktoNeuronInstallerUrl}: $($_.Exception.Message)"
}
if ($OktoNeuronInstaller -is [byte[]]) {
    $OktoNeuronInstaller = [Text.Encoding]::UTF8.GetString($OktoNeuronInstaller)
}
if ([string]::IsNullOrWhiteSpace($OktoNeuronInstaller) -or
    -not $OktoNeuronInstaller.Contains("Okto Neuron one-shot installer for Windows PowerShell")) {
    throw "the download from $OktoNeuronInstallerUrl is not the Okto Neuron installer; refusing to run it"
}

Invoke-Expression $OktoNeuronInstaller
