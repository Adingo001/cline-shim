#!/usr/bin/env bash
# Prove the shim comes back on its own after the process dies.
#
# Two layers should cover this: autostart.sh re-checks the port every 30s and
# restarts the shim when it is gone, and systemd's Restart=always brings the
# supervisor back if it is the supervisor that died. This kills the shim
# outright and reports whether the port returns, so the claim is measured
# rather than assumed.
set -u

port_pid() {
    fuser -n tcp 8788 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' | head -1
}

before="$(port_pid)"
sup_before="$(systemctl show -p MainPID --value cline-shim.service 2>/dev/null)"
echo "before  : shim=${before:-NONE}  supervisor=${sup_before:-NONE}"

if [ -z "$before" ]; then
    echo "shim was not running; starting from this state instead"
else
    kill -9 "$before" 2>/dev/null
    echo "killed  : $before"
fi

echo "waiting up to 75s for self-heal..."
for i in $(seq 1 25); do
    sleep 3
    now="$(port_pid)"
    if [ -n "$now" ]; then
        echo "recovered after ~$((i * 3))s: shim=${now}  supervisor=$(systemctl show -p MainPID --value cline-shim.service)"
        break
    fi
done

after="$(port_pid)"
echo "after   : shim=${after:-NONE}  service=$(systemctl is-active cline-shim.service 2>/dev/null)"
echo "health  : $(curl -sS -m 15 http://127.0.0.1:8788/health 2>&1 | head -c 140)"
echo "supers  :"
ps -eo pid,ppid,args | grep '[a]utostart.sh' | sed 's/^/          /'
[ -z "$after" ] && echo "RESULT  : FAILED to self-heal"
[ -n "$after" ] && echo "RESULT  : self-heal OK"
