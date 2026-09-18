# Keeps a local port forwarded to the shim running on a remote host.
#
# The shim binds 127.0.0.1 on the far side, so the only way to reach it is a
# tunnel. This script owns that tunnel and re-establishes it whenever it drops,
# which is what makes it a scheduled task rather than a one-shot command.
#
# Register it for the current user (no administrator rights needed):
#   schtasks /create /tn "Cline shim tunnel" /sc onlogon /f /tr "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"<path>\tunnel-shim.ps1\""
#
# ExitOnForwardFailure is not optional: without it, ssh reports success even
# when the local port is already taken, and the tunnel silently forwards
# nothing while looking healthy.

# The relay host has no default on purpose -- it is deployment-specific and
# this repository is public. Set CLINE_TUNNEL_SERVER before running, or pass a
# value through an environment block in the startup shortcut.
$Server    = $env:CLINE_TUNNEL_SERVER
$User      = if ($env:CLINE_TUNNEL_USER)    { $env:CLINE_TUNNEL_USER }    else { 'root' }
$LocalPort = if ($env:CLINE_TUNNEL_LPORT)   { $env:CLINE_TUNNEL_LPORT }   else { '8789' }
$RemotePort= if ($env:CLINE_TUNNEL_RPORT)   { $env:CLINE_TUNNEL_RPORT }   else { '8788' }
$LogFile   = if ($env:CLINE_TUNNEL_LOG)     { $env:CLINE_TUNNEL_LOG }     else { "$PSScriptRoot\tunnel-shim.log" }
$RetrySecs = 5

if (-not $Server) {
    Write-Error "CLINE_TUNNEL_SERVER is not set -- nothing to connect to."
    exit 1
}

function Write-Log($Message) {
    $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    # Keep the log from growing without bound; it is only ever read by hand.
    if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 1MB)) {
        Set-Content -Path $LogFile -Value (Get-Content $LogFile -Tail 200)
    }
    Add-Content -Path $LogFile -Value $line
}

# One supervisor per port. Without this, the Startup shortcut and a manual run
# both bind the local port, the loser's ssh exits on ExitOnForwardFailure, and
# the two processes trade the port back and forth forever.
$mutexName = "Local\ClineShimTunnel-$LocalPort"
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
if (-not $mutex.WaitOne(0)) {
    Write-Log "another supervisor already owns port $LocalPort; exiting"
    exit 0
}

Write-Log "supervisor start: ${LocalPort} -> ${Server}:${RemotePort} as ${User}"

while ($true) {
    $sshArgs = @(
        '-N'
        '-L', "${LocalPort}:127.0.0.1:${RemotePort}"
        "${User}@${Server}"
        '-o', 'ServerAliveInterval=30'
        '-o', 'ServerAliveCountMax=3'
        '-o', 'ExitOnForwardFailure=yes'
        '-o', 'BatchMode=yes'
        '-o', 'ConnectTimeout=20'
        '-o', 'StrictHostKeyChecking=accept-new'
    )

    $proc = Start-Process -FilePath 'ssh.exe' -ArgumentList $sshArgs -PassThru -WindowStyle Hidden
    Write-Log "ssh started (pid $($proc.Id))"

    # Watch the tunnel rather than trusting the process: ssh can stay alive
    # while the forward has already failed. A loopback probe is the only
    # honest health check.
    while (-not $proc.HasExited) {
        Start-Sleep -Seconds 30
        $proc.Refresh()
        if ($proc.HasExited) { break }

        try {
            $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$LocalPort/health" `
                -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
            if ($resp.StatusCode -ne 200) {
                Write-Log "health returned $($resp.StatusCode); restarting tunnel"
                $proc.Kill(); break
            }
        } catch {
            Write-Log "health failed: $($_.Exception.Message); restarting tunnel"
            try { $proc.Kill() } catch { }
            break
        }
    }

    Write-Log "ssh exited; retrying in ${RetrySecs}s"
    Start-Sleep -Seconds $RetrySecs
}
