# Canonical public-installer tester for Marginalia on Windows PowerShell.
#
# Runs the raw GitHub install.ps1 entrypoint in an isolated PowerShell process so
# the test cannot modify the caller's real ~/.marginalia vaults or Claude config.

[CmdletBinding()]
param(
    [string]$InstallUrl = $(if ($env:MARGINALIA_INSTALL_URL) { $env:MARGINALIA_INSTALL_URL } else { "https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/install.ps1" }),
    [string]$TestHome = $(if ($env:MARGINALIA_TEST_HOME) { $env:MARGINALIA_TEST_HOME } else { Join-Path ([IO.Path]::GetTempPath()) ("marginalia-install-test-" + (Get-Date -Format "yyyyMMdd-HHmmss") + "-" + [guid]::NewGuid().ToString("N")) }),
    [string]$Vault = $(if ($env:MARGINALIA_VAULT) { $env:MARGINALIA_VAULT } else { "mynotes" }),
    [string]$ExpectedVersion = $(if ($env:MARGINALIA_EXPECTED_VERSION) { $env:MARGINALIA_EXPECTED_VERSION } else { "0.0.40" }),
    [ValidateSet("interactive", "skip", "custom", "release-lifecycle")]
    [string]$Profile = "interactive",
    [string]$ApiBase = "",
    [string]$Model = "",
    [string]$DriverCommit = $(if ($env:MARGINALIA_TEST_DRIVER_COMMIT) { $env:MARGINALIA_TEST_DRIVER_COMMIT } else { "" }),
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
        throw "cleanup found a sandbox daemon but no sandbox marginalia command; retained $HomePath"
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
    throw "cleanup could not verify sandbox daemon shutdown; retained $HomePath"
}

function Initialize-TestSandbox([string]$HomePath, [string]$TempRoot) {
    $resolvedHome = [IO.Path]::GetFullPath($HomePath).TrimEnd('\', '/')
    $resolvedTemp = [IO.Path]::GetFullPath($TempRoot).TrimEnd('\', '/')
    $parent = [IO.Path]::GetFullPath((Split-Path -Parent $resolvedHome)).TrimEnd('\', '/')
    $leaf = Split-Path -Leaf $resolvedHome
    if ($parent -ne $resolvedTemp -or $leaf -notmatch '^marginalia-install-test-[A-Za-z0-9._-]+$') {
        throw "test home must be a uniquely named marginalia-install-test-* directory directly under $resolvedTemp"
    }
    $marker = Join-Path $resolvedHome ".marginalia-test-sandbox-owner"
    if (Test-Path -LiteralPath $resolvedHome) {
        if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or
            (Get-Content -Raw -LiteralPath $marker).Trim() -ne "marginalia-test-sandbox-v1") {
            throw "refusing to reuse unowned test directory: $resolvedHome"
        }
    } else {
        New-Item -ItemType Directory -Path $resolvedHome -ErrorAction Stop | Out-Null
        Set-Content -LiteralPath $marker -Value "marginalia-test-sandbox-v1" -Encoding ASCII
    }
    return $resolvedHome
}

function Remove-TestSandbox([string]$HomePath, [string]$TempRoot) {
    $resolvedHome = [IO.Path]::GetFullPath($HomePath).TrimEnd('\', '/')
    $resolvedTemp = [IO.Path]::GetFullPath($TempRoot).TrimEnd('\', '/')
    $parent = [IO.Path]::GetFullPath((Split-Path -Parent $resolvedHome)).TrimEnd('\', '/')
    $marker = Join-Path $resolvedHome ".marginalia-test-sandbox-owner"
    if ($parent -ne $resolvedTemp -or
        -not (Test-Path -LiteralPath $marker -PathType Leaf) -or
        (Get-Content -Raw -LiteralPath $marker).Trim() -ne "marginalia-test-sandbox-v1") {
        throw "refusing to delete unowned test directory: $resolvedHome"
    }
    Remove-Item -LiteralPath $resolvedHome -Recurse -Force -ErrorAction Stop
}

function Export-PublicEvidence(
    [string]$RawPath,
    [string]$PublicPath,
    [string]$TestRoot,
    [string]$CallerHome,
    [string]$CallerIdentity,
    [string]$MachineIdentity
) {
    if (-not (Test-Path -LiteralPath $RawPath -PathType Leaf)) {
        throw "raw Windows transcript was not created: $RawPath"
    }
    $lines = @(Get-Content -LiteralPath $RawPath)
    $delimiters = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\*{10,}$') { $delimiters += $i }
    }
    if ($delimiters.Count -lt 4) {
        throw "raw Windows transcript did not contain complete start/end headers"
    }
    $bodyStart = $delimiters[1] + 1
    $bodyEnd = $delimiters[$delimiters.Count - 2] - 1
    if ($bodyEnd -lt $bodyStart) {
        throw "raw Windows transcript contained no evidence body"
    }
    $text = ($lines[$bodyStart..$bodyEnd] -join "`r`n") + "`r`n"
    foreach ($replacement in @(
        [pscustomobject]@{ From = $TestRoot; To = "<TEST_HOME>" },
        [pscustomobject]@{ From = $CallerHome; To = "<CALLER_HOME>" },
        [pscustomobject]@{ From = $CallerIdentity; To = "<WINDOWS_USER>" },
        [pscustomobject]@{ From = $MachineIdentity; To = "<WINDOWS_MACHINE>" }
    )) {
        if ($replacement.From) {
            $text = [regex]::Replace(
                $text,
                [regex]::Escape([string]$replacement.From),
                [string]$replacement.To,
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
        }
    }
    foreach ($forbidden in @(
        'Windows PowerShell transcript (?:start|end)',
        '(?m)^(?:Username|RunAs User|Machine|Host Application|Process ID|PSVersion|PSEdition|PSCompatibleVersions|BuildVersion|CLRVersion|WSManStackVersion|PSRemotingProtocolVersion|SerializationVersion):'
    )) {
        if ($text -match $forbidden) {
            throw "sanitized Windows evidence retained a transcript identity/header field"
        }
    }
    foreach ($identity in @($TestRoot, $CallerHome, $CallerIdentity, $MachineIdentity)) {
        if ($identity -and $text.IndexOf($identity, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw "sanitized Windows evidence retained private identity data"
        }
    }
    Set-Content -LiteralPath $PublicPath -Value $text -Encoding UTF8
}

if ($Profile -eq "custom" -and (-not $ApiBase -or -not $Model)) {
    Die "-Profile custom requires -ApiBase and -Model"
}
if ($Profile -eq "release-lifecycle" -and $NoServe) {
    Die "-Profile release-lifecycle cannot be combined with -NoServe"
}
if ($Profile -eq "release-lifecycle" -and
    ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
     $PSVersionTable.PSEdition -ne "Desktop")) {
    Die "-Profile release-lifecycle requires Windows PowerShell 5.1 on Windows"
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

$OriginalTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$TestHome = Initialize-TestSandbox $TestHome $OriginalTempRoot
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
$EvidenceStem = "evidence-" + (Get-Date -Format "yyyyMMdd-HHmmss")
$RawEvidence = Join-Path $TestHome ($EvidenceStem + ".private.raw.log")
$Evidence = Join-Path $TestHome ($EvidenceStem + ".public.log")
$DriverUrl = "UNPINNED_SMOKE"
$DriverSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $PSCommandPath).Hash.ToLowerInvariant()
$InstallSha256 = ""
$ManifestUrl = ""
$ManifestSha256 = ""
if ($Profile -eq "release-lifecycle") {
    if ($DriverCommit -cnotmatch '^[0-9a-f]{40}$') {
        throw "-DriverCommit must be an exact 40-character lowercase dist commit for release-lifecycle"
    }
    $rawBase = "https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/$DriverCommit"
    $DriverUrl = "$rawBase/test-install.ps1"
    $InstallUrl = "$rawBase/install.ps1"
    $ManifestUrl = "$rawBase/release-manifest.json"
    $remoteDriver = Join-Path $TestHome "provenance-test-install.ps1"
    $remoteInstaller = Join-Path $TestHome "provenance-install.ps1"
    $remoteManifest = Join-Path $TestHome "provenance-release-manifest.json"
    Invoke-WebRequest -UseBasicParsing -Uri $DriverUrl -OutFile $remoteDriver
    Invoke-WebRequest -UseBasicParsing -Uri $InstallUrl -OutFile $remoteInstaller
    Invoke-WebRequest -UseBasicParsing -Uri $ManifestUrl -OutFile $remoteManifest
    $remoteDriverHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $remoteDriver).Hash.ToLowerInvariant()
    if ($remoteDriverHash -ne $DriverSha256) {
        throw "running test-install.ps1 does not match exact public driver commit $DriverCommit"
    }
    $InstallSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $remoteInstaller).Hash.ToLowerInvariant()
    $ManifestSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $remoteManifest).Hash.ToLowerInvariant()
    $manifest = Get-Content -Raw -LiteralPath $remoteManifest | ConvertFrom-Json
    if ([string]$manifest.version -ne $ExpectedVersion) {
        throw "pinned release manifest version '$($manifest.version)' does not match $ExpectedVersion"
    }
}

$child = @'
param(
    [string]$InstallUrl,
    [string]$TestHome,
    [string]$Vault,
    [string]$ExpectedVersion,
    [string]$Profile,
    [string]$ApiBase,
    [string]$Model,
    [string]$DriverCommit,
    [string]$DriverUrl,
    [string]$DriverSha256,
    [string]$InstallSha256,
    [string]$ManifestUrl,
    [string]$ManifestSha256,
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
    (Join-Path $TestHome ".uv\python-bin"), `
    (Join-Path $TestHome ".uv\python-cache"), `
    (Join-Path $TestHome ".uv\cache"), `
    (Join-Path $TestHome ".local\bin"), `
    (Join-Path $TestHome "tmp") | Out-Null

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
$env:UV_INSTALL_DIR = Join-Path $TestHome ".uv\bin"
$env:UV_PYTHON_INSTALL_DIR = Join-Path $TestHome ".uv\python"
$env:UV_PYTHON_BIN_DIR = Join-Path $TestHome ".uv\python-bin"
$env:UV_PYTHON_CACHE_DIR = Join-Path $TestHome ".uv\python-cache"
$env:UV_CACHE_DIR = Join-Path $TestHome ".uv\cache"
$env:UV_NO_MODIFY_PATH = "1"
$env:UV_PYTHON_NO_REGISTRY = "1"
$env:UV_PYTHON_INSTALL_REGISTRY = "0"
Remove-Item Env:UV_UNMANAGED_INSTALL -ErrorAction SilentlyContinue
$env:TEMP = Join-Path $TestHome "tmp"
$env:TMP = Join-Path $TestHome "tmp"
$env:XDG_DATA_HOME = Join-Path $TestHome ".local\share"
$env:XDG_CACHE_HOME = Join-Path $TestHome ".cache"
$env:XDG_CONFIG_HOME = Join-Path $TestHome ".config"
$env:XDG_BIN_HOME = Join-Path $TestHome ".local\bin"
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
    "MARGINALIA_PACKS",
    "MARGINALIA_WHEEL",
    "MARGINALIA_SRC",
    "MARGINALIA_MANIFEST",
    "MARGINALIA_WHEEL_SHA256",
    "MARGINALIA_DEFAULT_WHEEL_URL",
    "MARGINALIA_DEFAULT_MANIFEST_URL",
    "MARGINALIA_REPO",
    "MARGINALIA_REF",
    "MARGINALIA_ENDPOINT",
    "MARGINALIA_AUTH_TOKEN",
    "MARGINALIA_TEST_INSTALL_URL",
    "MARGINALIA_TEST_FAIL_ACTIVATION",
    "MARGINALIA_REAL_UV"
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
if ($Profile -eq "release-lifecycle") {
    $env:MARGINALIA_MANIFEST = $ManifestUrl
    $env:MARGINALIA_DEFAULT_MANIFEST_URL = $ManifestUrl
    $env:MARGINALIA_PACKS = "core,research,personal"
    $existingVaultConfig = Join-Path `
        (Join-Path (Join-Path (Join-Path $HOME ".marginalia") "vaults") $Vault) `
        "marginalia.yaml"
    $existingTool = Join-Path $env:UV_TOOL_DIR "marginalia"
    if ((Test-Path -LiteralPath $existingVaultConfig) -or
        (Test-Path -LiteralPath $existingTool)) {
        throw "release-lifecycle requires a fresh test home: $TestHome"
    }
}

function Test-ChildProcessAlive([int]$ProcessId) {
    try {
        Get-Process -Id $ProcessId -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Test-ChildTcpPort([int]$Port) {
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $result = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
        if (-not $result.AsyncWaitHandle.WaitOne(500, $false)) {
            return $false
        }
        $client.EndConnect($result)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Wait-TestHealth([string]$Endpoint) {
    for ($i = 0; $i -lt 90; $i++) {
        try {
            Invoke-RestMethod -Uri "$($Endpoint.TrimEnd('/'))/health" -TimeoutSec 2 -ErrorAction Stop | Out-Null
            return
        } catch {
            Start-Sleep -Seconds 1
        }
    }
    throw "daemon did not become healthy at $Endpoint"
}

function Wait-TestDaemonStopped([int]$ProcessId, [int[]]$Ports) {
    for ($i = 0; $i -lt 60; $i++) {
        $processAlive = $ProcessId -gt 0 -and (Test-ChildProcessAlive $ProcessId)
        $portOpen = $false
        foreach ($port in $Ports) {
            if (Test-ChildTcpPort $port) {
                $portOpen = $true
                break
            }
        }
        if (-not $processAlive -and -not $portOpen) {
            return
        }
        Start-Sleep -Milliseconds 500
    }
    throw "daemon process or ports remained live after stop (pid $ProcessId; ports $($Ports -join ','))"
}

function Invoke-TestMarginalia([string]$Command, [string[]]$Arguments) {
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "marginalia $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Get-TestStatus([string]$Command, [string]$VaultPath, [string]$Endpoint = "") {
    $oldEndpoint = $env:MARGINALIA_ENDPOINT
    try {
        if ($Endpoint) {
            $env:MARGINALIA_ENDPOINT = $Endpoint
        } else {
            Remove-Item Env:MARGINALIA_ENDPOINT -ErrorAction SilentlyContinue
        }
        $raw = (& $Command status --vault $VaultPath --json --timeout 5 2>$null | Out-String)
        if ($LASTEXITCODE -ne 0 -or -not $raw.Trim()) {
            throw "authenticated status failed for $VaultPath"
        }
        return ($raw | ConvertFrom-Json)
    } finally {
        $env:MARGINALIA_ENDPOINT = $oldEndpoint
    }
}

function Confirm-DefaultDaemon([string]$Command, [string]$VaultPath, [string]$Version) {
    $endpoint = "http://127.0.0.1:7777"
    Wait-TestHealth $endpoint
    $status = Get-TestStatus $Command $VaultPath
    if ([string]$status.marginalia_version -ne $Version) {
        throw "server version '$($status.marginalia_version)' does not match $Version"
    }
    if ([string]$status.endpoint -ne $endpoint) {
        throw "server endpoint '$($status.endpoint)' does not match $endpoint"
    }
    $processId = [int]$status.pid
    if ($processId -le 0 -or -not (Test-ChildProcessAlive $processId)) {
        throw "authenticated status did not identify a live daemon process"
    }

    $tokenFile = Join-Path $VaultPath ".marginalia\daemon.token"
    if (-not (Test-Path -LiteralPath $tokenFile)) {
        throw "missing daemon token: $tokenFile"
    }
    $token = (Get-Content -Raw -LiteralPath $tokenFile).Trim()
    if (-not $token) {
        throw "daemon token is empty: $tokenFile"
    }
    $response = Invoke-WebRequest -UseBasicParsing -Uri "$endpoint/" `
        -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 5 -ErrorAction Stop
    if ($response.StatusCode -ne 200 -or $response.Content -notmatch '(?i)<(?:!doctype\s+html|html)') {
        throw "authenticated UI fetch did not return the Marginalia HTML application"
    }

    $uiOutput = (& $Command ui --no-open --vault $VaultPath 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "marginalia ui --no-open failed"
    }
    $expectedUi = "Authenticated Marginalia UI is ready at $endpoint; browser launch skipped"
    if ($uiOutput -ne $expectedUi) {
        throw "unexpected authenticated UI output: $uiOutput"
    }
    Write-Host $uiOutput
    return $status
}

function Invoke-RawInstallerProcess([string]$Url, [string]$OutputPath) {
    $nestedPowerShell = Join-Path $PSHOME "powershell.exe"
    $installCommand = '$ProgressPreference = "SilentlyContinue"; Invoke-RestMethod -UseBasicParsing $env:MARGINALIA_TEST_INSTALL_URL | Invoke-Expression'
    $oldInstallUrl = $env:MARGINALIA_TEST_INSTALL_URL
    try {
        $env:MARGINALIA_TEST_INSTALL_URL = $Url
        $output = @(& $nestedPowerShell -NoProfile -ExecutionPolicy Bypass -Command $installCommand 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $env:MARGINALIA_TEST_INSTALL_URL = $oldInstallUrl
    }
    $output | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    $output | Out-Host
    return $exitCode
}

function Assert-OutputContains([string]$Path, [string]$Expected) {
    $output = Get-Content -Raw -LiteralPath $Path
    if (-not $output.Contains($Expected)) {
        throw "installer output $Path did not contain: $Expected"
    }
}

function Assert-TokenUnchanged([string]$Path, [string]$Baseline) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "daemon token disappeared during release lifecycle"
    }
    $current = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path))
    if ($current -cne $Baseline) {
        throw "daemon token changed during release lifecycle"
    }
}

function Invoke-ReleaseLifecycle(
    [string]$Command,
    [string]$VaultPath,
    [string]$Version,
    [string]$Url,
    [string]$HomePath
) {
    Write-Host "WINDOWS_RELEASE_LIFECYCLE_INTERACTIVE_ONBOARDING_OK"
    $status = Confirm-DefaultDaemon $Command $VaultPath $Version
    Write-Host "RELEASE_LIFECYCLE_FRESH_INSTALL_OK"
    Write-Host "RELEASE_LIFECYCLE_STATUS_UI_OK"

    $yaml = Join-Path $VaultPath "marginalia.yaml"
    $configHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $yaml).Hash.ToLowerInvariant()
    $tokenPath = Join-Path $VaultPath ".marginalia\daemon.token"
    $initialToken = [Convert]::ToBase64String([IO.File]::ReadAllBytes($tokenPath))

    $stoppedProcessId = [int]$status.pid
    Invoke-TestMarginalia $Command @("stop", "--vault", $VaultPath, "--timeout", "30")
    Wait-TestDaemonStopped $stoppedProcessId @(7777, 8201)
    $stoppedOutput = Join-Path $HomePath "stopped-update.out"
    $stoppedExitCode = Invoke-RawInstallerProcess $Url $stoppedOutput
    if ($stoppedExitCode -ne 0) {
        throw "stopped update failed with exit code $stoppedExitCode"
    }
    Assert-OutputContains $stoppedOutput "daemon remains stopped"
    if ((Test-ChildTcpPort 7777) -or (Test-ChildTcpPort 8201)) {
        throw "stopped update unexpectedly started the daemon"
    }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $yaml).Hash.ToLowerInvariant() -ne $configHash) {
        throw "stopped update changed marginalia.yaml"
    }
    Assert-TokenUnchanged $tokenPath $initialToken
    Write-Host "RELEASE_LIFECYCLE_STOPPED_UPDATE_OK"

    Invoke-TestMarginalia $Command @("serve", "--daemon", "--vault", $VaultPath)
    $status = Confirm-DefaultDaemon $Command $VaultPath $Version
    $runningBefore = [int]$status.pid
    $runningOutput = Join-Path $HomePath "running-update.out"
    $runningExitCode = Invoke-RawInstallerProcess $Url $runningOutput
    if ($runningExitCode -ne 0) {
        throw "running update failed with exit code $runningExitCode"
    }
    $status = Confirm-DefaultDaemon $Command $VaultPath $Version
    $runningAfter = [int]$status.pid
    if ($runningBefore -eq $runningAfter) {
        throw "running update did not replace the daemon process"
    }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $yaml).Hash.ToLowerInvariant() -ne $configHash) {
        throw "running update changed marginalia.yaml"
    }
    Assert-TokenUnchanged $tokenPath $initialToken
    $realUv = (Get-Command uv -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $toolRoot = ([string](& $realUv tool dir | Select-Object -First 1)).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $toolRoot) {
        throw "could not resolve uv tool directory after running update"
    }
    $rollbackSentinel = Join-Path (Join-Path $toolRoot "marginalia") `
        ".release-lifecycle-previous-tool-sentinel"
    if (Test-Path -LiteralPath $rollbackSentinel) {
        throw "previous-tool rollback sentinel already exists: $rollbackSentinel"
    }
    Set-Content -LiteralPath $rollbackSentinel `
        -Value "previous-tool-only:$Version" -Encoding ASCII
    $rollbackSentinelHash = (Get-FileHash -Algorithm SHA256 `
        -LiteralPath $rollbackSentinel).Hash.ToLowerInvariant()
    Write-Host "RELEASE_LIFECYCLE_RUNNING_UPDATE_OK"

    Invoke-TestMarginalia $Command @("stop", "--vault", $VaultPath, "--timeout", "30")
    Wait-TestDaemonStopped $runningAfter @(7777, 8201)
    Invoke-TestMarginalia $Command @(
        "serve", "--daemon", "--vault", $VaultPath, "--port", "7788", "--mcp-port", "8202"
    )
    $customEndpoint = "http://127.0.0.1:7788"
    Wait-TestHealth $customEndpoint
    $customStatus = Get-TestStatus $Command $VaultPath $customEndpoint
    $customProcessId = [int]$customStatus.pid
    if ($customProcessId -le 0 -or -not (Test-ChildProcessAlive $customProcessId)) {
        throw "custom-port status did not identify a live daemon process"
    }
    if ([string]$customStatus.endpoint -ne $customEndpoint -or
        [string]$customStatus.marginalia_version -ne $Version) {
        throw "custom-port status did not report the expected endpoint and version"
    }
    $customOutput = Join-Path $HomePath "custom-port-refusal.out"
    $oldEndpoint = $env:MARGINALIA_ENDPOINT
    try {
        $env:MARGINALIA_ENDPOINT = $customEndpoint
        $customExitCode = Invoke-RawInstallerProcess $Url $customOutput
    } finally {
        $env:MARGINALIA_ENDPOINT = $oldEndpoint
    }
    if ($customExitCode -eq 0) {
        throw "installer accepted a running custom-port daemon"
    }
    Assert-OutputContains $customOutput "uses custom endpoint"
    Assert-OutputContains $customOutput $customEndpoint
    if (-not (Test-ChildProcessAlive $customProcessId)) {
        throw "custom-port refusal stopped the existing daemon"
    }
    if (([string](& $Command --version | Select-Object -First 1)).Trim() -ne "marginalia $Version") {
        throw "custom-port refusal changed the installed CLI version"
    }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $yaml).Hash.ToLowerInvariant() -ne $configHash) {
        throw "custom-port refusal changed marginalia.yaml"
    }
    Assert-TokenUnchanged $tokenPath $initialToken
    if (-not (Test-Path -LiteralPath $rollbackSentinel -PathType Leaf)) {
        throw "custom-port refusal replaced the previous tool"
    }
    if ((Get-FileHash -Algorithm SHA256 `
        -LiteralPath $rollbackSentinel).Hash.ToLowerInvariant() -ne $rollbackSentinelHash) {
        throw "custom-port refusal changed the previous tool"
    }
    try {
        $env:MARGINALIA_ENDPOINT = $customEndpoint
        Invoke-TestMarginalia $Command @("stop", "--vault", $VaultPath, "--timeout", "30")
    } finally {
        $env:MARGINALIA_ENDPOINT = $oldEndpoint
    }
    Wait-TestDaemonStopped $customProcessId @(7788, 8202)
    Write-Host "RELEASE_LIFECYCLE_CUSTOM_PORT_REFUSAL_OK"

    $guardVault = Join-Path (Join-Path (Join-Path $HomePath ".marginalia") "vaults") "release-pid-guard"
    $guardRecordRoot = Join-Path $guardVault ".marginalia"
    New-Item -ItemType Directory -Force -Path $guardRecordRoot | Out-Null
    $nestedPowerShell = Join-Path $PSHOME "powershell.exe"
    $guardProcess = Start-Process -FilePath $nestedPowerShell `
        -ArgumentList @("-NoProfile", "-Command", "Start-Sleep -Seconds 1800") `
        -WindowStyle Hidden -PassThru
    try {
        Set-Content -LiteralPath (Join-Path $guardRecordRoot "server.pid") `
            -Value ([string]$guardProcess.Id) -Encoding ASCII
        $guardOutput = Join-Path $HomePath "live-pid-refusal.out"
        $guardExitCode = Invoke-RawInstallerProcess $Url $guardOutput
        if ($guardExitCode -eq 0) {
            throw "installer accepted an unverified live PID record"
        }
        Assert-OutputContains $guardOutput "live Marginalia process (pid $($guardProcess.Id))"
        Assert-OutputContains $guardOutput "marginalia stop --vault"
        if (-not (Test-ChildProcessAlive $guardProcess.Id)) {
            throw "live-PID refusal stopped the unrelated guard process"
        }
        if (([string](& $Command --version | Select-Object -First 1)).Trim() -ne "marginalia $Version") {
            throw "live-PID refusal changed the installed CLI version"
        }
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $yaml).Hash.ToLowerInvariant() -ne $configHash) {
            throw "live-PID refusal changed marginalia.yaml"
        }
    } finally {
        if (Test-ChildProcessAlive $guardProcess.Id) {
            Stop-Process -Id $guardProcess.Id -Force -ErrorAction SilentlyContinue
            $guardProcess.WaitForExit()
        }
        Remove-Item -LiteralPath $guardVault -Recurse -Force -ErrorAction SilentlyContinue
    }
    Assert-TokenUnchanged $tokenPath $initialToken
    if (-not (Test-Path -LiteralPath $rollbackSentinel -PathType Leaf)) {
        throw "live-PID refusal replaced the previous tool"
    }
    if ((Get-FileHash -Algorithm SHA256 `
        -LiteralPath $rollbackSentinel).Hash.ToLowerInvariant() -ne $rollbackSentinelHash) {
        throw "live-PID refusal changed the previous tool"
    }
    Write-Host "RELEASE_LIFECYCLE_LIVE_PID_REFUSAL_OK"

    Invoke-TestMarginalia $Command @("serve", "--daemon", "--vault", $VaultPath)
    $status = Confirm-DefaultDaemon $Command $VaultPath $Version
    $rollbackBefore = [int]$status.pid
    $rollbackOutput = Join-Path $HomePath "activation-rollback.out"
    $shimRoot = Join-Path $HomePath "activation-failure-shim"
    New-Item -ItemType Directory -Force -Path $shimRoot | Out-Null
    @(
        '@echo off',
        'if "%MARGINALIA_TEST_FAIL_ACTIVATION%"=="1" if /I "%~1"=="tool" if /I "%~2"=="install" exit /b 77',
        '"%MARGINALIA_REAL_UV%" %*',
        'exit /b %ERRORLEVEL%'
    ) | Set-Content -LiteralPath (Join-Path $shimRoot "uv.cmd") -Encoding ASCII
    $oldPath = $env:Path
    $oldFailActivation = $env:MARGINALIA_TEST_FAIL_ACTIVATION
    $oldRealUv = $env:MARGINALIA_REAL_UV
    try {
        $env:MARGINALIA_REAL_UV = $realUv
        $env:MARGINALIA_TEST_FAIL_ACTIVATION = "1"
        $env:Path = "$shimRoot;$oldPath"
        $rollbackExitCode = Invoke-RawInstallerProcess $Url $rollbackOutput
    } finally {
        $env:Path = $oldPath
        $env:MARGINALIA_TEST_FAIL_ACTIVATION = $oldFailActivation
        $env:MARGINALIA_REAL_UV = $oldRealUv
        Remove-Item -LiteralPath $shimRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($rollbackExitCode -eq 0) {
        throw "forced activation failure unexpectedly succeeded"
    }
    Assert-OutputContains $rollbackOutput "candidate activation failed"
    Assert-OutputContains $rollbackOutput "restored and restarted Marginalia $Version"
    $status = Confirm-DefaultDaemon $Command $VaultPath $Version
    $rollbackAfter = [int]$status.pid
    if ($rollbackBefore -eq $rollbackAfter) {
        throw "activation rollback did not restart the previous daemon"
    }
    if (([string](& $Command --version | Select-Object -First 1)).Trim() -ne "marginalia $Version") {
        throw "activation rollback did not restore the CLI version"
    }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $yaml).Hash.ToLowerInvariant() -ne $configHash) {
        throw "activation rollback changed marginalia.yaml"
    }
    Assert-TokenUnchanged $tokenPath $initialToken
    if (-not (Test-Path -LiteralPath $rollbackSentinel -PathType Leaf)) {
        throw "activation rollback did not restore the previous-tool sentinel"
    }
    if ((Get-FileHash -Algorithm SHA256 `
        -LiteralPath $rollbackSentinel).Hash.ToLowerInvariant() -ne $rollbackSentinelHash) {
        throw "activation rollback changed the previous-tool sentinel"
    }
    if (Get-ChildItem -LiteralPath $toolRoot -Directory `
        -Filter ".marginalia-installer-backup-*" -ErrorAction SilentlyContinue) {
        throw "activation rollback left an installer backup directory"
    }
    Write-Host "RELEASE_LIFECYCLE_PREVIOUS_TOOL_SENTINEL_SHA256=$rollbackSentinelHash"
    Write-Host "RELEASE_LIFECYCLE_PREVIOUS_TOOL_SENTINEL_OK"
    Write-Host "RELEASE_LIFECYCLE_ACTIVATION_ROLLBACK_OK"

    Invoke-TestMarginalia $Command @("stop", "--vault", $VaultPath, "--timeout", "30")
    Wait-TestDaemonStopped $rollbackAfter @(7777, 8201)
    Assert-TokenUnchanged $tokenPath $initialToken
    Write-Host "RELEASE_LIFECYCLE_FINAL_STOP_OK"
    Write-Host "WINDOWS_RELEASE_LIFECYCLE_OK"
}

Start-Transcript -Path $Evidence -Force
try {
    Write-Host "TEST_HOME=$TestHome"
    Write-Host "VAULT=$Vault"
    Write-Host "PROFILE=$Profile"
    if ($Profile -eq "release-lifecycle") {
        Write-Host "DRIVER_COMMIT=$DriverCommit"
        Write-Host "DRIVER_URL=$DriverUrl"
        Write-Host "DRIVER_SHA256=$DriverSha256"
        Write-Host "INSTALL_SHA256=$InstallSha256"
        Write-Host "MANIFEST_URL=$ManifestUrl"
        Write-Host "MANIFEST_SHA256=$ManifestSha256"
    }
    Write-Host "ENTRYPOINT_URL=$InstallUrl"
    Write-Host "INPUT_REDIRECTED=$([Console]::IsInputRedirected)"
    if ($Profile -in @("interactive", "release-lifecycle") -and [Console]::IsInputRedirected) {
        throw "$Profile profile requires a real Windows PowerShell terminal; redirected input is only valid for -Profile skip or -Profile custom smoke tests"
    }

    Invoke-RestMethod -UseBasicParsing $InstallUrl | Invoke-Expression

    $toolBin = (& uv tool dir --bin 2>$null | Select-Object -First 1)
    if ($toolBin) {
        $env:Path = "$toolBin;$env:Path"
    }
    $sandboxCli = (Get-Command marginalia -ErrorAction Stop).Source
    if (-not $sandboxCli) {
        throw "sandbox marginalia command was not found after installation"
    }
    $vaultPath = Join-Path (Join-Path (Join-Path $HOME ".marginalia") "vaults") $Vault
    & $sandboxCli --help | Select-Object -First 12 | Out-Host
    $cliVersion = [string](& $sandboxCli --version | Select-Object -First 1)
    if ($cliVersion.Trim() -ne "marginalia $ExpectedVersion") {
        throw "CLI version '$($cliVersion.Trim())' does not match $ExpectedVersion"
    }
    $currentVault = (& $sandboxCli vault current 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $currentVault) {
        throw "marginalia vault current failed after fresh installation"
    }
    if ([IO.Path]::GetFullPath($currentVault) -ne [IO.Path]::GetFullPath($vaultPath)) {
        throw "current vault '$currentVault' does not match sandbox vault '$vaultPath'"
    }
    Write-Host $currentVault
    if (-not $NoServe) {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:7777/health" -TimeoutSec 5
        Write-Host "TEST_HEALTH_OK=$($health.status)"
        $version = Invoke-RestMethod -Uri "http://127.0.0.1:7777/version" -TimeoutSec 5
        if ([string]$version.marginalia_version -ne $ExpectedVersion) {
            throw "server version '$($version.marginalia_version)' does not match $ExpectedVersion"
        }
        Write-Host "TEST_VERSION_OK=$ExpectedVersion"
    }
    $yaml = Join-Path $vaultPath "marginalia.yaml"
    if (-not (Test-Path $yaml)) {
        throw "missing vault config: $yaml"
    }
    Write-Host "TEST_YAML=$yaml"
    if ($Profile -in @("skip", "release-lifecycle") -and
        (Select-String -Path $yaml -Pattern "^\s*llm:" -Quiet)) {
        throw "$Profile profile wrote an explicit llm block"
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
    if ($Profile -eq "release-lifecycle") {
        Invoke-ReleaseLifecycle $sandboxCli $vaultPath $ExpectedVersion $InstallUrl $TestHome
    } else {
        Write-Host "WINDOWS_PUBLIC_INSTALL_TEST_OK"
    }
} finally {
    Stop-Transcript
}
'@

Set-Content -LiteralPath $Runner -Value $child -Encoding UTF8

$isolatedMarginaliaNames = @(
    "MARGINALIA_WHEEL",
    "MARGINALIA_SRC",
    "MARGINALIA_MANIFEST",
    "MARGINALIA_WHEEL_SHA256",
    "MARGINALIA_DEFAULT_WHEEL_URL",
    "MARGINALIA_DEFAULT_MANIFEST_URL",
    "MARGINALIA_REPO",
    "MARGINALIA_REF",
    "MARGINALIA_PACKS",
    "MARGINALIA_ENDPOINT",
    "MARGINALIA_AUTH_TOKEN",
    "MARGINALIA_TEST_DRIVER_COMMIT"
)
$envNames = @(
    "HOME",
    "USERPROFILE",
    "APPDATA",
    "LOCALAPPDATA",
    "UV_TOOL_DIR",
    "UV_TOOL_BIN_DIR",
    "UV_INSTALL_DIR",
    "UV_UNMANAGED_INSTALL",
    "UV_PYTHON_INSTALL_DIR",
    "UV_PYTHON_BIN_DIR",
    "UV_PYTHON_CACHE_DIR",
    "UV_CACHE_DIR",
    "UV_NO_MODIFY_PATH",
    "UV_PYTHON_NO_REGISTRY",
    "UV_PYTHON_INSTALL_REGISTRY",
    "TEMP",
    "TMP",
    "XDG_DATA_HOME",
    "XDG_CACHE_HOME",
    "XDG_CONFIG_HOME",
    "XDG_BIN_HOME",
    "MARGINALIA_NO_MCP",
    "MARGINALIA_VAULT",
    "MARGINALIA_EXPECTED_VERSION",
    "MARGINALIA_NO_SERVE",
    "PATH"
) + $isolatedMarginaliaNames
$oldEnv = @{}
foreach ($name in $envNames) {
    $oldEnv[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}

$childExitCode = 0
$stopError = $null
$CallerIdentity = if ($env:USERDOMAIN -and $env:USERNAME) {
    "$($env:USERDOMAIN)\$($env:USERNAME)"
} else {
    [Environment]::UserName
}
$MachineIdentity = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [Environment]::MachineName }
try {
    [Environment]::SetEnvironmentVariable("HOME", $TestHome, "Process")
    [Environment]::SetEnvironmentVariable("USERPROFILE", $TestHome, "Process")
    [Environment]::SetEnvironmentVariable("APPDATA", (Join-Path $TestHome "AppData\Roaming"), "Process")
    [Environment]::SetEnvironmentVariable("LOCALAPPDATA", (Join-Path $TestHome "AppData\Local"), "Process")
    [Environment]::SetEnvironmentVariable("UV_TOOL_DIR", $SandboxUvToolDir, "Process")
    [Environment]::SetEnvironmentVariable("UV_TOOL_BIN_DIR", $SandboxUvToolBin, "Process")
    [Environment]::SetEnvironmentVariable("UV_INSTALL_DIR", $SandboxUvToolBin, "Process")
    [Environment]::SetEnvironmentVariable("UV_UNMANAGED_INSTALL", $null, "Process")
    [Environment]::SetEnvironmentVariable("UV_PYTHON_INSTALL_DIR", $SandboxUvPythonDir, "Process")
    [Environment]::SetEnvironmentVariable("UV_PYTHON_BIN_DIR", (Join-Path $TestHome ".uv\python-bin"), "Process")
    [Environment]::SetEnvironmentVariable("UV_PYTHON_CACHE_DIR", (Join-Path $TestHome ".uv\python-cache"), "Process")
    [Environment]::SetEnvironmentVariable("UV_CACHE_DIR", $SandboxUvCacheDir, "Process")
    [Environment]::SetEnvironmentVariable("UV_NO_MODIFY_PATH", "1", "Process")
    [Environment]::SetEnvironmentVariable("UV_PYTHON_NO_REGISTRY", "1", "Process")
    [Environment]::SetEnvironmentVariable("UV_PYTHON_INSTALL_REGISTRY", "0", "Process")
    [Environment]::SetEnvironmentVariable("TEMP", (Join-Path $TestHome "tmp"), "Process")
    [Environment]::SetEnvironmentVariable("TMP", (Join-Path $TestHome "tmp"), "Process")
    [Environment]::SetEnvironmentVariable("XDG_DATA_HOME", (Join-Path $TestHome ".local\share"), "Process")
    [Environment]::SetEnvironmentVariable("XDG_CACHE_HOME", (Join-Path $TestHome ".cache"), "Process")
    [Environment]::SetEnvironmentVariable("XDG_CONFIG_HOME", (Join-Path $TestHome ".config"), "Process")
    [Environment]::SetEnvironmentVariable("XDG_BIN_HOME", (Join-Path $TestHome ".local\bin"), "Process")
    [Environment]::SetEnvironmentVariable("MARGINALIA_NO_MCP", "1", "Process")
    [Environment]::SetEnvironmentVariable("MARGINALIA_VAULT", $Vault, "Process")
    [Environment]::SetEnvironmentVariable("MARGINALIA_EXPECTED_VERSION", $ExpectedVersion, "Process")
    foreach ($name in $isolatedMarginaliaNames) {
        [Environment]::SetEnvironmentVariable($name, $null, "Process")
    }
    if ($Profile -eq "release-lifecycle") {
        [Environment]::SetEnvironmentVariable("MARGINALIA_MANIFEST", $ManifestUrl, "Process")
        [Environment]::SetEnvironmentVariable("MARGINALIA_DEFAULT_MANIFEST_URL", $ManifestUrl, "Process")
        [Environment]::SetEnvironmentVariable("MARGINALIA_PACKS", "core,research,personal", "Process")
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
    if ($Profile -eq "release-lifecycle") {
        $childArgs += @(
            "-DriverCommit", $DriverCommit,
            "-DriverUrl", $DriverUrl,
            "-DriverSha256", $DriverSha256,
            "-InstallSha256", $InstallSha256,
            "-ManifestUrl", $ManifestUrl,
            "-ManifestSha256", $ManifestSha256
        )
    }
    if ($ApiBase) {
        $childArgs += @("-ApiBase", $ApiBase)
    }
    if ($Model) {
        $childArgs += @("-Model", $Model)
    }
    if ($NoServe) {
        $childArgs += "-NoServe"
    }
    $childArgs += @("-Evidence", $RawEvidence)
    & $powershell @childArgs
    $childExitCode = $LASTEXITCODE
} finally {
    if ($Cleanup -or $Profile -eq "release-lifecycle") {
        try {
            Stop-TestDaemon $TestHome $Vault $SandboxUvToolBin
        } catch {
            $stopError = $_.Exception.Message
        }
    }
    foreach ($name in $envNames) {
        [Environment]::SetEnvironmentVariable($name, $oldEnv[$name], "Process")
    }
}

if (Test-Path -LiteralPath $RawEvidence -PathType Leaf) {
    Export-PublicEvidence `
        $RawEvidence $Evidence $TestHome $RealHome $CallerIdentity $MachineIdentity
}
if ($stopError) { throw $stopError }
if ($Cleanup) {
    Remove-TestSandbox $TestHome $OriginalTempRoot
} else {
    Write-Host ""
    Write-Host "Sandbox/evidence kept at:"
    Write-Host "  $TestHome"
    Write-Host "Public sanitized evidence:"
    Write-Host "  $Evidence"
    Write-Host "Private raw transcript (do not publish):"
    Write-Host "  $RawEvidence"
}
if ($childExitCode -ne 0) {
    exit $childExitCode
}
