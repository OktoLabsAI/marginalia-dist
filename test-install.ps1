# Canonical public-installer tester for Marginalia on Windows PowerShell.
#
# Runs the raw GitHub install.ps1 entrypoint in an isolated PowerShell process so
# the test cannot modify the caller's real ~/.marginalia vaults or Claude config.

[CmdletBinding()]
param(
    [string]$InstallUrl = $(if ($env:MARGINALIA_INSTALL_URL) { $env:MARGINALIA_INSTALL_URL } else { "https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/install.ps1" }),
    [string]$TestHome = $(if ($env:MARGINALIA_TEST_HOME) { $env:MARGINALIA_TEST_HOME } else { Join-Path ([IO.Path]::GetTempPath()) ("marginalia-install-test-" + (Get-Date -Format "yyyyMMdd-HHmmss")) }),
    [string]$Vault = $(if ($env:MARGINALIA_VAULT) { $env:MARGINALIA_VAULT } else { "mynotes" }),
    [string]$ExpectedVersion = $(if ($env:MARGINALIA_EXPECTED_VERSION) { $env:MARGINALIA_EXPECTED_VERSION } else { "0.0.40" }),
    [ValidateSet("interactive", "skip", "custom")]
    [string]$Profile = "interactive",
    [string]$ApiBase = "",
    [string]$Model = "",
    [switch]$NoServe,
    [switch]$Cleanup,
    [switch]$AllowExistingDaemon
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Die([string]$Message) {
    Write-Error "error: $Message"
    exit 1
}

function Test-PortOpen([int]$Port) {
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $iar = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(500, $false)) {
            return $false
        }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Test-ProcessAlive([int]$ProcessId) {
    try {
        Get-Process -Id $ProcessId -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Read-TestServerProcessId([string]$Path) {
    try {
        $record = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($record.Length -gt 16384) { return 0 }
        $raw = (Get-Content -Raw -LiteralPath $Path -ErrorAction Stop).Trim()
    } catch {
        return 0
    }
    if (-not $raw) { return 0 }
    $recordProcessId = 0
    if ([int]::TryParse($raw, [ref]$recordProcessId)) {
        if ($recordProcessId -gt 0) { return $recordProcessId }
        return 0
    }
    try {
        $payload = ConvertFrom-Json $raw -ErrorAction Stop
    } catch {
        return 0
    }
    if ($null -eq $payload -or -not ($payload.PSObject.Properties.Name -contains "pid")) {
        return 0
    }
    $recordProcessId = 0
    if (-not ([int]::TryParse([string]$payload.pid, [ref]$recordProcessId))) { return 0 }
    if ($recordProcessId -gt 0) { return $recordProcessId }
    return 0
}

function Stop-TestDaemon([string]$HomePath, [string]$VaultName, [string]$ToolBin) {
    $vaultPath = Join-Path (Join-Path (Join-Path $HomePath ".marginalia") "vaults") $VaultName
    $recordPath = Join-Path $vaultPath ".marginalia\server.pid"
    $recordProcessId = Read-TestServerProcessId $recordPath
    $daemonPresent = (
        ($recordProcessId -gt 0 -and (Test-ProcessAlive $recordProcessId)) -or
        (Test-PortOpen 7777) -or
        (Test-PortOpen 8201)
    )
    if (-not $daemonPresent) { return }

    $sandboxCli = $null
    foreach ($name in @("marginalia.exe", "marginalia.cmd", "marginalia")) {
        $candidate = Join-Path $ToolBin $name
        if (Test-Path -LiteralPath $candidate) {
            $sandboxCli = $candidate
            break
        }
    }
    if (-not $sandboxCli) {
        Die "cleanup found a sandbox daemon but no sandbox marginalia command; retained $HomePath"
    }
    & $sandboxCli stop --vault $vaultPath --timeout 30 2>$null | Out-Null

    for ($i = 0; $i -lt 60; $i++) {
        if ($recordProcessId -le 0) {
            $recordProcessId = Read-TestServerProcessId $recordPath
        }
        $processAlive = $recordProcessId -gt 0 -and (Test-ProcessAlive $recordProcessId)
        if (-not $processAlive -and -not (Test-PortOpen 7777) -and -not (Test-PortOpen 8201)) {
            return
        }
        Start-Sleep -Milliseconds 500
    }
    Die "cleanup could not verify sandbox daemon shutdown; retained $HomePath"
}

if ($Profile -eq "custom" -and (-not $ApiBase -or -not $Model)) {
    Die "-Profile custom requires -ApiBase and -Model"
}

if (-not $AllowExistingDaemon) {
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:7777/health" -TimeoutSec 2 -ErrorAction Stop | Out-Null
        Die "127.0.0.1:7777 already has a Marginalia daemon. Stop it before running the isolated test."
    } catch {
        if (Test-PortOpen 7777) {
            Die "127.0.0.1:7777 is already in use. Stop the process before running the isolated test."
        }
    }
    if (-not $NoServe -and (Test-PortOpen 8201)) {
        Die "127.0.0.1:8201 is already in use. Stop the process before running the isolated test."
    }
}

$TestHome = [IO.Path]::GetFullPath($TestHome)
$RealHome = [IO.Path]::GetFullPath($HOME)
if ($TestHome -eq $RealHome -or $TestHome.StartsWith((Join-Path $RealHome ".marginalia"), [StringComparison]::OrdinalIgnoreCase)) {
    Die "refusing to use your real HOME or ~/.marginalia as the test home"
}
$SandboxUvToolDir = Join-Path $TestHome ".uv\tools"
$SandboxUvToolBin = Join-Path $TestHome ".uv\bin"
$SandboxUvPythonDir = Join-Path $TestHome ".uv\python"
$SandboxUvCacheDir = Join-Path $TestHome ".uv\cache"

New-Item -ItemType Directory -Force -Path `
    $TestHome, `
    $SandboxUvToolDir, `
    $SandboxUvToolBin, `
    $SandboxUvPythonDir, `
    $SandboxUvCacheDir | Out-Null
$Runner = Join-Path $TestHome "windows-runner.ps1"
$Evidence = Join-Path $TestHome ("evidence-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")

$child = @'
param(
    [string]$InstallUrl,
    [string]$TestHome,
    [string]$Vault,
    [string]$ExpectedVersion,
    [string]$Profile,
    [string]$ApiBase,
    [string]$Model,
    [switch]$NoServe,
    [string]$Evidence
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

New-Item -ItemType Directory -Force -Path `
    $TestHome, `
    (Join-Path $TestHome "AppData\Roaming"), `
    (Join-Path $TestHome "AppData\Local"), `
    (Join-Path $TestHome ".cache"), `
    (Join-Path $TestHome ".config"), `
    (Join-Path $TestHome ".local\share"), `
    (Join-Path $TestHome ".uv\tools"), `
    (Join-Path $TestHome ".uv\bin"), `
    (Join-Path $TestHome ".uv\python"), `
    (Join-Path $TestHome ".uv\cache") | Out-Null

$resolvedHome = [IO.Path]::GetFullPath($HOME)
$resolvedExpected = [IO.Path]::GetFullPath($TestHome)
if ($resolvedHome -ne $resolvedExpected) {
    throw "PowerShell HOME isolation failed: HOME is '$resolvedHome', expected '$resolvedExpected'. Launch the tester from test-install.ps1, not the runner directly."
}

$env:MARGINALIA_VAULT = $Vault
$env:MARGINALIA_EXPECTED_VERSION = $ExpectedVersion
$env:MARGINALIA_NO_MCP = "1"
# This tester redirects HOME/USERPROFILE but not the real Windows user-PATH
# registry - never let a sandbox run persist PATH there via uv tool update-shell.
$env:MARGINALIA_NO_UPDATE_SHELL = "1"
$env:UV_TOOL_DIR = Join-Path $TestHome ".uv\tools"
$env:UV_TOOL_BIN_DIR = Join-Path $TestHome ".uv\bin"
$env:UV_PYTHON_INSTALL_DIR = Join-Path $TestHome ".uv\python"
$env:UV_CACHE_DIR = Join-Path $TestHome ".uv\cache"
$env:XDG_DATA_HOME = Join-Path $TestHome ".local\share"
$env:XDG_CACHE_HOME = Join-Path $TestHome ".cache"
$env:XDG_CONFIG_HOME = Join-Path $TestHome ".config"
if ($NoServe) {
    $env:MARGINALIA_NO_SERVE = "1"
}

foreach ($name in @(
    "MARGINALIA_ONBOARD_NONINTERACTIVE",
    "MARGINALIA_LLM_PROVIDER",
    "MARGINALIA_LLM_API_BASE",
    "MARGINALIA_LLM_API_KEY_ENV",
    "MARGINALIA_LLM_MODEL",
    "MARGINALIA_LLM_SKIP_DISCOVERY",
    "MARGINALIA_LLM_ALLOW_REMOTE",
    "MARGINALIA_WHEEL",
    "MARGINALIA_SRC",
    "MARGINALIA_MANIFEST",
    "MARGINALIA_WHEEL_SHA256",
    "MARGINALIA_DEFAULT_WHEEL_URL",
    "MARGINALIA_DEFAULT_MANIFEST_URL",
    "MARGINALIA_REPO",
    "MARGINALIA_REF"
)) {
    if (Test-Path (Join-Path "Env:" $name)) {
        Remove-Item (Join-Path "Env:" $name) -Force
    }
}

if ($Profile -eq "skip") {
    $env:MARGINALIA_ONBOARD_NONINTERACTIVE = "1"
    $env:MARGINALIA_LLM_PROVIDER = "skip"
} elseif ($Profile -eq "custom") {
    $env:MARGINALIA_ONBOARD_NONINTERACTIVE = "1"
    $env:MARGINALIA_LLM_PROVIDER = "custom"
    $env:MARGINALIA_LLM_API_BASE = $ApiBase
    $env:MARGINALIA_LLM_MODEL = $Model
}

Start-Transcript -Path $Evidence -Force
try {
    Write-Host "TEST_HOME=$TestHome"
    Write-Host "VAULT=$Vault"
    Write-Host "PROFILE=$Profile"
    Write-Host "ENTRYPOINT_URL=$InstallUrl"
    Write-Host "INPUT_REDIRECTED=$([Console]::IsInputRedirected)"
    if ($Profile -eq "interactive" -and [Console]::IsInputRedirected) {
        throw "interactive profile requires a real Windows PowerShell terminal; redirected input is only valid for -Profile skip or -Profile custom smoke tests"
    }

    Invoke-RestMethod -UseBasicParsing $InstallUrl | Invoke-Expression

    $toolBin = (& uv tool dir --bin 2>$null | Select-Object -First 1)
    if ($toolBin) {
        $env:Path = "$toolBin;$env:Path"
    }
    & marginalia --help | Select-Object -First 12 | Out-Host
    $cliVersion = [string](& marginalia --version | Select-Object -First 1)
    if ($cliVersion.Trim() -ne "marginalia $ExpectedVersion") {
        throw "CLI version '$($cliVersion.Trim())' does not match $ExpectedVersion"
    }
    & marginalia vault current | Out-Host
    if (-not $NoServe) {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:7777/health" -TimeoutSec 5
        Write-Host "TEST_HEALTH_OK=$($health.status)"
        $version = Invoke-RestMethod -Uri "http://127.0.0.1:7777/version" -TimeoutSec 5
        if ([string]$version.marginalia_version -ne $ExpectedVersion) {
            throw "server version '$($version.marginalia_version)' does not match $ExpectedVersion"
        }
        Write-Host "TEST_VERSION_OK=$ExpectedVersion"
    }
    $yaml = Join-Path (Join-Path (Join-Path $HOME ".marginalia\vaults") $Vault) "marginalia.yaml"
    if (-not (Test-Path $yaml)) {
        throw "missing vault config: $yaml"
    }
    Write-Host "TEST_YAML=$yaml"
    if ($Profile -eq "skip" -and (Select-String -Path $yaml -Pattern "^\s*llm:" -Quiet)) {
        throw "skip profile wrote an explicit llm block"
    }
    if ($Profile -eq "custom") {
        if (-not (Select-String -Path $yaml -Pattern "^\s*provider:\s*openai\s*$" -Quiet)) {
            throw "custom profile did not write provider: openai"
        }
        if (-not (Select-String -Path $yaml -SimpleMatch "api_base: $ApiBase" -Quiet)) {
            throw "custom profile did not write api_base: $ApiBase"
        }
        if (-not (Select-String -Path $yaml -SimpleMatch "model: $Model" -Quiet)) {
            throw "custom profile did not write model: $Model"
        }
        Write-Host "WINDOWS_CUSTOM_PROFILE_OK"
    }
    Write-Host "WINDOWS_PUBLIC_INSTALL_TEST_OK"
} finally {
    Stop-Transcript
}
'@

Set-Content -LiteralPath $Runner -Value $child -Encoding UTF8

$artifactOverrideNames = @(
    "MARGINALIA_WHEEL",
    "MARGINALIA_SRC",
    "MARGINALIA_MANIFEST",
    "MARGINALIA_WHEEL_SHA256",
    "MARGINALIA_DEFAULT_WHEEL_URL",
    "MARGINALIA_DEFAULT_MANIFEST_URL",
    "MARGINALIA_REPO",
    "MARGINALIA_REF"
)
$envNames = @(
    "HOME",
    "USERPROFILE",
    "APPDATA",
    "LOCALAPPDATA",
    "UV_TOOL_DIR",
    "UV_TOOL_BIN_DIR",
    "UV_PYTHON_INSTALL_DIR",
    "UV_CACHE_DIR",
    "XDG_DATA_HOME",
    "XDG_CACHE_HOME",
    "XDG_CONFIG_HOME",
    "MARGINALIA_NO_MCP",
    "MARGINALIA_VAULT",
    "MARGINALIA_EXPECTED_VERSION",
    "MARGINALIA_NO_SERVE",
    "PATH"
) + $artifactOverrideNames
$oldEnv = @{}
foreach ($name in $envNames) {
    $oldEnv[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}

$childExitCode = 0
try {
    [Environment]::SetEnvironmentVariable("HOME", $TestHome, "Process")
    [Environment]::SetEnvironmentVariable("USERPROFILE", $TestHome, "Process")
    [Environment]::SetEnvironmentVariable("APPDATA", (Join-Path $TestHome "AppData\Roaming"), "Process")
    [Environment]::SetEnvironmentVariable("LOCALAPPDATA", (Join-Path $TestHome "AppData\Local"), "Process")
    [Environment]::SetEnvironmentVariable("UV_TOOL_DIR", $SandboxUvToolDir, "Process")
    [Environment]::SetEnvironmentVariable("UV_TOOL_BIN_DIR", $SandboxUvToolBin, "Process")
    [Environment]::SetEnvironmentVariable("UV_PYTHON_INSTALL_DIR", $SandboxUvPythonDir, "Process")
    [Environment]::SetEnvironmentVariable("UV_CACHE_DIR", $SandboxUvCacheDir, "Process")
    [Environment]::SetEnvironmentVariable("XDG_DATA_HOME", (Join-Path $TestHome ".local\share"), "Process")
    [Environment]::SetEnvironmentVariable("XDG_CACHE_HOME", (Join-Path $TestHome ".cache"), "Process")
    [Environment]::SetEnvironmentVariable("XDG_CONFIG_HOME", (Join-Path $TestHome ".config"), "Process")
    [Environment]::SetEnvironmentVariable("MARGINALIA_NO_MCP", "1", "Process")
    [Environment]::SetEnvironmentVariable("MARGINALIA_VAULT", $Vault, "Process")
    [Environment]::SetEnvironmentVariable("MARGINALIA_EXPECTED_VERSION", $ExpectedVersion, "Process")
    foreach ($name in $artifactOverrideNames) {
        [Environment]::SetEnvironmentVariable($name, $null, "Process")
    }
    if ($NoServe) {
        [Environment]::SetEnvironmentVariable("MARGINALIA_NO_SERVE", "1", "Process")
    } else {
        [Environment]::SetEnvironmentVariable("MARGINALIA_NO_SERVE", $null, "Process")
    }
    [Environment]::SetEnvironmentVariable(
        "PATH",
        "$SandboxUvToolBin;$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\Wbem;$env:SystemRoot\System32\WindowsPowerShell\v1.0",
        "Process"
    )

    $powershell = Join-Path $PSHOME "powershell.exe"
    $childArgs = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $Runner,
        "-InstallUrl",
        $InstallUrl,
        "-TestHome",
        $TestHome,
        "-Vault",
        $Vault,
        "-ExpectedVersion",
        $ExpectedVersion,
        "-Profile",
        $Profile
    )
    if ($ApiBase) {
        $childArgs += @("-ApiBase", $ApiBase)
    }
    if ($Model) {
        $childArgs += @("-Model", $Model)
    }
    if ($NoServe) {
        $childArgs += "-NoServe"
    }
    $childArgs += @("-Evidence", $Evidence)
    & $powershell @childArgs
    $childExitCode = $LASTEXITCODE
} finally {
    foreach ($name in $envNames) {
        [Environment]::SetEnvironmentVariable($name, $oldEnv[$name], "Process")
    }
}

if ($Cleanup) {
    Stop-TestDaemon $TestHome $Vault $SandboxUvToolBin
    Remove-Item -LiteralPath $TestHome -Recurse -Force -ErrorAction Stop
} else {
    Write-Host ""
    Write-Host "Sandbox/evidence kept at:"
    Write-Host "  $TestHome"
    Write-Host "Transcript:"
    Write-Host "  $Evidence"
}
if ($childExitCode -ne 0) {
    exit $childExitCode
}
