# Marginalia one-shot installer for Windows PowerShell.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/install.ps1 | iex"
#
# Takes a fresh Windows machine from zero to a running Marginalia daemon wired
# into Claude Code: prereqs -> install tool -> create vault -> configure LLM ->
# serve -> register the MCP server.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$DefaultWheelUrl = if ($env:MARGINALIA_DEFAULT_WHEEL_URL) {
    $env:MARGINALIA_DEFAULT_WHEEL_URL
} else {
    "https://github.com/OktoLabsAI/marginalia-dist/releases/download/v0.0.40/marginalia-0.0.40-py3-none-any.whl"
}
$DefaultManifestUrl = if ($env:MARGINALIA_DEFAULT_MANIFEST_URL) {
    $env:MARGINALIA_DEFAULT_MANIFEST_URL
} else {
    "https://raw.githubusercontent.com/OktoLabsAI/marginalia-dist/main/release-manifest.json"
}
$ExpectedVersion = if ($env:MARGINALIA_EXPECTED_VERSION) { $env:MARGINALIA_EXPECTED_VERSION } else { "0.0.40" }
$Extras = "embeddings,ladybug,mcp,litellm"
$PyVersion = "3.12"
$Repo = if ($env:MARGINALIA_REPO) { $env:MARGINALIA_REPO } else { "git@github.com:OktoLabsAI/marginalia.git" }
$Ref = if ($env:MARGINALIA_REF) { $env:MARGINALIA_REF } else { "" }
$Vault = if ($env:MARGINALIA_VAULT) { $env:MARGINALIA_VAULT } else { "mynotes" }
$Packs = if ($env:MARGINALIA_PACKS) { $env:MARGINALIA_PACKS } else { "core,research,personal" }
$HomeRoot = Join-Path $HOME ".marginalia"
$VaultDir = Join-Path (Join-Path $HomeRoot "vaults") $Vault
$RestUrl = "http://127.0.0.1:7777"
$McpUrl = "http://127.0.0.1:8201/mcp"
$script:CloneTmp = $null
$script:WorkTmp = $null
$script:ToolRoot = $null
$script:ToolBin = $null
$script:BackupRoot = $null
$script:PreviousVersion = ""
$script:PreviousCommand = ""
$script:RollbackVault = ""
$script:WasRunning = $false
$script:TransactionArmed = $false
$script:PreviousStopRequested = $false
$script:PreviousProcessId = 0
$script:ActivationStarted = $false
$script:ActivationCommitted = $false
$script:CandidateInstallAttempted = $false
$script:CandidateDaemonStarted = $false
$script:CandidateProcessId = 0

function Step([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Green
}

function Info([string]$Message) {
    Write-Host "    $Message"
}

function Warn([string]$Message) {
    Write-Host " !! $Message" -ForegroundColor Yellow
}

function Die([string]$Message) {
    Write-Error "error: $Message"
    exit 1
}

function Run-Checked([string]$Command, [string[]]$Arguments) {
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE"
    }
}

function Prompt-Value([string]$Message, [string]$Default = "") {
    if ($Default) {
        $answer = Read-Host "$Message [$Default]"
    } else {
        $answer = Read-Host $Message
    }
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $Default
    }
    return $answer
}

function Test-ProcessAlive([int]$ProcessId) {
    try {
        Get-Process -Id $ProcessId -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Read-ServerProcessId([string]$Path) {
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

function Find-DaemonLockRoot([int]$ProcessId, [string]$ActiveVault = "") {
    if ($ProcessId -le 0) { return "" }

    $roots = @((Join-Path $HomeRoot "runtime"))
    if ($ActiveVault) { $roots += $ActiveVault }
    $vaultRoot = Join-Path $HomeRoot "vaults"
    if (Test-Path -LiteralPath $vaultRoot) {
        $roots += @(Get-ChildItem -LiteralPath $vaultRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }

    foreach ($root in @($roots | Where-Object { $_ } | Select-Object -Unique)) {
        $recordPath = Join-Path $root ".marginalia\server.pid"
        if ((Read-ServerProcessId $recordPath) -eq $ProcessId) {
            return [string]$root
        }
    }
    return ""
}

function Test-ClaudeMcpRegistrationMatches([string]$Output, [string]$ExpectedUrl) {
    if (-not $Output -or -not $ExpectedUrl) { return $false }

    $fieldPattern = '(?m)^[ \t]*{0}:[ \t]*([^\r\n]*?)[ \t]*\r?$'
    $scopeMatches = [regex]::Matches($Output, ($fieldPattern -f "Scope"))
    $statusMatches = [regex]::Matches($Output, ($fieldPattern -f "Status"))
    $typeMatches = [regex]::Matches($Output, ($fieldPattern -f "Type"))
    $urlMatches = [regex]::Matches($Output, ($fieldPattern -f "URL"))
    if ($scopeMatches.Count -ne 1 -or $statusMatches.Count -ne 1 -or
        $typeMatches.Count -ne 1 -or $urlMatches.Count -ne 1) {
        return $false
    }

    $scope = $scopeMatches[0].Groups[1].Value
    $status = $statusMatches[0].Groups[1].Value
    $type = $typeMatches[0].Groups[1].Value
    $url = $urlMatches[0].Groups[1].Value
    $hasUserScope = $scope -cmatch '^User config(?:[ \t]+\([^()]*\))?$'
    $isConnected = $status -cmatch '^(?:[^\p{L}\p{N}\s]\s*)?Connected$'
    return ($hasUserScope -and $isConnected -and $type -ceq "http" -and
        $url -ceq $ExpectedUrl)
}

function Get-ClaudeMcpRegistrationScope([string]$Output) {
    if ($Output -cmatch '(?m)^\s*Scope:\s*Local config(?:\s+\([^()]*\))?\s*$') {
        return "local"
    }
    if ($Output -cmatch '(?m)^\s*Scope:\s*Project config(?:\s+\([^()]*\))?\s*$') {
        return "project"
    }
    if ($Output -cmatch '(?m)^\s*Scope:\s*User config(?:\s+\([^()]*\))?\s*$') {
        return "user"
    }
    return "unknown"
}

function Assert-NoUndiscoveredLiveDaemon {
    $vaultRoot = Join-Path $HomeRoot "vaults"
    $vaultPaths = @()
    if (Test-Path $vaultRoot) {
        $vaultPaths += @(Get-ChildItem -LiteralPath $vaultRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }
    $command = Get-MarginaliaCommand
    if ($command) {
        try {
            $rawVaults = (& $command vault list --json 2>$null | Out-String)
            if ($LASTEXITCODE -eq 0 -and $rawVaults) {
                $vaultPaths += @((ConvertFrom-Json $rawVaults).vaults | ForEach-Object { [string]$_.path })
            }
        } catch {}
    }
    $runtimeRoot = Join-Path $HomeRoot "runtime"
    $vaultPaths += $runtimeRoot

    foreach ($vaultPath in @($vaultPaths | Where-Object { $_ } | Select-Object -Unique)) {
        $recordPath = Join-Path $vaultPath ".marginalia\server.pid"
        if (-not (Test-Path -LiteralPath $recordPath)) {
            continue
        }
        $recordProcessId = Read-ServerProcessId $recordPath
        if ($recordProcessId -le 0 -or -not (Test-ProcessAlive $recordProcessId)) {
            continue
        }
        $stopCommand = if ($vaultPath -eq $runtimeRoot) {
            "marginalia stop"
        } else {
            "marginalia stop --vault `"$vaultPath`""
        }
        Die "a live Marginalia process (pid $recordProcessId) was found for '$vaultPath', but authenticated status at $RestUrl was unavailable. Run: $stopCommand. Custom endpoint/ports may require manual stop. Update aborted before activation."
    }
}

function Test-TcpPort([int]$Port) {
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

function Get-MarginaliaCommand {
    foreach ($name in @("marginalia", "marginalia.exe", "marginalia.cmd")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) {
            return $cmd.Source
        }
    }
    return $null
}

function Get-AuthenticatedStatus {
    $command = Get-MarginaliaCommand
    if ($command) {
        try {
            $raw = (& $command status --json --timeout 2 2>$null | Out-String)
            if ($LASTEXITCODE -eq 0 -and $raw) {
                $status = ConvertFrom-Json $raw
                if ($status.pid) { return $status }
            }
        } catch {}
    }

    $vaultPaths = @()
    if ($command) {
        try {
            $rawVaults = (& $command vault list --json 2>$null | Out-String)
            if ($LASTEXITCODE -eq 0 -and $rawVaults) {
                $vaultPaths += @((ConvertFrom-Json $rawVaults).vaults | ForEach-Object { [string]$_.path })
            }
        } catch {}
    }
    $vaultRoot = Join-Path $HomeRoot "vaults"
    if (Test-Path $vaultRoot) {
        $vaultPaths += @(Get-ChildItem -Path $vaultRoot -Filter "daemon.token" -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.Directory.Parent.FullName })
    }
    foreach ($vaultPath in @($vaultPaths | Where-Object { $_ } | Select-Object -Unique)) {
        $tokenFile = Join-Path $vaultPath ".marginalia\daemon.token"
        if (-not (Test-Path $tokenFile)) { continue }
        $token = (Get-Content -Raw $tokenFile).Trim()
        if (-not $token) { continue }
        $headers = @{ Authorization = "Bearer $token" }
        try {
            $status = Invoke-RestMethod -Uri "$RestUrl/api/v1/status" -Headers $headers -TimeoutSec 2 -ErrorAction Stop
            if ($status.pid) { return $status }
        } catch {
            try {
                $status = Invoke-RestMethod -Uri "$RestUrl/health" -Headers $headers -TimeoutSec 2 -ErrorAction Stop
                if ($status.pid) { return $status }
            } catch {}
        }
    }
    return $null
}

function Get-ToolVersion([string]$Root) {
    $python = Join-Path (Join-Path $Root "marginalia") "Scripts\python.exe"
    if (-not (Test-Path $python)) { return "" }
    try {
        return ([string](& $python -c 'import importlib.metadata; print(importlib.metadata.version("marginalia"))')).Trim()
    } catch {
        return ""
    }
}

function Get-AuthenticatedServerVersion([string]$Command, [string]$VaultPath) {
    $tokenFile = Join-Path $VaultPath ".marginalia\daemon.token"
    if (-not (Test-Path $tokenFile)) { return "" }
    $token = (Get-Content -Raw $tokenFile).Trim()
    if (-not $token) { return "" }
    $oldToken = $env:MARGINALIA_AUTH_TOKEN
    try {
        $env:MARGINALIA_AUTH_TOKEN = $token
        $payload = (& $Command status --vault $VaultPath --json --timeout 2 2>$null | Out-String)
        if ($LASTEXITCODE -eq 0 -and $payload) {
            return [string](ConvertFrom-Json $payload).marginalia_version
        }
    } catch {
        # v0.0.39 predates the status command; use its authenticated version API.
    } finally {
        $env:MARGINALIA_AUTH_TOKEN = $oldToken
    }
    try {
        $headers = @{ Authorization = "Bearer $token" }
        return [string](Invoke-RestMethod -Uri "$RestUrl/version" -Headers $headers -TimeoutSec 2 -ErrorAction Stop).marginalia_version
    } catch {
        return ""
    }
}

function Wait-ProcessExit([int]$ProcessId, [int]$TimeoutSeconds) {
    if ($ProcessId -le 0) { return $true }
    for ($i = 0; $i -lt $TimeoutSeconds; $i++) {
        if (-not (Test-ProcessAlive $ProcessId)) { return $true }
        Start-Sleep -Seconds 1
    }
    return (-not (Test-ProcessAlive $ProcessId))
}

function Stop-CandidateDaemonForRollback {
    if (-not $script:CandidateDaemonStarted) { return }
    if (-not $script:RollbackVault) {
        throw "candidate daemon vault is unknown; refusing to delete its active environment"
    }

    $recordPath = Join-Path $script:RollbackVault ".marginalia\server.pid"
    $candidateProcessId = $script:CandidateProcessId
    if ($candidateProcessId -le 0) {
        $candidateProcessId = Read-ServerProcessId $recordPath
        if ($candidateProcessId -gt 0) { $script:CandidateProcessId = $candidateProcessId }
    }
    $candidate = Join-Path $script:ToolBin "marginalia.exe"
    if (Test-Path -LiteralPath $candidate) {
        & $candidate stop --vault $script:RollbackVault --timeout 10 2>$null | Out-Null
    }

    for ($i = 0; $i -lt 15; $i++) {
        if ($candidateProcessId -le 0) {
            $candidateProcessId = Read-ServerProcessId $recordPath
            if ($candidateProcessId -gt 0) { $script:CandidateProcessId = $candidateProcessId }
        }
        $processAlive = $candidateProcessId -gt 0 -and (Test-ProcessAlive $candidateProcessId)
        if (-not $processAlive -and -not (Test-TcpPort 7777) -and -not (Test-TcpPort 8201)) {
            # When serve itself failed there may be no PID to observe. Require a
            # short quiet window so a just-spawned detached child cannot race the
            # environment deletion.
            if ($candidateProcessId -gt 0 -or $i -ge 2) {
                $script:CandidateDaemonStarted = $false
                return
            }
        }
        Start-Sleep -Seconds 1
    }

    if ($candidateProcessId -gt 0 -and (Test-ProcessAlive $candidateProcessId)) {
        throw "candidate daemon pid $candidateProcessId is still live after graceful shutdown; active environment and backup retained"
    }
    if ((Test-TcpPort 7777) -or (Test-TcpPort 8201)) {
        throw "candidate daemon ports remain open after shutdown; active environment and backup retained"
    }
    $script:CandidateDaemonStarted = $false
}

function Restore-PreviousDaemonState {
    if (-not $script:WasRunning) { return }
    if (-not $script:RollbackVault) {
        throw "previous daemon vault is unknown; restart could not be verified"
    }

    # Before activation, a failed/refused stop may leave the original process
    # untouched. Do not launch a duplicate daemon or describe that state as an
    # incomplete rollback; the prior running state is already preserved.
    if (-not $script:ActivationStarted -and $script:PreviousProcessId -gt 0 -and
        (Test-ProcessAlive $script:PreviousProcessId)) {
        Info "previous Marginalia daemon remains running (pid $($script:PreviousProcessId))"
        $script:PreviousStopRequested = $false
        return
    }

    if ($script:PreviousStopRequested -and $script:PreviousProcessId -gt 0 -and
        (Test-ProcessAlive $script:PreviousProcessId)) {
        if (-not (Wait-ProcessExit $script:PreviousProcessId 35)) {
            throw "previous daemon pid $($script:PreviousProcessId) is still draining; restart could not be verified"
        }
    } elseif (-not $script:PreviousStopRequested) {
        return
    }

    $restored = Get-MarginaliaCommand
    if (-not $restored) { $restored = $script:PreviousCommand }
    if (-not $restored -or -not (Test-Path -LiteralPath $restored)) {
        throw "previous daemon command could not be restored"
    }
    & $restored serve --daemon --vault $script:RollbackVault 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "previous daemon could not be restarted" }
    $runningVersion = ""
    for ($i = 0; $i -lt 30; $i++) {
        $runningVersion = Get-AuthenticatedServerVersion $restored $script:RollbackVault
        if ($runningVersion) { break }
        Start-Sleep -Seconds 1
    }
    if (-not $runningVersion -or
        ($script:PreviousVersion -and $runningVersion -ne $script:PreviousVersion)) {
        throw "previous daemon restart could not be verified"
    }
    Info "restored and restarted Marginalia $($script:PreviousVersion)"
}

function Restore-PreviousTool {
    if (-not $script:TransactionArmed) { return }
    Warn "installation failed; restoring the previous Marginalia state"

    if ($script:ActivationStarted) {
        Stop-CandidateDaemonForRollback
        $activeTool = Join-Path $script:ToolRoot "marginalia"
        $backupTool = if ($script:BackupRoot) { Join-Path $script:BackupRoot "tool" } else { "" }
        $hasToolBackup = $backupTool -and (Test-Path -LiteralPath $backupTool)
        $activeVersion = Get-ToolVersion $script:ToolRoot
        $replaceActiveInstallation = (
            $hasToolBackup -or $script:CandidateInstallAttempted -or -not $script:PreviousVersion
        )
        if ($replaceActiveInstallation) {
            if (Test-Path -LiteralPath $activeTool) {
                Remove-Item -LiteralPath $activeTool -Recurse -Force -ErrorAction Stop
            }
        } elseif ($activeVersion -ne $script:PreviousVersion) {
            throw "previous tool backup is missing and the active version cannot be verified; files retained"
        }
        if ($hasToolBackup) {
            Move-Item -LiteralPath $backupTool -Destination $activeTool -Force -ErrorAction Stop
        }
        $backupBin = if ($script:BackupRoot) { Join-Path $script:BackupRoot "bin" } else { "" }
        foreach ($name in @("marginalia.exe", "marginalia.cmd", "marginalia", "kg.exe", "kg.cmd", "kg")) {
            $launcher = Join-Path $script:ToolBin $name
            $backupLauncher = if ($backupBin) { Join-Path $backupBin $name } else { "" }
            $hasLauncherBackup = $backupLauncher -and (Test-Path -LiteralPath $backupLauncher)
            if (($hasLauncherBackup -or $script:CandidateInstallAttempted -or -not $script:PreviousVersion) -and
                (Test-Path -LiteralPath $launcher)) {
                Remove-Item -LiteralPath $launcher -Force -ErrorAction Stop
            }
            if ($hasLauncherBackup) {
                Move-Item -LiteralPath $backupLauncher -Destination $launcher -Force -ErrorAction Stop
            }
        }

        $restoredVersion = Get-ToolVersion $script:ToolRoot
        if ($script:PreviousVersion -and $restoredVersion -ne $script:PreviousVersion) {
            throw "previous tool restoration could not be verified (expected $($script:PreviousVersion), got $restoredVersion)"
        }
    }

    Restore-PreviousDaemonState
    if (-not $script:WasRunning) {
        Info "restored Marginalia $($script:PreviousVersion); daemon remains stopped"
    }
    $script:ActivationStarted = $false
    $script:CandidateInstallAttempted = $false
    $script:TransactionArmed = $false
    $script:PreviousStopRequested = $false
}

function Remove-InstallerTemps([switch]$KeepBackup) {
    if ($script:BackupRoot -and -not $KeepBackup) {
        Remove-Item -Recurse -Force $script:BackupRoot -ErrorAction SilentlyContinue
    } elseif ($script:BackupRoot -and $KeepBackup) {
        Warn "rollback incomplete; previous tool backup retained at $($script:BackupRoot)"
    }
    if ($script:WorkTmp) { Remove-Item -Recurse -Force $script:WorkTmp -ErrorAction SilentlyContinue }
    if ($script:CloneTmp) { Remove-Item -Recurse -Force $script:CloneTmp -ErrorAction SilentlyContinue }
}

trap {
    $originalError = $_
    $keepBackup = $false
    $restoreFailure = $null
    try {
        if ($script:TransactionArmed -and -not $script:ActivationCommitted) {
            $keepBackup = $true
            Restore-PreviousTool
            $keepBackup = $false
        }
    } catch {
        $restoreFailure = $_
        $keepBackup = $true
    } finally {
        Remove-InstallerTemps -KeepBackup:$keepBackup
    }
    if ($restoreFailure) {
        Warn "rollback incomplete: $($restoreFailure.Exception.Message)"
    }
    throw $originalError
}

Write-Host "Marginalia installer - local-first knowledge graph for Claude Code"

Step "Checking uv (the package manager Marginalia runs through)"
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Info "uv not found - installing from astral.sh ..."
    Invoke-RestMethod https://astral.sh/uv/install.ps1 | Invoke-Expression
    $localBin = Join-Path $HOME ".local\bin"
    $cargoBin = Join-Path $HOME ".cargo\bin"
    $env:Path = "$localBin;$cargoBin;$env:Path"
    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
        Die "uv installed but is not on PATH; restart PowerShell and re-run."
    }
}
Info "uv: $((Get-Command uv).Source)"

# A prior uv tool can exist even when this shell has not loaded uv's PATH
# update yet. Make it reachable before update detection needs to stop it.
$preinstallToolBin = (& uv tool dir --bin 2>$null | Select-Object -First 1)
if ($preinstallToolBin) {
    $env:Path = "$preinstallToolBin;$env:Path"
}
$script:ToolRoot = (& uv tool dir 2>$null | Select-Object -First 1)
$script:ToolBin = if ($preinstallToolBin) { $preinstallToolBin } else { Join-Path $HOME ".local\bin" }
$script:WorkTmp = Join-Path ([IO.Path]::GetTempPath()) ("marginalia-install-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $script:WorkTmp | Out-Null

Step "Ensuring Python $PyVersion (uv-managed; no system Python touched)"
& uv python install $PyVersion | Out-Null

Step "Resolving and staging the Marginalia candidate"
$spec = ""
$candidateKind = ""
$wheelSource = ""
$sourcePath = ""
$wheel = if ($env:MARGINALIA_WHEEL) { $env:MARGINALIA_WHEEL } else { "" }
$src = if ($env:MARGINALIA_SRC) { $env:MARGINALIA_SRC } else { "" }
if ($wheel) {
    Info "using wheel: $wheel"
    $candidateKind = "wheel"
    $wheelSource = $wheel
} elseif ($src) {
    if (-not (Test-Path (Join-Path $src "pyproject.toml"))) {
        Die "MARGINALIA_SRC has no pyproject.toml: $src"
    }
    Info "using checkout: $src"
    $candidateKind = "source"
    $sourcePath = $src
} elseif ($DefaultWheelUrl) {
    Info "using release wheel: $DefaultWheelUrl"
    $candidateKind = "wheel"
    $wheelSource = $DefaultWheelUrl
} else {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Die "git not found; install git or set MARGINALIA_SRC / MARGINALIA_WHEEL."
    }
    $script:CloneTmp = Join-Path $script:WorkTmp "source"
    New-Item -ItemType Directory -Path $script:CloneTmp | Out-Null
    Info "cloning $Repo ..."
    $cloneArgs = @("clone", "--depth", "1")
    if ($Ref) {
        $cloneArgs += @("--branch", $Ref)
    }
    $cloneArgs += @($Repo, $script:CloneTmp)
    & git @cloneArgs
    if ($LASTEXITCODE -ne 0) {
        Die "clone failed. Private repo? Set up SSH access, or pass MARGINALIA_SRC=<path> / MARGINALIA_WHEEL=<url>."
    }
    $candidateKind = "source"
    $sourcePath = $script:CloneTmp
}

if ($candidateKind -eq "wheel") {
    $manifestSource = if ($env:MARGINALIA_MANIFEST) { $env:MARGINALIA_MANIFEST } elseif ($wheelSource -eq $DefaultWheelUrl) { $DefaultManifestUrl } else { "" }
    $manifest = $null
    if ($manifestSource) {
        try {
            if ($manifestSource -match '^https?://') {
                $manifest = Invoke-RestMethod -Uri $manifestSource -TimeoutSec 30 -ErrorAction Stop
            } else {
                $manifestPath = $manifestSource -replace '^file://', ''
                $manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json
            }
        } catch {
            Die "could not load release manifest: $manifestSource"
        }
        foreach ($field in @("version", "wheel_url", "wheel", "sha256")) {
            if (-not $manifest.$field) { Die "release manifest is missing $field" }
        }
        $manifestWheel = [string]$manifest.wheel
        if ((Split-Path -Leaf $manifestWheel) -ne $manifestWheel) {
            Die "release manifest wheel must be a filename, not a path"
        }
        if ($ExpectedVersion -and [string]$manifest.version -ne $ExpectedVersion) {
            Die "release manifest version $($manifest.version) does not match expected $ExpectedVersion"
        }
        $ExpectedVersion = [string]$manifest.version
        if ($wheelSource -match '^https?://') {
            if ($wheelSource -ne [string]$manifest.wheel_url) { Die "wheel URL does not match release manifest" }
        } elseif ((Split-Path -Leaf $wheelSource) -ne [string]$manifest.wheel) {
            Die "wheel filename does not match release manifest"
        }
    }

    $expectedSha = if ($env:MARGINALIA_WHEEL_SHA256) { $env:MARGINALIA_WHEEL_SHA256 } elseif ($manifest) { [string]$manifest.sha256 } else { "" }
    if (-not $expectedSha) { Die "wheel verification requires MARGINALIA_MANIFEST or MARGINALIA_WHEEL_SHA256" }
    if ($manifest -and $env:MARGINALIA_WHEEL_SHA256 -and $env:MARGINALIA_WHEEL_SHA256 -ne [string]$manifest.sha256) {
        Die "MARGINALIA_WHEEL_SHA256 does not match the release manifest"
    }
    if ($expectedSha -notmatch '^[0-9a-fA-F]{64}$') { Die "wheel SHA-256 must be 64 hexadecimal characters" }

    $wheelName = if ($manifest) { [string]$manifest.wheel } else {
        if ($wheelSource -match '^https?://') {
            $wheelUriPath = ([Uri]$wheelSource).AbsolutePath
            Split-Path -Leaf $wheelUriPath
        } else {
            Split-Path -Leaf $wheelSource
        }
    }
    if (-not $wheelName.EndsWith(".whl", [StringComparison]::OrdinalIgnoreCase)) { Die "wheel filename must end in .whl" }
    $candidateWheel = Join-Path $script:WorkTmp $wheelName
    if ($wheelSource -match '^https?://') {
        Invoke-WebRequest -UseBasicParsing -Uri $wheelSource -OutFile $candidateWheel
    } else {
        Copy-Item -Force ($wheelSource -replace '^file://', '') $candidateWheel
    }
    $actualSha = (Get-FileHash -Algorithm SHA256 $candidateWheel).Hash.ToLowerInvariant()
    if ($actualSha -ne $expectedSha.ToLowerInvariant()) {
        Die "wheel SHA-256 mismatch; expected $expectedSha, got $actualSha"
    }
    Info "verified wheel SHA-256: $actualSha"
    $spec = "${candidateWheel}[$Extras]"
} else {
    $spec = "${sourcePath}[$Extras]"
}

$stageVenv = Join-Path $script:WorkTmp "stage"
Run-Checked "uv" @("venv", "--python", $PyVersion, $stageVenv)
$stagePython = Join-Path $stageVenv "Scripts\python.exe"
$stageCli = Join-Path $stageVenv "Scripts\marginalia.exe"
Run-Checked "uv" @("pip", "install", "--python", $stagePython, $spec)
$candidateVersion = ([string](& $stagePython -c 'import importlib.metadata; print(importlib.metadata.version("marginalia"))')).Trim()
if ($ExpectedVersion -and $candidateVersion -ne $ExpectedVersion) {
    Die "staged Marginalia $candidateVersion, expected $ExpectedVersion"
}
$ExpectedVersion = $candidateVersion
if (-not (Test-Path $stageCli)) { Die "staged wheel did not install the marginalia command" }
& $stageCli --help 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Die "staged marginalia command failed its help smoke" }
$stagedCliVersion = [string](& $stageCli --version 2>$null | Select-Object -First 1)
if ($LASTEXITCODE -eq 0 -and $stagedCliVersion.Trim() -ne "marginalia $candidateVersion") {
    Die "staged CLI does not match package version $candidateVersion"
}
Info "staged Marginalia $candidateVersion; active installation is still untouched"

$upgrade = $false
$wasRunning = $false
$restartVault = ""
$oldPid = 0
$oldLockRoot = ""
$status = Get-AuthenticatedStatus
if (-not $status) {
    # A daemon on a custom endpoint/port is invisible to the default REST probe.
    # Fail closed on any live vault PID record before moving the installed tool.
    Assert-NoUndiscoveredLiveDaemon
}
if ($status) {
    $upgrade = $true
    $wasRunning = $true
    $script:WasRunning = $true
    if ($status.PSObject.Properties.Name -contains "vault_path") {
        $restartVault = [string]$status.vault_path
    }
    if ($status.PSObject.Properties.Name -contains "pid") {
        $oldPid = [int]$status.pid
    }
    $oldLockRoot = Find-DaemonLockRoot $oldPid $restartVault
    if (-not $oldLockRoot) {
        Die "authenticated daemon status reported pid $oldPid, but its lifecycle lock could not be found; update aborted before shutdown"
    }
    if ($status.PSObject.Properties.Name -contains "endpoint" -and $status.endpoint) {
        $statusEndpoint = ([string]$status.endpoint).TrimEnd('/')
        if ($statusEndpoint -notin @($RestUrl, "http://localhost:7777")) {
            Die "live Marginalia daemon uses custom endpoint $statusEndpoint; update aborted before shutdown because the installer cannot preserve custom ports automatically. Stop it first: marginalia stop --vault `"$oldLockRoot`""
        }
    }
    $script:RollbackVault = $restartVault
    Step "Existing Marginalia daemon detected - updating in place"
    Info "active vault: $(if ($restartVault) { $restartVault } else { 'unknown' })"
    $existing = Get-MarginaliaCommand
    $script:PreviousCommand = if ($existing) { $existing } else { "" }
    $script:PreviousVersion = Get-ToolVersion $script:ToolRoot
    if (-not $restartVault) { Die "authenticated daemon status did not identify its active vault; update aborted" }
    if (-not $existing) { Die "daemon is running but its installed marginalia command was not found" }
    $script:PreviousProcessId = $oldPid
    # Arm rollback before requesting shutdown. Any error or interruption from
    # this point must leave the existing tool in place and restore its daemon.
    $script:TransactionArmed = $true
    $script:PreviousStopRequested = $true
    & $stageCli stop --vault $oldLockRoot --timeout 30
    if ($LASTEXITCODE -ne 0) {
        Die "could not stop the verified daemon (pid $oldPid); update aborted before replacing the installed tool"
    }
    for ($i = 0; $i -lt 10; $i++) {
        $processAlive = $oldPid -gt 0 -and (Test-ProcessAlive $oldPid)
        if (-not $processAlive -and -not (Test-TcpPort 7777)) {
            break
        }
        Start-Sleep -Seconds 1
    }
    if (($oldPid -gt 0 -and (Test-ProcessAlive $oldPid)) -or (Test-TcpPort 7777)) {
        Die "old daemon$(if ($oldPid -gt 0) { " (pid $oldPid)" }) still owns its process or port after a successful stop; update aborted before replacing the installed tool"
    }
    Info "stopped the running daemon - it will restart on the new version below"
} elseif (Test-TcpPort 7777) {
    Die "port 7777 is in use but authenticated Marginalia status is unavailable; update aborted"
} elseif ((Test-Path (Join-Path $HomeRoot "vaults")) -and
          (Get-ChildItem -Path (Join-Path $HomeRoot "vaults") -Filter "marginalia.yaml" -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1)) {
    # Daemon isn't up (crashed, machine rebooted, whatever) but this machine
    # was already set up before - a re-run should update in place, not treat
    # this as a fresh install and re-run vault-create/onboard against existing
    # state (which dies noninteractively).
    $upgrade = $true
    Step "Existing Marginalia install detected (daemon not running) - updating in place"
}

Step "Activating staged Marginalia $candidateVersion"
$script:TransactionArmed = $true
$script:PreviousCommand = if ($script:PreviousCommand) { $script:PreviousCommand } else { [string](Get-MarginaliaCommand) }
if (-not $script:PreviousVersion) { $script:PreviousVersion = Get-ToolVersion $script:ToolRoot }
$script:BackupRoot = Join-Path $script:ToolRoot (".marginalia-installer-backup-" + [guid]::NewGuid())
$backupBin = Join-Path $script:BackupRoot "bin"
New-Item -ItemType Directory -Path $backupBin -Force | Out-Null
$script:ActivationStarted = $true
$activeTool = Join-Path $script:ToolRoot "marginalia"
if (Test-Path $activeTool) { Move-Item $activeTool (Join-Path $script:BackupRoot "tool") }
foreach ($name in @("marginalia.exe", "marginalia.cmd", "marginalia", "kg.exe", "kg.cmd", "kg")) {
    $launcher = Join-Path $script:ToolBin $name
    if (Test-Path $launcher) { Move-Item $launcher (Join-Path $backupBin $name) }
}

$script:CandidateInstallAttempted = $true
& uv tool install --python $PyVersion $spec
if ($LASTEXITCODE -ne 0) { Die "candidate activation failed" }

$toolBin = $script:ToolBin
$env:Path = "$toolBin;$env:Path"
$marginalia = Get-MarginaliaCommand
if (-not $marginalia) {
    Die "marginalia installed but was not found in $toolBin. Run 'uv tool update-shell', restart PowerShell, re-run."
}
Info "marginalia: $marginalia"

$toolRoot = $script:ToolRoot
$toolPython = Join-Path (Join-Path $toolRoot "marginalia") "Scripts\python.exe"
if (-not (Test-Path $toolPython)) {
    Die "could not locate Marginalia's uv-managed Python at $toolPython"
}
$installedVersion = [string](& $toolPython -c 'import importlib.metadata; print(importlib.metadata.version("marginalia"))')
$installedVersion = $installedVersion.Trim()
if ($installedVersion -ne $candidateVersion) {
    Die "installed Marginalia $installedVersion, expected staged $candidateVersion"
}
$cliVersion = [string](& $marginalia --version 2>$null | Select-Object -First 1)
if ($LASTEXITCODE -eq 0 -and $cliVersion.Trim() -ne "marginalia $installedVersion") {
    Die "the installed marginalia command does not match package version $installedVersion"
}
Info "version: $installedVersion"

# Best-effort: persist PATH into the user's profile so a NEW PowerShell
# session (next terminal, next re-run) finds marginalia without manual setup.
# Opt out for sandboxed/test runs that must not touch the real user PATH.
if ($env:MARGINALIA_NO_UPDATE_SHELL -ne "1") {
    & uv tool update-shell 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Info "persisted PATH via 'uv tool update-shell'"
    } else {
        Warn "run 'uv tool update-shell' to persist PATH"
    }
}

# Upgrade path but health check never told us which vault was active (daemon
# wasn't running when we checked) - ask the CLI's own notion of "current".
if ($upgrade -and -not $restartVault) {
    $current = (& $marginalia vault current 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -eq 0 -and $current) {
        $restartVault = [string]$current
    }
}

if ($upgrade) {
    Step "Update mode - leaving your vaults, default, and LLM config untouched"
} else {
    Step "Creating vault '$Vault' (packs: $Packs)"
    $yaml = Join-Path $VaultDir "marginalia.yaml"
    if (Test-Path $yaml) {
        Info "vault already exists at $VaultDir - leaving it as-is"
        & $marginalia vault use $Vault | Out-Null
    } else {
        Run-Checked $marginalia @("vault", "create", $Vault, "--packs", $Packs, "--use")
        Info "created $VaultDir"
    }

    Step "Configuring provider and model with 'marginalia onboard'"
    $onboardArgs = @("onboard", "--vault", $Vault)
    if ($env:MARGINALIA_LLM_PROVIDER) {
        $onboardArgs += @("--provider", $env:MARGINALIA_LLM_PROVIDER)
    } elseif ([Console]::IsInputRedirected -or $env:MARGINALIA_ONBOARD_NONINTERACTIVE -eq "1") {
        if ($env:MARGINALIA_LLM_API_BASE -or $env:MARGINALIA_LLM_MODEL) {
            $onboardArgs += @("--provider", "custom")
        } else {
            $onboardArgs += @("--provider", "skip")
        }
    }
    if ($env:MARGINALIA_LLM_API_BASE) {
        $onboardArgs += @("--api-base", $env:MARGINALIA_LLM_API_BASE)
    }
    if ($env:MARGINALIA_LLM_MODEL) {
        $onboardArgs += @("--model", $env:MARGINALIA_LLM_MODEL)
    }
    if ($env:MARGINALIA_LLM_API_KEY_ENV) {
        $onboardArgs += @("--api-key-env", $env:MARGINALIA_LLM_API_KEY_ENV)
    }
    if ($env:MARGINALIA_LLM_SKIP_DISCOVERY -eq "1" -or $env:MARGINALIA_LLM_MODEL) {
        $onboardArgs += "--skip-model-discovery"
    }
    if ($env:MARGINALIA_LLM_ALLOW_REMOTE -eq "1") {
        $onboardArgs += @("--allow-remote-llm", "--yes")
    }
    if ([Console]::IsInputRedirected -or $env:MARGINALIA_ONBOARD_NONINTERACTIVE -eq "1") {
        $onboardArgs += "--non-interactive"
        Info "no interactive terminal detected - using noninteractive onboarding"
    }
    Run-Checked $marginalia $onboardArgs
}

$serveVault = $Vault
$vaultLabel = $Vault
$tokenVault = $VaultDir
if ($upgrade -and $restartVault) {
    $serveVault = $restartVault
    $vaultLabel = Split-Path -Leaf $restartVault
    $tokenVault = $restartVault
}
$script:RollbackVault = $tokenVault

# Tracks whether we can honestly report success at the end. Starts true -
# MARGINALIA_NO_SERVE=1 (never attempted) and upgrade (already known-good) are
# not failures. Only a failed health wait below flips it. Defined on ALL
# paths (Set-StrictMode) since the final block reads it unconditionally.
$serveOk = $true
$serverStarted = $false
$logPath = Join-Path (Join-Path $HomeRoot "logs") "marginalia-serve.log"
if ($env:MARGINALIA_NO_SERVE -eq "1") {
    Step "Skipping daemon start (MARGINALIA_NO_SERVE=1)"
} elseif ($upgrade -and -not $wasRunning) {
    Step "Preserving stopped daemon state"
    Info "the daemon was stopped before this update, so it remains stopped"
} else {
    if ($upgrade) {
        Step "Restarting the daemon on the new version (vault: $vaultLabel)"
    } else {
        Step "Starting the Marginalia daemon (UI/REST :7777 + MCP :8201)"
    }
    $script:CandidateDaemonStarted = $true
    & $marginalia serve --daemon --vault $serveVault
    $serveExitCode = $LASTEXITCODE
    $candidateRecord = Join-Path $tokenVault ".marginalia\server.pid"
    $observedCandidateProcessId = Read-ServerProcessId $candidateRecord
    if ($observedCandidateProcessId -gt 0) {
        $script:CandidateProcessId = $observedCandidateProcessId
    }
    if ($serveExitCode -ne 0) {
        $serveOk = $false
        Warn "daemon start command failed"
    } else {
        Info "waiting for server version $installedVersion ..."
        $serverVersion = ""
        for ($i = 0; $i -lt 60; $i++) {
            if ($script:CandidateProcessId -le 0) {
                $observedCandidateProcessId = Read-ServerProcessId $candidateRecord
                if ($observedCandidateProcessId -gt 0) {
                    $script:CandidateProcessId = $observedCandidateProcessId
                }
            }
            $serverVersion = Get-AuthenticatedServerVersion $marginalia $tokenVault
            if ($serverVersion -eq $installedVersion) { break }
            Start-Sleep -Seconds 1
        }
        if ($serverVersion -eq $installedVersion) {
            $serverStarted = $true
            Info "server: ready ($RestUrl, version $serverVersion)"
        } else {
            $serveOk = $false
            if ($serverVersion) {
                Warn "server reported version $serverVersion; installed version is $installedVersion"
            } else {
                Warn "server did not become ready within 60s"
            }
            Warn "try 'marginalia serve --foreground --vault $serveVault'"
            Warn "daemon log: $logPath"
        }
    }
    if (-not $serveOk -and (Test-Path $logPath)) {
        Info "last 20 lines of ${logPath}:"
        Get-Content -Path $logPath -Tail 20 | ForEach-Object { Info $_ }
    }
}

if (-not $serveOk) {
    Die "candidate daemon verification failed; the previous installation will be restored"
}
$script:ActivationCommitted = $true
$script:TransactionArmed = $false
$script:ActivationStarted = $false
$script:CandidateInstallAttempted = $false
Remove-Item -Recurse -Force $script:BackupRoot -ErrorAction SilentlyContinue
$script:BackupRoot = $null

$globalUrl = $McpUrl
$tokenFile = Join-Path $tokenVault ".marginalia\daemon.token"
$authToken = if (Test-Path $tokenFile) { (Get-Content -Raw $tokenFile).Trim() } else { "" }
$mcpWired = $false
if ($env:MARGINALIA_NO_MCP -eq "1") {
    Step "Skipping Claude Code wiring (MARGINALIA_NO_MCP=1)"
} elseif (-not $authToken) {
    Step "Claude Code wiring deferred"
    Info "start the daemon, then re-run this installer to register its authenticated MCP endpoint"
} elseif (Get-Command claude -ErrorAction SilentlyContinue) {
    Step "Registering the authenticated MCP server with Claude Code (user scope)"
    # v0.0.40 reuses the vault credential across daemon restarts. Preserve an
    # existing user registration instead of deleting a working integration before
    # its replacement is proven. A fresh registration still uses Claude's only
    # documented HTTP-header input surface.
    $mcpGetOutput = (& claude mcp get marginalia 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0) {
        if (Test-ClaudeMcpRegistrationMatches $mcpGetOutput $globalUrl) {
            $mcpWired = $true
            Info "preserved connected 'marginalia' user-scope registration"
        } else {
            $mcpScope = Get-ClaudeMcpRegistrationScope $mcpGetOutput
            Warn "an existing 'marginalia' Claude MCP entry is not the connected user-scope endpoint $globalUrl"
            if ($mcpScope -in @("local", "project")) {
                Info "resolve it with: claude mcp remove marginalia --scope $mcpScope"
            } else {
                Info "inspect it with: claude mcp get marginalia"
            }
            Die "Claude MCP registration conflict; resolve the existing entry and re-run this installer"
        }
    } else {
        & claude mcp add --scope user --transport http marginalia $globalUrl --header "Authorization: Bearer $authToken" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $mcpGetOutput = (& claude mcp get marginalia 2>&1 | Out-String)
            if ($LASTEXITCODE -ne 0 -or
                -not (Test-ClaudeMcpRegistrationMatches $mcpGetOutput $globalUrl)) {
                Die "Claude MCP registration was added but did not verify as a connected user-scope endpoint"
            }
            $mcpWired = $true
            Info "registered and verified 'marginalia' for the active vault"
        } else {
            Warn "automatic Claude Code registration failed"
        }
    }
} else {
    Step "Claude Code CLI not found"
    Info "install Claude Code, then re-run this installer to register Marginalia"
}

Write-Host ""
if (-not $serveOk) {
    Write-Host "Marginalia $installedVersion installed, but the daemon did not start correctly." -ForegroundColor Yellow
    Info "vault    : $serveVault"
    Info "start manually: marginalia serve --foreground --vault $serveVault"
    Info "log      : $logPath"
    exit 1
}

if ($upgrade) {
    if ($serverStarted) {
        Write-Host "Marginalia $installedVersion updated and restarted." -ForegroundColor Green
    } else {
        Write-Host "Marginalia $installedVersion updated; daemon remains stopped." -ForegroundColor Green
    }
} elseif ($serverStarted) {
    Write-Host "Marginalia $installedVersion is ready." -ForegroundColor Green
} else {
    Write-Host "Marginalia $installedVersion installed; daemon was not started." -ForegroundColor Green
}
Info "vault    : $serveVault"
if ($serverStarted) {
    Info "web UI   : marginalia ui"
    Info "stop     : marginalia stop --vault `"$tokenVault`""
    if ($mcpWired) {
        Info "Claude MCP: authenticated user-scope connection registered"
    }
} else {
    Info "start    : marginalia serve --daemon --vault $serveVault"
}
Info "update   : re-run this installer"
Remove-InstallerTemps
