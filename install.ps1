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
    "https://github.com/OktoLabsAI/marginalia-dist/releases/download/v0.0.23/marginalia-0.0.23-py3-none-any.whl"
}
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
        exit $LASTEXITCODE
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

function Get-Health {
    try {
        return Invoke-RestMethod -Uri "$RestUrl/health" -TimeoutSec 2 -ErrorAction Stop
    } catch {
        return $null
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

trap {
    if ($script:CloneTmp -and (Test-Path $script:CloneTmp)) {
        Remove-Item -Recurse -Force $script:CloneTmp -ErrorAction SilentlyContinue
    }
    throw
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

Step "Ensuring Python $PyVersion (uv-managed; no system Python touched)"
& uv python install $PyVersion | Out-Null

Step "Resolving Marginalia source"
$spec = ""
$wheel = if ($env:MARGINALIA_WHEEL) { $env:MARGINALIA_WHEEL } else { "" }
$src = if ($env:MARGINALIA_SRC) { $env:MARGINALIA_SRC } else { "" }
if ($wheel) {
    Info "using wheel: $wheel"
    $spec = "${wheel}[$Extras]"
} elseif ($src) {
    if (-not (Test-Path (Join-Path $src "pyproject.toml"))) {
        Die "MARGINALIA_SRC has no pyproject.toml: $src"
    }
    Info "using checkout: $src"
    $spec = "${src}[$Extras]"
} elseif ($DefaultWheelUrl) {
    Info "using release wheel: $DefaultWheelUrl"
    $spec = "${DefaultWheelUrl}[$Extras]"
} else {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Die "git not found; install git or set MARGINALIA_SRC / MARGINALIA_WHEEL."
    }
    $script:CloneTmp = Join-Path ([IO.Path]::GetTempPath()) ("marginalia-install-" + [guid]::NewGuid())
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
    $spec = "${script:CloneTmp}[$Extras]"
}

$upgrade = $false
$restartVault = ""
$health = Get-Health
if ($health) {
    $upgrade = $true
    if ($health.PSObject.Properties.Name -contains "vault_path") {
        $restartVault = [string]$health.vault_path
    }
    Step "Existing Marginalia daemon detected - updating in place"
    Info "active vault: $(if ($restartVault) { $restartVault } else { 'unknown' })"
    $existing = Get-MarginaliaCommand
    if ($existing) {
        & $existing stop --vault (Join-Path $HomeRoot "runtime") | Out-Null
        if ($restartVault) {
            & $existing stop --vault $restartVault | Out-Null
        }
    }
    for ($i = 0; $i -lt 15; $i++) {
        if (-not (Get-Health)) {
            break
        }
        Start-Sleep -Seconds 1
    }
    Info "stopped the running daemon - it will restart on the new version below"
}

Step "Installing the marginalia + kg commands (extras: $Extras)"
Run-Checked "uv" @("tool", "install", "--force", "--python", $PyVersion, $spec)
if ($script:CloneTmp -and (Test-Path $script:CloneTmp)) {
    Remove-Item -Recurse -Force $script:CloneTmp
    $script:CloneTmp = $null
}

$toolBin = (& uv tool dir --bin 2>$null | Select-Object -First 1)
if (-not $toolBin) {
    $toolBin = Join-Path $HOME ".local\bin"
}
$env:Path = "$toolBin;$env:Path"
$marginalia = Get-MarginaliaCommand
if (-not $marginalia) {
    Die "marginalia installed but was not found in $toolBin. Run 'uv tool update-shell', restart PowerShell, re-run."
}
Info "marginalia: $marginalia"

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
if ($upgrade -and $restartVault) {
    $serveVault = $restartVault
    $vaultLabel = Split-Path -Leaf $restartVault
}

if ($env:MARGINALIA_NO_SERVE -eq "1") {
    Step "Skipping daemon start (MARGINALIA_NO_SERVE=1)"
} else {
    if ($upgrade) {
        Step "Restarting the daemon on the new version (vault: $vaultLabel)"
    } else {
        Step "Starting the Marginalia daemon (UI/REST :7777 + MCP :8201)"
    }
    Run-Checked $marginalia @("serve", "--daemon", "--vault", $serveVault)
    Info "waiting for the server to come up ..."
    $up = $false
    for ($i = 0; $i -lt 30; $i++) {
        if (Get-Health) {
            $up = $true
            break
        }
        Start-Sleep -Seconds 1
    }
    if ($up) {
        Info "health: ok ($RestUrl)"
    } else {
        Warn "server did not report healthy within 30s - check 'marginalia serve --foreground --vault $serveVault'"
    }
}

$globalUrl = $McpUrl
$projectExample = "{`"mcpServers`":{`"marginalia`":{`"type`":`"http`",`"url`":`"$McpUrl`?vault=$vaultLabel`"}}}"
if ($upgrade) {
    Step "Update mode - Claude Code wiring left as-is"
} elseif ($env:MARGINALIA_NO_MCP -eq "1") {
    Step "Skipping Claude Code wiring (MARGINALIA_NO_MCP=1)"
    Info "register later with: claude mcp add --scope user marginalia --transport http `"$globalUrl`""
} elseif (Get-Command claude -ErrorAction SilentlyContinue) {
    Step "Registering the MCP server with Claude Code (user scope, all projects)"
    & claude mcp add --scope user marginalia --transport http $globalUrl
    if ($LASTEXITCODE -eq 0) {
        Info "added 'marginalia' (4 tools: ask, explore, remember, init_vault) -> active vault"
        Info "per-project vault: drop a .mcp.json with ?vault=<name> in that project folder"
    } else {
        Warn "couldn't add automatically (already registered?). Run manually if needed:"
        Info "claude mcp add --scope user marginalia --transport http `"$globalUrl`""
    }
} else {
    Step "Claude Code CLI not found"
    Info "once 'claude' is on PATH, run:"
    Info "claude mcp add --scope user marginalia --transport http `"$globalUrl`""
}

Write-Host ""
if ($upgrade) {
    Write-Host "Marginalia updated and restarted." -ForegroundColor Green
} else {
    Write-Host "Marginalia is ready." -ForegroundColor Green
}
Info "vault    : $serveVault"
Info "web UI   : $RestUrl"
Info "MCP url  : $globalUrl  (active vault; all projects)"
Info "per-proj : add .mcp.json -> $projectExample"
Info "stop     : marginalia stop --vault $vaultLabel"
Info 'Try in Claude Code: "remember this note: ..." then "ask Marginalia about ..."'
