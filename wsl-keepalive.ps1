# Keeps the WSL distro running after logon.
#
# WSL2 shuts a distro down when no wsl.exe client is attached and it has been
# idle. Measured on this machine: after the previous keep-alive was removed, the
# distro really did stop, and the next wsl.exe call had to boot it again from
# scratch (uptime read "up 0 minutes"). Anything inside the distro -- the
# OpenAI4S service and the tunnel to the relay's shim -- goes down with it.
#
# So an enabled systemd unit inside the distro is not sufficient on its own:
# something on the Windows side has to hold a client attached. That is all this
# script does.
#
# A plain child launched with Start-Process does not work for this: it is torn
# down with the launching shell, which removes the last attached client and
# starts the shutdown it was meant to prevent. Running under a supervisor that
# outlives the shell is what makes it stick.
#
# Register it for the current user (no administrator rights needed) by putting a
# shortcut in the Startup folder -- see wsl-keepalive.vbs beside this file.

$Distro    = if ($env:CLINE_WSL_DISTRO)  { $env:CLINE_WSL_DISTRO }  else { 'Ubuntu' }
$ProbePort = if ($env:CLINE_WSL_PROBE)   { $env:CLINE_WSL_PROBE }   else { '8760' }
$LogFile   = if ($env:CLINE_WSL_LOG)     { $env:CLINE_WSL_LOG }     else { "$PSScriptRoot\wsl-keepalive.log" }
$RetrySecs = 10

function Write-Log($Message) {
    $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 1MB)) {
        Set-Content -Path $LogFile -Value (Get-Content $LogFile -Tail 200)
    }
    Add-Content -Path $LogFile -Value $line
}

# One supervisor per distro, so a logon shortcut and a manual run cannot both
# hold clients and fight over restarts.
$mutex = New-Object System.Threading.Mutex($false, "Local\ClineWslKeepalive-$Distro")
if (-not $mutex.WaitOne(0)) {
    Write-Log "another keep-alive supervisor already owns $Distro; exiting"
    exit 0
}

Write-Log "supervisor start for distro $Distro"

# A supervisor that is killed outright leaves its wsl.exe behind, and that
# orphan keeps holding the distro up -- which is the opposite of what stopping
# the supervisor is meant to achieve. Reap any client whose parent is gone.
Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match "-d $Distro " } |
    ForEach-Object {
        $parentAlive = Get-CimInstance Win32_Process -Filter "ProcessId=$($_.ParentProcessId)" -ErrorAction SilentlyContinue
        if (-not $parentAlive) {
            Write-Log "reaping orphaned wsl.exe (pid $($_.ProcessId))"
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }

$proc = $null
try {
    while ($true) {
        $proc = Start-Process -FilePath 'wsl.exe' `
            -ArgumentList @('-d', $Distro, '--', 'sleep', 'infinity') `
            -PassThru -WindowStyle Hidden
        Write-Log "wsl.exe started (pid $($proc.Id))"

        # sleep infinity never returns while the distro lives, so this loop is
        # normally silent. The port probe catches the case where the client is still
        # attached but the distro's services failed to come up -- worth rebooting
        # the distro for rather than waiting on a half-dead state.
        $missedProbes = 0
        while (-not $proc.HasExited) {
            Start-Sleep -Seconds 30
            $proc.Refresh()
            if ($proc.HasExited) { break }

            $alive = $false
            try {
                $client = New-Object System.Net.Sockets.TcpClient
                $alive = $client.ConnectAsync('127.0.0.1', [int]$ProbePort).Wait(5000)
                $client.Close()
            } catch { $alive = $false }

            if ($alive) {
                $missedProbes = 0
            } else {
                $missedProbes++
                Write-Log "port $ProbePort probe failed ($missedProbes/3)"
                # A single miss can just be a service restarting; three in a row
                # means the distro is not healthy and is worth recycling.
                if ($missedProbes -ge 3) {
                    Write-Log "port $ProbePort unreachable; recycling the distro client"
                    try { $proc.Kill() } catch { }
                    break
                }
            }
        }

        Write-Log "wsl.exe exited; retrying in ${RetrySecs}s"
        Start-Sleep -Seconds $RetrySecs
    }
} finally {
    if ($proc -and -not $proc.HasExited) {
        try { $proc.Kill() } catch { }
        Write-Log "supervisor exiting; wsl.exe (pid $($proc.Id)) stopped"
    }
}
