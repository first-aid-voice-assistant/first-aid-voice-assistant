<#
.SYNOPSIS
  Starts and stops the parts of the PoC: the LLM container, the server and the mobile app.

.EXAMPLE
  .\scripts\dev.ps1 llm                       # Ollama container with the GPU
  .\scripts\dev.ps1 server -Model qwen -EventLog
  .\scripts\dev.ps1 mobile -Device R58M12345
  .\scripts\dev.ps1 status
  .\scripts\dev.ps1 stop

  Parts: llm | server | mobile | all (each in its own window) | status | stop
  server starts the LLM container first (with the GPU), except for -Model fake or with -NoLlm
  -Model     server config in poc/server/configs: gemma (default), bielik, qwen, fake
  -EventLog  turn the event log on (a temporary copy of the config; the file in the repo stays off)
  -Lan       listen on all interfaces so that a phone in the same Wi-Fi can connect
  -Cpu       llm (and server): do not use the GPU
  -NoLlm     server: do not touch the LLM container (e.g. Ollama runs elsewhere)
  -Device    mobile: device id from `flutter devices`
  -Mode      mobile: release (default, measure speed in it), profile or debug
  -Reverse   mobile: run `adb reverse` so that a phone on USB reaches the server at 127.0.0.1
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('llm', 'server', 'mobile', 'all', 'status', 'stop')]
    [string]$Part,
    [ValidateSet('gemma', 'bielik', 'qwen', 'fake')]
    [string]$Model = 'gemma',
    [switch]$EventLog,
    [switch]$Lan,
    [switch]$Cpu,
    [switch]$NoLlm,
    [string]$Device,
    [ValidateSet('release', 'profile', 'debug')]
    [string]$Mode = 'release',
    [switch]$Reverse,
    [int]$Port = 8000
)

$Root = Split-Path -Parent $PSScriptRoot
$ServerDir = Join-Path $Root 'poc\server'
$MobileDir = Join-Path $Root 'poc\mobile'

function Write-Step([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }

function Get-ServerProcessIds {
    Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique
}

function Get-LlmContainerId {
    Push-Location $ServerDir
    try { return (docker compose ps -q llm 2>$null | Select-Object -First 1) } finally { Pop-Location }
}

# The model named in a server config, as Ollama calls it (empty for the fake model).
function Get-ConfigModel([string]$Config) {
    $text = Get-Content (Join-Path $ServerDir "configs\$Config.yaml") -Raw
    if ($text -match 'model:\s*"ollama_chat/([^"]+)"') { return $Matches[1] }
    return ''
}

function Start-Llm {
    Push-Location $ServerDir
    try {
        $files = @('-f', 'docker-compose.yml')
        # Always the same files: a plain `up` would recreate the container without the GPU.
        if (-not $Cpu) { $files += @('-f', 'docker-compose.gpu.yml') }
        Write-Step ("Starting the LLM container " + $(if ($Cpu) { '(CPU only)' } else { 'with the GPU' }))
        & docker compose @files up -d llm
        if ($LASTEXITCODE -ne 0) { throw 'docker compose failed (is Docker running?)' }

        $id = Get-LlmContainerId
        for ($i = 0; $i -lt 40; $i++) {
            if ((docker inspect -f '{{.State.Health.Status}}' $id) -eq 'healthy') { break }
            Start-Sleep -Seconds 2
        }
        if (-not $Cpu -and (docker inspect -f '{{json .HostConfig.DeviceRequests}}' $id) -eq 'null') {
            Write-Warning 'The container has no GPU access (NVIDIA Container Toolkit installed?).'
        }
        Write-Step 'Models in the container'
        & docker compose exec -T llm ollama list
        $needed = Get-ConfigModel $Model
        if ($needed -and -not ((docker compose exec -T llm ollama list) -match [regex]::Escape($needed))) {
            Write-Warning "Model '$needed' (config '$Model') is missing. Pull it: docker compose exec llm ollama pull $needed"
        }
        Write-Host 'Ollama: http://localhost:11434. The first question loads the model (up to a minute); after it check the GPU share with: .\scripts\dev.ps1 status'
    } finally { Pop-Location }
}

function Start-Server {
    if (Get-ServerProcessIds) { throw "Port $Port is in use. Run '.\scripts\dev.ps1 stop' first." }
    # The model must be there before the server takes questions. Safe to repeat: `up -d` with
    # unchanged files leaves a running container alone.
    if ($Model -ne 'fake' -and -not $NoLlm) { Start-Llm }
    $config = Join-Path $ServerDir "configs\$Model.yaml"
    if ($EventLog) {
        $text = Get-Content $config -Raw
        $on = $text -replace 'event_log:\s*\{\s*enabled:\s*false\s*\}', 'event_log: { enabled: true }'
        if ($on -eq $text) { Write-Warning "Config '$Model' has no 'event_log: { enabled: false }' line to switch on." }
        $config = Join-Path ([IO.Path]::GetTempPath()) "voice-assistant-$Model-event-log.yaml"
        Set-Content -Path $config -Value $on -Encoding UTF8
    }
    $bind = if ($Lan) { '0.0.0.0' } else { '127.0.0.1' }
    Write-Step "Server: config '$Model', event log $(if ($EventLog) { 'ON' } else { 'as in the config' }), http://${bind}:$Port"
    if ($Lan) {
        $ip = Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object { $_.IPAddress -notmatch '^(127|169\.254)' -and $_.PrefixOrigin -ne 'WellKnown' } |
            Select-Object -First 1 -ExpandProperty IPAddress
        Write-Host "Phone (same Wi-Fi): http://${ip}:$Port - set it in Settings of the app; allow the port in the Windows firewall."
    }
    $env:APP_CONFIG = $config
    $env:DEV_MODE = 'true'
    Push-Location $ServerDir
    try { & uv run uvicorn app.main:app --host $bind --port $Port } finally { Pop-Location }
}

function Start-Mobile {
    if ($Reverse) {
        $adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
        if (-not $adb) {
            $adb = @("$env:ANDROID_HOME\platform-tools\adb.exe", "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe") |
                Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
        }
        if (-not $adb) { throw 'adb not found (add Android SDK platform-tools to PATH).' }
        & $adb reverse "tcp:$Port" "tcp:$Port"
    }
    Push-Location $MobileDir
    try {
        Write-Step "Mobile app ($Mode)"
        & flutter pub get
        $run = @('run', "--$Mode")
        if ($Device) { $run += @('-d', $Device) }
        & flutter @run
    } finally { Pop-Location }
}

function Open-Window([string[]]$Arguments) {
    Start-Process powershell -ArgumentList (@('-NoExit', '-NoProfile', '-File', $PSCommandPath) + $Arguments)
}

function Show-Status {
    $id = Get-LlmContainerId
    if ($id -and (docker inspect -f '{{.State.Running}}' $id) -eq 'true') {
        $gpu = if ((docker inspect -f '{{json .HostConfig.DeviceRequests}}' $id) -eq 'null') { 'NO GPU access' } else { 'GPU access' }
        Write-Host "LLM container: running ($gpu)"
        Push-Location $ServerDir
        try { & docker compose exec -T llm ollama ps } finally { Pop-Location }
    } else { Write-Host 'LLM container: stopped' }
    try {
        $health = Invoke-RestMethod "http://localhost:$Port/health" -TimeoutSec 3
        $llm = (Invoke-RestMethod "http://localhost:$Port/v1/providers" -TimeoutSec 3).llm.params.model
        Write-Host "Server: $($health.status) on port $Port, model $llm"
    } catch { Write-Host "Server: not running on port $Port" }
}

function Stop-All {
    foreach ($p in Get-ServerProcessIds) {
        $name = (Get-Process -Id $p -ErrorAction SilentlyContinue).ProcessName
        if ($name -match 'python|uv') { Stop-Process -Id $p -Force; Write-Host "Server stopped (pid $p)" }
        else { Write-Warning "Port $Port is held by '$name' (pid $p), not stopping it." }
    }
    Push-Location $ServerDir
    try { & docker compose stop llm } finally { Pop-Location }
}

switch ($Part) {
    'llm'    { Start-Llm }
    'server' { Start-Server }
    'mobile' { Start-Mobile }
    'status' { Show-Status }
    'stop'   { Stop-All }
    'all' {
        Start-Llm
        $serverArgs = @('server', '-NoLlm', '-Model', $Model, '-Port', $Port)  # the LLM is up already
        if ($EventLog) { $serverArgs += '-EventLog' }
        if ($Lan) { $serverArgs += '-Lan' }
        Open-Window $serverArgs
        $mobileArgs = @('mobile', '-Mode', $Mode, '-Port', $Port)
        if ($Device) { $mobileArgs += @('-Device', $Device) }
        if ($Reverse) { $mobileArgs += '-Reverse' }
        Open-Window $mobileArgs
    }
}
