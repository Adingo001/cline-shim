#Requires -Version 5.1
<#
.SYNOPSIS
    Keeps a shim running on this machine, with no relay and no WSL.

.DESCRIPTION
    dsh talks to http://127.0.0.1:8789. This script is what makes that address
    exist locally.

    shim.py is stdlib-only Python, so it runs unchanged on Windows -- which
    means the relay and the ssh forward were never needed *for dsh*. They were
    inherited from a layout built around OpenAI4S, which does need Linux. dsh
    does not: it is a Windows application, and the thing it talks to is a
    single-file HTTP server.

    Keeping the shim matters even without the relay. It is what pins the
    upstream channel and fails over when a channel returns an empty response --
    measured, one round went `[togetherai!] empty -> next channel` and was
    served by novita 1.9s later. Pointing dsh straight at the gateway loses
    that.

    The supervisor:
      - holds a per-port mutex, so launching twice is a no-op;
      - restarts the shim if it dies;
      - reaps a shim whose parent is gone, so hard-killing this script does not
        leak a listener that then fights the next supervisor for the port.

.EXAMPLE
    .\local-shim.ps1
    .\local-shim.ps1 -Port 8790 -Upstream https://api.cline.bot/api/v1
#>
[CmdletBinding()]
param(
    [int]$Port = 8789,
    [string]$Upstream = 'https://api.cline.bot/api/v1',
    [string]$PinMode = 'strict',
    [int]$RetrySecs = 5
)

$ErrorActionPreference = 'Stop'

$ShimScript = Join-Path $PSScriptRoot 'shim.py'

# Two files, not one. The shim's stdout is held open by Start-Process for as
# long as the shim lives, so a supervisor that appends to the same path collides
# with that handle and dies on the write. They are separate streams with
# separate lifetimes and belong in separate files.
$SupLog  = if ($env:CLINE_LOCAL_SHIM_LOG) { $env:CLINE_LOCAL_SHIM_LOG }
           else { Join-Path $PSScriptRoot 'local-shim.log' }
$ShimLog = if ($env:CLINE_LOCAL_SHIM_SHIMLOG) { $env:CLINE_LOCAL_SHIM_SHIMLOG }
           else { Join-Path $PSScriptRoot 'local-shim-shim.log' }
$SupMaxSize = 1MB

if (-not (Test-Path -LiteralPath $ShimScript)) {
    Write-Error "shim.py not found beside this script: $ShimScript"
    exit 1
}

function Write-Log($Message) {
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$stamp $Message"
    if ((Test-Path -LiteralPath $SupLog) -and
        (Get-Item -LiteralPath $SupLog).Length -gt $SupMaxSize) {
        Set-Content -LiteralPath $SupLog -Value "$line`n(log truncated)" -Encoding UTF8
    }
    Add-Content -LiteralPath $SupLog -Value $line -Encoding UTF8
}

function Find-Python {
    <#
        Windows has no single place a Python lives, and the obvious answer is a
        trap: a bare `python` on PATH is often the Microsoft Store stub in
        WindowsApps, which opens the Store instead of running anything. Real
        interpreters are tried first; the PATH lookup is a fallback that
        refuses the stub.
    #>
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python313\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\python.exe'),
        'D:\tools\miniconda3\python.exe',
        (Join-Path $env:USERPROFILE 'miniconda3\python.exe'),
        (Join-Path $env:USERPROFILE 'anaconda3\python.exe'),
        'C:\Python313\python.exe',
        'C:\Python312\python.exe'
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    foreach ($name in @('python.exe', 'python3.exe')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source -notmatch 'WindowsApps') { return $cmd.Source }
    }
    return $null
}

$Python = Find-Python
if (-not $Python) {
    Write-Error 'No usable Python found. shim.py needs Python 3.8+; set one on PATH or install it.'
    exit 1
}

$mutexName = "Local\ClineLocalShim-$Port"
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
if (-not $mutex.WaitOne(0)) {
    Write-Log "another supervisor already owns port $Port; exiting"
    exit 0
}

Write-Log "supervisor start: $Port -> $Upstream using $Python"

# A supervisor killed outright leaves its shim behind, and that orphan keeps
# holding the port. Windows lets a second listener bind anyway when the two land
# on different address families, so this does not fail loudly -- it just leaks one
# process per hard kill. Reap any shim whose parent is gone.
Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match [regex]::Escape($ShimScript) } |
    ForEach-Object {
        $parentAlive = Get-CimInstance Win32_Process -Filter "ProcessId=$($_.ParentProcessId)" -ErrorAction SilentlyContinue
        if (-not $parentAlive) {
            Write-Log "reaping orphaned shim (pid $($_.ProcessId)) holding $Port"
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }

function Rotate-ShimLog {
    if (-not (Test-Path -LiteralPath $ShimLog)) { return }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Move-Item -LiteralPath $ShimLog -Destination "$ShimLog.$stamp" -Force
    Get-ChildItem -Path "$ShimLog.*" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 3 |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

$env:CLINE_SHIM_PORT = "$Port"
$env:CLINE_UPSTREAM = $Upstream
# The same mode the relay ran with. `preferred` lets the gateway pick whenever
# the pin is unavailable; `strict` turns that into a failover instead, which is
# what catches a dead or rate-limited channel rather than silently accepting it.
$env:CLINE_SHIM_PIN_MODE = $PinMode

$proc = $null
try {
    while ($true) {
        Rotate-ShimLog
        $proc = Start-Process -FilePath $Python `
            -ArgumentList @('-u', $ShimScript) `
            -RedirectStandardOutput $ShimLog `
            -RedirectStandardError "$ShimLog.err" `
            -WindowStyle Hidden -PassThru
        Write-Log "shim started (pid $($proc.Id))"

        # The shim is an HTTP server and should simply stay up, so this loop is
        # normally silent. It exits when the process does, whatever the reason.
        while (-not $proc.HasExited) {
            Start-Sleep -Seconds 30
            $proc.Refresh()
        }

        $code = 'unknown'
        try { $code = $proc.ExitCode } catch { }
        Write-Log "shim exited (code $code); retrying in ${RetrySecs}s"
        Start-Sleep -Seconds $RetrySecs
    }
} finally {
    # Leaving the child behind is what creates the orphan reaped on the next
    # start, so do not create one on the way out.
    if ($proc -and -not $proc.HasExited) {
        try { $proc.Kill() } catch { }
        Write-Log "supervisor exiting; shim (pid $($proc.Id)) stopped"
    }
    $mutex.ReleaseMutex()
}