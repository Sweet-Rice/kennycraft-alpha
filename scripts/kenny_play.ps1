# One command to play on the board: Nemotron Nano (villager brains), kc-host on the UART
# (dashboard, Nemotron agents, villagers spawned on link), the dashboard in the browser, and
# kenny_keys sending keyboard and mouse through kc-host. Quit the keys window to stop it all.
#
#   .\scripts\kenny_play.ps1               COM3
#   .\scripts\kenny_play.ps1 -Port COM5 -Demo    demo village (board built with KC_DEMO=1)
#   .\scripts\kenny_play.ps1 -Root ..\kennycraft-alpha   kc-host (its .env and ledger) from another checkout
param([string]$Port = 'COM3', [switch]$Demo, [string]$Root = (Split-Path $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path $Root).Path
$started = @()

function Listening($p) { [bool](Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) }

try {
    if (-not (Listening 8080)) {   # NANO_BASE_URL in .env points here; villagers fall back to rules without it
        $started += Start-Process llama-server -PassThru -WindowStyle Minimized -ArgumentList `
            '-hf nvidia/NVIDIA-Nemotron-3-Nano-4B-GGUF:Q4_K_M --device Vulkan0 -ngl 999 -c 8192 -np 4 --jinja --host 127.0.0.1 --port 8080'
    }
    if (Listening 8000) { throw 'port 8000 is taken: another kc-host is running, stop it first' }
    $env:KC_CHIP = 'serial'; $env:KC_PORT = $Port
    if ($Demo) { $env:KC_DEMO = '1' }
    $kc = Start-Process python -PassThru -NoNewWindow -WorkingDirectory $root -ArgumentList 'host/kchost.py'
    $started += $kc
    for ($i = 0; -not (Listening 8000); $i++) {
        if ($kc.HasExited -or $i -ge 60) { throw "kc-host did not start (is $Port free?)" }
        Start-Sleep -Milliseconds 500
    }
    Start-Process 'http://127.0.0.1:8000'
    $py = Join-Path (Split-Path $PSScriptRoot) '.venv\Scripts\python.exe'   # pygame-ce; plain pygame lacks relative mouse mode
    if (-not (Test-Path $py)) { $py = 'python' }
    & $py (Join-Path $PSScriptRoot 'kenny_keys.py') --kchost
} finally {
    $started | Where-Object { -not $_.HasExited } | ForEach-Object { Stop-Process -Id $_.Id -Force }
}
