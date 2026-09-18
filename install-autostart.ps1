# Install (or remove) the local autostart layers for both consumers.
#
#   $env:CLINE_TUNNEL_SERVER = '<relay host>'
#   powershell -ExecutionPolicy Bypass -File install-autostart.ps1
#   powershell -ExecutionPolicy Bypass -File install-autostart.ps1 -Remove
#
# This is the only entry point. Nothing else has to be run.
#
# There are two consumers, they live on different sides of the WSL boundary, and
# neither depends on the other:
#
#   dsh        runs on Windows. It needs `tunnel-shim.ps1` holding an ssh
#              forward to the relay's shim at 127.0.0.1:$LocalPort.
#
#   OpenAI4S   runs inside the distro. It needs the distro to be *running*, and
#              two enabled units inside it: the same forward at 127.0.0.1:8788,
#              and the daemon itself.
#
# This script used to install a shim into the distro. It does not any more: the
# shim runs on the relay, and a shim in the distro would be a second, competing
# copy. What the distro needs is a forward to the relay's shim, not a shim.
#
# Why the distro needs a keeper on the Windows side:
#
#   WSL2 tears a distro down once no wsl.exe client is attached and it has been
#   idle, and a running systemd inside does not prevent it -- the whole VM goes
#   away. The distro stopping takes both units with it. A bare
#   `Start-Process wsl.exe ... sleep infinity` does not fix this: that client is
#   torn down with the launching shell, which removes the last attached client
#   and triggers the very shutdown it was meant to prevent. So the client has to
#   be owned by a supervisor that outlives every shell -- `wsl-keepalive.ps1`.
#
# Why the Startup folder and not Task Scheduler:
#
#   `schtasks /create /sc onlogon` needs administrator rights, and a normal
#   account does not have them. The Startup folder is per-user, needs no
#   elevation, and runs the same scripts.
#
# Files travel over the \\wsl.localhost share instead of through wsl.exe
# arguments where size matters: a payload base64-encoded past ~32k hits the
# Windows command-line ceiling and is silently truncated. A UNC write has no
# such limit and needs no quoting.

param(
    [switch]$Remove,
    [string]$Distro = 'Ubuntu',
    [string]$Server = '',
    [string]$TunnelUser = '',
    [int]$LocalPort = 0,
    [int]$RemotePort = 0,
    [string]$User = '',
    [string]$OpenAI4SRoot = '',
    [string]$KeyPath = ''
)

# A parameter default has to be a constant, so anything that reads the
# environment is resolved here instead. 0 means "not supplied" for the ports.
if (-not $Server) { $Server = $env:CLINE_TUNNEL_SERVER }
if (-not $TunnelUser) { $TunnelUser = if ($env:CLINE_TUNNEL_USER) { $env:CLINE_TUNNEL_USER } else { 'root' } }
if ($LocalPort -eq 0) { $LocalPort = if ($env:CLINE_TUNNEL_LPORT) { [int]$env:CLINE_TUNNEL_LPORT } else { 8789 } }
if ($RemotePort -eq 0) { $RemotePort = if ($env:CLINE_TUNNEL_RPORT) { [int]$env:CLINE_TUNNEL_RPORT } else { 8788 } }

$ErrorActionPreference = 'Stop'
$SrcDir = $PSScriptRoot

# Resolved from the distro so this script carries no username and works on any
# machine. wsl.exe output can come back NUL-padded.
$HomeDir = ((& wsl.exe -d $Distro -- bash -lc 'echo $HOME') -replace "`0", '').Trim()
if (-not $User) { $User = $HomeDir -replace '^.*/', '' }
if (-not $OpenAI4SRoot) { $OpenAI4SRoot = "$HomeDir/openai4s" }
if (-not $KeyPath) { $KeyPath = "$HomeDir/.ssh/relay_shim" }

$TunnelUnit = '/etc/systemd/system/cline-shim-tunnel.service'
$OpenAI4SUnit = '/etc/systemd/system/openai4s.service'
$RetiredUnit = '/etc/systemd/system/cline-shim.service'

$StartupDir = [Environment]::GetFolderPath('Startup')

function Invoke-Wsl {
    param([string]$Command, [switch]$AsRoot)
    if ($AsRoot) { & wsl.exe -u root -d $Distro -- bash -lc $Command }
    else         { & wsl.exe -d $Distro -- bash -lc $Command }
}

function Write-StartupLauncher {
    param([string]$Name, [string]$ScriptPath, [string]$EnvBlock = '', [string]$Body)

    # The launcher sets no arguments beyond the script path, so no
    # deployment-specific value is baked into the tracked scripts. The one value
    # that has to travel -- the relay host -- is written into the launcher
    # itself: it is per-machine, it lives outside the checkout, and tunnel-shim.ps1
    # deliberately ships without a default rather than hardcoding one.
    $vbs = @"
' Launches $Name at logon, without a console window.
$Body
$EnvBlock
CreateObject("WScript.Shell").Run _
    "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""$ScriptPath""", _
    0, False
"@
    $dest = Join-Path $StartupDir "$Name.vbs"
    Set-Content -Path $dest -Value $vbs -Encoding ASCII
    Write-Host "autostart: launcher written -> $dest"
}

if (-not (& wsl.exe -l -q 2>$null | Where-Object { $_.Trim() -eq $Distro })) {
    throw "WSL distro '$Distro' was not found. Check with: wsl -l -v"
}

if ($Remove) {
    Remove-Item (Join-Path $StartupDir 'cline-shim-tunnel.vbs') -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $StartupDir 'wsl-keepalive.vbs') -ErrorAction SilentlyContinue
    Write-Host "autostart: removed both Startup launchers"

    Invoke-Wsl -AsRoot -Command "systemctl disable --now openai4s.service 2>/dev/null; rm -f $OpenAI4SUnit; systemctl disable --now cline-shim-tunnel.service 2>/dev/null; rm -f $TunnelUnit; systemctl daemon-reload" | Out-Null
    Write-Host "autostart: removed openai4s.service and cline-shim-tunnel.service"

    # Leaving the keep-alive supervisor running would keep the distro up after
    # the units it was there to serve are gone.
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'wsl-keepalive|tunnel-shim' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Write-Host "autostart: stopped any running keep-alive and tunnel supervisors"
    Write-Host "autostart: $KeyPath was left on disk -- remove it yourself if you want it gone"
    return
}

if (-not $Server) {
    throw "CLINE_TUNNEL_SERVER is not set. Pass -Server <host>, or set `$env:CLINE_TUNNEL_SERVER."
}

# --- layer 0: the key the distro's forward authenticates with ----------------
$pubKey = (Invoke-Wsl -Command "test -f $KeyPath || ssh-keygen -t ed25519 -N '' -C 'openai4s-shim-tunnel@wsl' -f $KeyPath >/dev/null 2>&1; cat $KeyPath.pub") -replace "`0", ''
$pubKey = $pubKey.Trim()
Write-Host "autostart: distro key -> $pubKey"
Write-Host ""
Write-Host "  This key must be in $TunnelUser@${Server}:~/.ssh/authorized_keys."
Write-Host "  If it is not, append it there before continuing -- the forward cannot"
Write-Host "  authenticate otherwise, and the units will restart-loop."
Write-Host ""

# --- layer 1: the distro's two units ----------------------------------------
$tunnelUnitText = @"
[Unit]
Description=Cline shim tunnel (distro 127.0.0.1:$RemotePort -> relay $Server)
# Loopback-only: deliberately no network-online.target, which blocks a unit
# indefinitely when DNS or routing is unhealthy.
After=network.target

[Service]
Type=simple
User=$User
ExecStart=/usr/bin/ssh -N -i $KeyPath -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -L $RemotePort:127.0.0.1:$RemotePort $TunnelUser@$Server
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
"@

$openai4sUnitText = @"
[Unit]
Description=OpenAI4S daemon and web UI (127.0.0.1:8760)
Wants=cline-shim-tunnel.service
After=cline-shim-tunnel.service network.target

[Service]
Type=simple
User=$User
WorkingDirectory=$OpenAI4SRoot
# Foreground on purpose: Type=simple owns the process, so systemd can restart
# it. --detached would fork and leave systemd watching a parent that exits.
# --no-open skips the browser launch, which there is no session for.
# .env is loaded by openai4s/config.py::_load_dotenv(), so no EnvironmentFile.
ExecStart=$OpenAI4SRoot/.venv/bin/openai4s serve --no-open
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
"@

foreach ($pair in @(@{ Text = $tunnelUnitText; Path = $TunnelUnit },
                    @{ Text = $openai4sUnitText; Path = $OpenAI4SUnit })) {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair.Text))
    Invoke-Wsl -AsRoot -Command "echo $encoded | base64 -d > $($pair.Path)" | Out-Null
    Write-Host "autostart: unit written -> $($pair.Path)"
}

# The retired in-distro shim unit would compete for 8788 if it ever came back.
Invoke-Wsl -AsRoot -Command "systemctl disable --now cline-shim.service 2>/dev/null; rm -f $RetiredUnit; systemctl daemon-reload; systemctl enable cline-shim-tunnel.service openai4s.service" | Out-Null
Write-Host "autostart: retired cline-shim.service removed"
Write-Host "autostart: enabled -> $(Invoke-Wsl -AsRoot -Command 'systemctl is-enabled cline-shim-tunnel.service openai4s.service' | Out-String | ForEach-Object { $_.Trim() })"

# --- layer 2: the Windows-side supervisors, via the Startup folder ----------
Write-StartupLauncher -Name 'cline-shim-tunnel' -ScriptPath (Join-Path $SrcDir 'tunnel-shim.ps1') `
    -EnvBlock @"
' The relay host is per-machine, so it is written here instead of being
' defaulted inside the script -- tunnel-shim.ps1 refuses to start without it,
' and this repository is public.
Set shell = CreateObject("WScript.Shell")
shell.Environment("Process")("CLINE_TUNNEL_SERVER") = "$Server"
"@ `
    -Body @"
' dsh reaches the relay's shim through this forward. It does not touch the distro.
"@

Write-StartupLauncher -Name 'wsl-keepalive' -ScriptPath (Join-Path $SrcDir 'wsl-keepalive.ps1') `
    -Body @"
' Holds a wsl.exe client so the distro -- and the two units inside it -- stay up.
"@

# Start both now so the install is usable without a logout.
foreach ($script in @('tunnel-shim.ps1', 'wsl-keepalive.ps1')) {
    Start-Process powershell -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden',
        '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $SrcDir $script) -WindowStyle Hidden
}
Write-Host "autostart: both supervisors started"

Start-Sleep -Seconds 12
Write-Host ""
Write-Host "--- verification ---"
foreach ($target in @(@{ Name = 'dsh tunnel'; Url = "http://127.0.0.1:$LocalPort/health" },
                      @{ Name = 'OpenAI4S';   Url = 'http://127.0.0.1:8760/' })) {
    try {
        $r = Invoke-WebRequest $target.Url -TimeoutSec 10 -UseBasicParsing
        Write-Host ("  {0,-12} HTTP {1}" -f $target.Name, $r.StatusCode)
    } catch {
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { $null }
        if ($code) { Write-Host ("  {0,-12} HTTP {1} (reachable)" -f $target.Name, $code) }
        else       { Write-Host ("  {0,-12} unreachable" -f $target.Name) }
    }
}
Write-Host ""
Write-Host "autostart: installed. A cold boot now leaves both consumers usable."
