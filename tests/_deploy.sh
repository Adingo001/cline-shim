#!/usr/bin/env bash
# Deploy shim.py from the Windows checkout into the WSL install and restart it.
set -euo pipefail
D="${SHIM_DIR:-$HOME/openai4s-shim}"
F=/mnt/d/project/cline-shim/shim.py

[ -f "$D/shim.py.bak" ] || cp "$D/shim.py" "$D/shim.py.bak"
cp "$F" "$D/shim.py"
python3 - <<'PY'
import ast
import os
src = open(os.path.expanduser('~/openai4s-shim/shim.py'), encoding='utf-8').read()
ast.parse(src)
print('deployed shim.py: syntax OK, %d lines' % src.count('\n'))
PY

cd "$D"
./ctl.sh stop >/dev/null 2>&1 || true
sleep 1
./ctl.sh start
sleep 1
curl -sS -m 15 http://127.0.0.1:8788/health
echo
ss -lntH 'sport = :8788' | head -2

# Gateway-mode instance in front of the remote New API gateway, on its own port
# so this restart never disturbs the Cline Pass instance on 8788.
echo '--- gateway mode'
bash /mnt/d/project/cline-shim/tests/_gwctl.sh restart
