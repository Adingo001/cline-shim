# Install (or remove) the Cline Pass shim and the two layers that keep it up.
#
#   powershell -ExecutionPolicy Bypass -File install-autostart.ps1
#   powershell -ExecutionPolicy Bypass -File install-autostart.ps1 -Remove
#
# This is the only entry point. It copies the shim into the distro, installs the
# systemd unit, and registers the scheduled task -- nothing else has to be run.
#
# Two failure modes need two owners:
#
#   1. The shim lives inside the WSL2 VM, and the VM shuts itself down once no
#      wsl.exe client is attached -- taking the shim with it. A resident
#      `wsl.exe -d <distro> -- sleep infinity` owned by Task Scheduler keeps a
#      client attached indefinitely, so the VM never idles out.
#
#   2. The shim process itself can die. The distro already runs systemd, so a
#      unit with Restart=always brings it back within seconds and needs no
#      shell attached to do it.
#
# An earlier revision ran autostart.sh as the task's resident process. That
# worked, but it made the task a second manager of the shim and collided with
# the unit. The task now owns only the VM; systemd owns the shim.
#
# Files travel over the \\wsl.localhost share instead of through wsl.exe
# arguments: shim.py base64-encodes well past 32k, which is the Windows
# command-line ceiling, so the argument route silently truncates the largest
# file. A UNC write has no such limit and needs no quoting.
#
# The task runs as the current user, interactive. WSL distros are per-user, so
# a SYSTEM or boot-triggered task would not see this distro at all.

param(
    [switch]$Remove,
    [string]$Distro = 'Ubuntu',
    [string]$TaskName = 'Cline shim',
    [string]$User = '',
    [string]$InstallRoot = ''
)

$ErrorActionPreference = 'Stop'
$SrcDir = $PSScriptRoot

# Both defaults are resolved from the distro so this script carries no
# username and works on any machine. wsl.exe output can come back NUL-padded.
$HomeDir = ((& wsl.exe -d $Distro -- bash -lc 'echo $HOME') -replace "`0", '').Trim()
if (-not $User) { $User = $HomeDir -replace '^.*/', '' }
if (-not $InstallRoot) { $InstallRoot = "$HomeDir/openai4s-shim" }

$UnitName = 'cline-shim.service'
$UnitPath = "/etc/systemd/system/$UnitName"

# The distro is reachable as a UNC share; /home/x/y becomes \home\x\y there.
$UncRoot = "\\wsl.localhost\$Distro" + ($InstallRoot -replace '/', '\')

$UnitText = @"
[Unit]
Description=Cline shim (OpenAI-compatible adapter on 127.0.0.1:8788)

[Service]
Type=simple
User=$User
Group=$User
WorkingDirectory=$InstallRoot
ExecStart=/usr/bin/env bash $InstallRoot/autostart.sh
Restart=always
RestartSec=5
StandardOutput=append:$InstallRoot/shim-systemd.log
StandardError=append:$InstallRoot/shim-systemd.log

[Install]
WantedBy=multi-user.target
"@

function Invoke-Wsl {
    param([string]$Command, [switch]$AsRoot)
    if ($AsRoot) {
        & wsl.exe -u root -d $Distro -- bash -lc $Command
    } else {
        & wsl.exe -d $Distro -- bash -lc $Command
    }
}

if (-not (& wsl.exe -l -q 2>$null | Where-Object { $_.Trim() -eq $Distro })) {
    throw "WSL distro '$Distro' was not found. Check with: wsl -l -v"
}

if ($Remove) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Invoke-Wsl -AsRoot -Command "systemctl disable --now $UnitName 2>/dev/null; rm -f $UnitPath; systemctl daemon-reload"
    Write-Host "autostart: removed task '$TaskName' and unit '$UnitName'"
    Write-Host "autostart: $InstallRoot was left on disk -- delete it yourself if you want it gone"
    return
}

# --- layer 0: put the shim where the unit will look for it -------------------
New-Item -ItemType Directory -Force -Path $UncRoot | Out-Null

# The checkers live under tests/ in the checkout but are invoked from
# $InstallRoot, so their destination paths are flattened.
$payload = [ordered]@{
    'shim.py'             = 'shim.py'
    'ctl.sh'              = 'ctl.sh'
    'autostart.sh'        = 'autostart.sh'
    'tests\_verify.sh'    = '_verify.sh'
    'tests\_diag.sh'      = '_diag.sh'
    'tests\_heal_test.sh' = '_heal_test.sh'
}

foreach ($src in $payload.Keys) {
    $from = Join-Path $SrcDir $src
    if (-not (Test-Path $from)) { throw "missing source file: $from" }
    Copy-Item -Path $from -Destination (Join-Path $UncRoot $payload[$src]) -Force
}
Write-Host "autostart: pushed $($payload.Count) files -> $InstallRoot"

# A CRLF checkout would break every shell script and the shebang line on the
# Linux side, so strip stray carriage returns and set the exec bits.
Invoke-Wsl -Command "cd $InstallRoot && sed -i 's/\r$//' shim.py ctl.sh autostart.sh _verify.sh _diag.sh _heal_test.sh && chmod +x ctl.sh autostart.sh _verify.sh _diag.sh _heal_test.sh" | Out-Null
Write-Host "autostart: normalised line endings, set exec bits"

# --- layer 1: systemd owns the shim -----------------------------------------
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($UnitText))
Invoke-Wsl -AsRoot -Command "echo $encoded | base64 -d > $UnitPath && systemctl daemon-reload && systemctl enable $UnitName" | Out-Null
Write-Host "autostart: unit installed  -> $(Invoke-Wsl -AsRoot -Command "systemctl is-enabled $UnitName")"

# --- layer 2: the task owns the VM ------------------------------------------
$action = New-ScheduledTaskAction -Execute 'wsl.exe' `
    -Argument "-d $Distro -- sleep infinity"

# At logon, not at boot: the distro belongs to this user.
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"

# No execution time limit -- this client is meant to stay attached until logoff.
# The task dying is what lets the VM idle out, so restart it aggressively.
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew -Hidden

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

Start-Sleep -Seconds 8
Invoke-Wsl -AsRoot -Command "bash $InstallRoot/_verify.sh"
Write-Host "autostart: task '$TaskName' registered (resident VM keeper) + unit '$UnitName' enabled"
