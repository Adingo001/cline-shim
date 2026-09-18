#Requires -Version 5.1
<#
.SYNOPSIS
    Windows entry point for the OpenAI4S daemon running inside WSL.

.DESCRIPTION
    OpenAI4S needs POSIX process primitives (session and process-group
    isolation, exact per-cell SIGINT, and a bubblewrap sandbox), so the
    application runs inside the Ubuntu WSL2 distro and this script only drives
    it.

    `start` brings up, in order:
      1. the Cline gateway shim on 127.0.0.1:8788, which repairs the
         {"data": {...}} envelope, the `reasoning` field name, bare model ids
         and transient routing failures from https://api.cline.bot/api/v1;
      2. the OpenAI4S daemon on 127.0.0.1:8760;
      3. a Windows scheduled task that pins the WSL2 VM in place, because WSL
         reclaims the VM -- killing both services -- once no wsl.exe client is
         attached to it.

    Helper scripts are re-synchronised from this folder on every start, and
    the shim is restarted automatically when shim.py changes.

.EXAMPLE
    .\openai4s.cmd start
    .\openai4s.cmd status
    .\openai4s.cmd logs -Tail 80
#>
[CmdletBinding()]
param(
    [ValidateSet('start', 'stop', 'restart', 'status', 'doctor', 'logs', 'url', 'shell')]
    [string]$Action = 'start',

    [int]$Tail = 40,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

$Distro   = 'Ubuntu'

# Resolved from the distro rather than hardcoded, so this script carries no
# username. wsl.exe output can come back NUL-padded, hence the strip.
$HomeDir  = ((& wsl.exe -d $Distro -- bash -lc 'echo $HOME') -replace "`0", '').Trim()
$AppDir   = "$HomeDir/openai4s"
$ShimDir  = "$HomeDir/openai4s-shim"
$ShimPort = 8788
$DaemonLog = "$HomeDir/.openai4s/logs/app.out"

function Invoke-WslBash {
    param([Parameter(Mandatory)][string]$Script)

    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script))
    & wsl.exe -d $Distro -- bash -lc "echo $encoded | base64 -d > /tmp/_o4s_run.sh; bash /tmp/_o4s_run.sh"
}

# bash -lc would inherit the Windows HOME and lose the conda/uv paths.
function New-ShellPrelude {
    @"
export HOME=$HomeDir
export MAMBA_ROOT_PREFIX=$HomeDir/.mamba
export PATH="$HomeDir/.local/bin:/usr/local/bin:/usr/bin:/bin"
# Sourced rather than recomputed: the probe behind it costs a DNS lookup, and
# the answer only changes when the proxy in front of the resolver does.
[ -r $ShimDir/.fake_ip.env ] && . $ShimDir/.fake_ip.env || true
"@
}

function ConvertTo-WslPath {
    param([Parameter(Mandatory)][string]$WinPath)

    $p = $WinPath -replace '\\', '/'
    if ($p -match '^([A-Za-z]):(.*)$') { return "/mnt/$($Matches[1].ToLower())$($Matches[2])" }
    return $p
}

function Sync-Helpers {
    param([switch]$Restart)

    # Keep the WSL-side scripts identical to the ones next to this launcher,
    # and restart the shim when its source changed.
    $restartFlag = if ($Restart) { '1' } else { '' }
    $src = ConvertTo-WslPath $PSScriptRoot
    # Every helper shapes the shim: ctl.sh carries the pin mode, keepalive.sh
    # owns its lifetime. Keying the restart on shim.py alone copied a ctl.sh
    # edit into WSL without ever restarting the process that reads it.
    $want = (@('shim.py', 'ctl.sh', 'keepalive.sh', 'patch-openai4s.sh', 'detect-fake-ip.sh') | ForEach-Object {
        (Get-FileHash (Join-Path $PSScriptRoot $_) -Algorithm SHA256).Hash.ToLower()
    }) -join ''

    $script = @"
$(New-ShellPrelude)
RESTART="$restartFlag"
mkdir -p $ShimDir
have=`$(cat $ShimDir/.helpers.sha256 2>/dev/null)
cp -f $src/shim.py   $ShimDir/shim.py
cp -f $src/ctl.sh    $ShimDir/ctl.sh
cp -f $src/keepalive.sh $ShimDir/keepalive.sh
cp -f $src/patch-openai4s.sh $ShimDir/patch-openai4s.sh
cp -f $src/detect-fake-ip.sh $ShimDir/detect-fake-ip.sh
chmod +x $ShimDir/ctl.sh $ShimDir/keepalive.sh $ShimDir/patch-openai4s.sh $ShimDir/detect-fake-ip.sh
if [ -n "`$RESTART" ] && [ "`$have" != "$want" ]; then echo 'shim   : source changed, restarting'; bash $ShimDir/ctl.sh restart; fi
printf '%s' "$want" > $ShimDir/.helpers.sha256
"@
    Invoke-WslBash -Script $script | ForEach-Object { Write-Host $_ }
}

function Start-KeepAlive {
    # WSL2 drops the VM -- and every process inside it, including a detached
    # daemon -- once no wsl.exe client is attached. A scheduled task owns that
    # client, so it outlives this shell; a Start-Process child does not.
    Invoke-WslBash -Script "$(New-ShellPrelude)`ntouch $HomeDir/.openai4s/.keepalive" | Out-Null

    $taskName = 'OpenAI4S keepalive'
    try {
        $action = New-ScheduledTaskAction -Execute 'wsl.exe' `
            -Argument "-d $Distro -- bash -lc 'bash $ShimDir/keepalive.sh'"
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -Hidden
        # A reboot can leave the task in a stale Running state with no VM
        # behind it; stop first so Start always takes effect.
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Register-ScheduledTask -TaskName $taskName -Action $action `
            -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        Write-Host 'keepalive: scheduled task running'
    }
    catch {
        Write-Host "keepalive: scheduled task unavailable - $($_.Exception.Message)"
        Start-Process -FilePath 'wsl.exe' -WindowStyle Hidden -ArgumentList @(
            '-d', $Distro, '--', 'bash', '-lc', "bash $ShimDir/keepalive.sh"
        )
        Write-Host 'keepalive: fallback process started'
    }
}

function Stop-KeepAlive {
    try {
        Stop-ScheduledTask -TaskName 'OpenAI4S keepalive' -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName 'OpenAI4S keepalive' -Confirm:$false -ErrorAction SilentlyContinue
    }
    catch { }
    Invoke-WslBash -Script "$(New-ShellPrelude)`nrm -f $HomeDir/.openai4s/.keepalive" | Out-Null
}

function Get-DaemonUrl {
    $out = Invoke-WslBash -Script @"
$(New-ShellPrelude)
cd $AppDir
.venv/bin/openai4s url 2>/dev/null
"@
    return ($out | Where-Object { $_ -match '^https?://' } | Select-Object -First 1)
}

if (-not (& wsl.exe -l -q 2>$null | Where-Object { $_.Trim() -eq $Distro })) {
    throw "WSL distro '$Distro' was not found. Check with: wsl -l -v"
}

switch ($Action) {
    'start' {
        Sync-Helpers -Restart
        # A release archive replaces webtools.py and completions.py wholesale,
        # so the local fixes are re-applied before anything imports them.
        Invoke-WslBash -Script @"
$(New-ShellPrelude)
bash $ShimDir/patch-openai4s.sh || echo 'patch  : an anchor moved -- review patch-openai4s.sh'
"@ | ForEach-Object { Write-Host $_ }

        # Before the daemon, because the answer goes into its environment and
        # web_fetch refuses a Fake-IP answer without it.
        Invoke-WslBash -Script @"
$(New-ShellPrelude)
bash $ShimDir/detect-fake-ip.sh
"@ | ForEach-Object { Write-Host $_ }

        Invoke-WslBash -Script @"
$(New-ShellPrelude)
bash $ShimDir/ctl.sh start
"@ | ForEach-Object { Write-Host $_ }

        Invoke-WslBash -Script @"
$(New-ShellPrelude)
cd $AppDir
if .venv/bin/openai4s status 2>/dev/null | grep -q 'daemon: running'; then
    echo 'daemon : already running'
else
    .venv/bin/openai4s serve --detached --no-open 2>&1 | tail -n 2
fi
sleep 4
.venv/bin/openai4s status
"@ | ForEach-Object { Write-Host $_ }

        Start-KeepAlive

        $url = Get-DaemonUrl
        if ($url) {
            Write-Host "ui     : $url"
            if (-not $NoBrowser) { Start-Process $url }
        }
    }

    'stop' {
        Sync-Helpers
        Invoke-WslBash -Script @"
$(New-ShellPrelude)
cd $AppDir
.venv/bin/openai4s stop 2>&1 | tail -n 2
bash $ShimDir/ctl.sh stop
"@ | ForEach-Object { Write-Host $_ }
        # Last, so the VM cannot drop mid-shutdown.
        Stop-KeepAlive
        Write-Host 'keepalive: stopped'
    }

    'restart' {
        & $PSCommandPath -Action stop
        Start-Sleep -Seconds 2
        & $PSCommandPath -Action start -NoBrowser:$NoBrowser
    }

    'status' {
        Sync-Helpers
        Invoke-WslBash -Script @"
$(New-ShellPrelude)
cd $AppDir
echo '--- shim ---'
bash $ShimDir/ctl.sh status
echo '--- daemon ---'
.venv/bin/openai4s status 2>&1
"@ | ForEach-Object { Write-Host $_ }
    }

    'doctor' {
        Invoke-WslBash -Script @"
$(New-ShellPrelude)
cd $AppDir
.venv/bin/openai4s doctor 2>&1
"@ | ForEach-Object { Write-Host $_ }
    }

    'logs' {
        Invoke-WslBash -Script @"
$(New-ShellPrelude)
echo '--- daemon log ---'
tail -n $Tail $DaemonLog 2>/dev/null || echo '(no log yet)'
echo ''
echo '--- shim log ---'
tail -n $Tail $ShimDir/shim.log 2>/dev/null || echo '(no log yet)'
"@ | ForEach-Object { Write-Host $_ }
    }

    'url' {
        $url = Get-DaemonUrl
        if ($url) { Write-Host $url; Start-Process $url }
        else { Write-Host 'daemon is not running' }
    }

    'shell' {
        & wsl.exe -d $Distro --cd $AppDir
    }
}