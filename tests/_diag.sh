#!/usr/bin/env bash
# Diagnose why the shim did not come back after a distro restart.
#
# Checks the unit's own state, the boot-time dependency that could block it,
# and whether anything is listening, then dumps the tail of both the service
# journal and the shim log.
set -u

echo "=== wsl boot ==="
uptime -p 2>/dev/null || echo "(uptime unavailable)"

echo
echo "=== unit state ==="
systemctl is-enabled cline-shim.service 2>&1
systemctl is-active cline-shim.service 2>&1
systemctl show -p MainPID -p ActiveState -p SubState -p Result -p ExecMainStatus \
    cline-shim.service 2>/dev/null

echo
echo "=== blocking dependencies ==="
for t in network-online.target network.target multi-user.target; do
    printf '  %-24s %s\n' "$t" "$(systemctl is-active "$t" 2>&1)"
done

echo
echo "=== port 8788 ==="
fuser -n tcp 8788 2>/dev/null && echo "  (listening)" || echo "  nothing listening"

echo
echo "=== health ==="
curl -sS -m 10 http://127.0.0.1:8788/health 2>&1 | head -c 150
echo

echo
echo "=== supervisors ==="
ps -eo pid,ppid,args | grep '[a]utostart.sh' || echo "  (no autostart.sh running)"

echo
echo "=== service journal (last 30) ==="
journalctl -u cline-shim.service -n 30 --no-pager 2>&1 | tail -30

echo
echo "=== shim log tail ==="
tail -n 10 "$HOME/openai4s-shim/shim.log" 2>/dev/null

echo
echo "=== systemd log for the unit at boot ==="
journalctl -b -u cline-shim.service --no-pager 2>&1 | head -20
