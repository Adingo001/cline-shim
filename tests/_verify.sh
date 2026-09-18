#!/usr/bin/env bash
# Report the shim's state and whether the WSL VM has been kept alive.
#
# The thing worth watching is uptime: if the VM had been torn down while we
# waited, uptime would reset to a few seconds and boot_id would change. A
# steady boot_id with growing uptime is the proof that the resident wsl.exe
# client is holding the VM open.
set -u

echo "uptime   : $(uptime -p)"
echo "boot_id  : $(cat /proc/sys/kernel/random/boot_id)"
echo "service  : $(systemctl is-active cline-shim.service) / $(systemctl is-enabled cline-shim.service)"
echo "main_pid : $(systemctl show -p MainPID --value cline-shim.service)"
echo "shim pid : $(fuser -n tcp 8788 2>/dev/null || echo NONE)"
echo "supers   : $(ps -eo pid,args | grep -c '[a]utostart.sh')"
echo -n "health   : "
curl -sS -m 12 http://127.0.0.1:8788/health 2>&1 | head -c 100
echo
echo "resident : "
ps -eo pid,args | grep '[s]leep infinity' | sed 's/^/           /' || echo "           (none)"
